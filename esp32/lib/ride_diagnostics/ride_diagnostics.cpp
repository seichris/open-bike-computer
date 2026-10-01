#include "ride_diagnostics.hpp"
#include "ride_diagnostics_control.hpp"
#include "ride_diagnostics_format.hpp"
#include "ride_diagnostics_queue_policy.hpp"
#include "ride_diagnostics_health.hpp"
#include "../power_management/power_management.hpp"
#include "diagnostics_capture_policy.hpp"
#include "diagnostics_tail_policy.hpp"
#include "diagnostics_segment_catalog.hpp"
#include <mbedtls/sha256.h>
#include <Preferences.h>
#include <unistd.h>
#include <ctime>

#include <Arduino.h>
#include <new>
#include <atomic>
#include <algorithm>
#include <dirent.h>
#include <cstdio>
#include <cstring>
#include <sys/stat.h>

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include <esp_attr.h>
#endif

#include "../firmware_metadata/firmware_metadata.hpp"
#include "../storage/storage.hpp"
#include "../runtime_watchdog_diagnostics/runtime_watchdog_diagnostics.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "../boot_diagnostics/boot_diagnostics.hpp"
#endif

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <esp_heap_caps.h>

#ifndef PERSISTENT_RIDE_DIAGNOSTICS
#define PERSISTENT_RIDE_DIAGNOSTICS 0
#endif

#ifndef DETAILED_RIDE_DIAGNOSTICS
#define DETAILED_RIDE_DIAGNOSTICS 1
#endif

namespace ride_diagnostics {

bool recordInternal(Level level, const char *category, const char *event,
                    const char *fieldsJson, bool clearsFaultCapsule,
                    uint32_t faultBoot, uint32_t faultEventCount,
                    uint32_t faultChecksum = 0);

namespace {

bool flushFaultCapsulesIfPossible();
void pruneRetention();
bool parseUnsigned(const char *value, uint32_t &out);

struct QueuedEvent {
  uint32_t sequence;
  uint32_t issueMarker;
  char capture[48];
  uint16_t length;
  bool critical;
  bool rotateBeforeWrite;
  bool rotateAfterWrite;
  bool clearsFaultCapsule;
  uint32_t faultCapsuleBoot;
  uint32_t faultCapsuleEventCount;
  uint32_t faultCapsuleChecksum;
  char line[kMaximumEventBytes];
};

struct ChunkFile {
  uint32_t boot;
  uint32_t chunk;
  uint32_t bytes;
  time_t modifiedAt;
};

using detail::FaultCapsuleState;
using detail::formatFaultCapsuleFields;
using detail::faultCapsuleIdentityMatches;
using detail::kFaultCapsuleMagic;
using detail::sealFaultCapsule;
using detail::validateFieldsJson;
using detail::validFaultCapsule;
using detail::validFaultCapsuleEnvelope;

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
RTC_NOINIT_ATTR FaultCapsuleState retainedFaultCapsule;
#else
FaultCapsuleState retainedFaultCapsule = {};
#endif

FaultCapsuleState currentFaultCapsule = {};
FaultCapsuleState pendingFaultCapsule = {};
bool pendingFaultCapsuleValid = false;
portMUX_TYPE faultCapsuleMux = portMUX_INITIALIZER_UNLOCKED;

constexpr std::size_t kMaximumRetainedFiles = 256;
constexpr std::size_t kFilePruneBatch = 16;

Storage *storage = nullptr;
QueueHandle_t normalQueue = nullptr;
QueueHandle_t criticalQueue = nullptr;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
// Queue control remains in internal RAM. Only task-owned event payloads live
// in PSRAM; no ISR or flash-cache-disabled path accesses these queues.
StaticQueue_t normalQueueControl{};
StaticQueue_t criticalQueueControl{};
uint8_t *normalQueueEvents = nullptr;
uint8_t *criticalQueueEvents = nullptr;

QueueHandle_t createEventQueue(UBaseType_t capacity, uint8_t *&events,
                               StaticQueue_t &control) {
  events = static_cast<uint8_t *>(heap_caps_malloc(
      capacity * sizeof(QueuedEvent), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (events == nullptr)
    return nullptr;
  QueueHandle_t queue =
      xQueueCreateStatic(capacity, sizeof(QueuedEvent), events, &control);
  if (queue == nullptr) {
    heap_caps_free(events);
    events = nullptr;
  }
  return queue;
}
#endif
TaskHandle_t writerTaskHandle = nullptr;
std::atomic<bool> recorderResourcesReady{false};
std::atomic<bool> recorderWriterReady{false};
SemaphoreHandle_t producerMutex = nullptr;
SemaphoreHandle_t queueMutationMutex = nullptr;
SemaphoreHandle_t sealComplete = nullptr;
SemaphoreHandle_t faultCapsuleFlushMutex = nullptr;
FILE *activeFile = nullptr;
mbedtls_sha256_context activeDigest{};
bool activeDigestValid = false;
uint32_t activeFileBytes = 0;
uint32_t activeChunk = 1;
std::atomic<uint32_t> activeChunkSnapshot{1};
std::atomic<uint32_t> bootSequence{1};
std::atomic<bool> persistentBootSequenceReady{false};
uint32_t firmwareFingerprint = 0;
std::atomic<uint32_t> nextSequence{0};
std::atomic<uint32_t> enqueued{0};
std::atomic<uint32_t> written{0};
std::atomic<bool> retentionPrunedThisBoot{false};
std::atomic<uint32_t> dropped{0};
std::atomic<uint32_t> storageErrors{0};
std::atomic<uint32_t> faultCapsuleGeneration{0};
std::atomic<uint32_t> faultCapsuleQueuedGeneration{0};
std::atomic<uint32_t> pendingFaultCapsuleQueuedChecksum{0};
std::atomic<uint32_t> currentFaultCapsuleQueuedChecksum{0};
std::atomic<uint16_t> maxQueueDepth{0};
// When the reserved critical lane overflows, critical records may spill into
// the normal queue. While any spill remains, normal producers are rejected so
// noncritical records can never be appended behind a critical record and make
// head eviction unsafe.
std::atomic<uint16_t> normalQueueCriticalCount{0};
char activeCapture[48] = {};
portMUX_TYPE captureMux = portMUX_INITIALIZER_UNLOCKED;
#if DETAILED_RIDE_DIAGNOSTICS
std::atomic<bool> detailedCapture{false};
std::atomic<uint32_t> detailedCaptureDeadlineMs{0};
#endif
std::atomic<bool> captureBoundaryPending{false};
std::atomic<uint32_t> lastMarkerSequence{0};
char activePath[192] = {};
std::atomic<bool> lastStorageAvailable{false};
std::atomic<bool> sealRequested{false};
std::atomic<uint32_t> sealSequenceCutoff{0};
std::atomic<transfer_policy::SealPreparation> sealPreparationResult{
    transfer_policy::SealPreparation::SealFailed};
std::atomic<bool> clockAnchorEmitted{false};
std::atomic<bool> checkpointRequested{false};
std::atomic<bool> storageTransitionRequested{false};
std::atomic<uint32_t> retentionLeaseDeadlineMs{0};
SemaphoreHandle_t retentionMutex = nullptr;
StorageRecoveryAllowedProbe storageRecoveryAllowedProbe = nullptr;
uint32_t runtimeBootSequence = 0;
uint32_t captureGeneration = 0;
uint32_t lastCheckpointMs = 0;
std::atomic<uint32_t> lastWrittenEventSequence{0};
std::atomic<uint32_t> durableEventSequence{0};
using LiveTail = bicino_diagnostics::TailRing<64>;
LiveTail *liveTail = nullptr; // Lazy, bounded PSRAM, never accessed by ISR/panic paths.
SemaphoreHandle_t liveTailMutex = nullptr;
std::atomic<uint32_t> liveTailDeadlineMs{0};
std::atomic<uint32_t> liveTailDropped{0};
bicino_diagnostics::TailRequest pendingLiveTail{};
std::atomic<bool> liveTailPending{false};
std::atomic<bool> durableSequenceValid{false};

void observeLiveTail(uint32_t sequence, const char *line, std::size_t bytes) {
  if (static_cast<int32_t>(liveTailDeadlineMs.load(std::memory_order_acquire) - millis()) <= 0 ||
      liveTailMutex == nullptr || liveTail == nullptr) return;
  if (xSemaphoreTake(liveTailMutex, 0) != pdTRUE) {
    liveTailDropped.fetch_add(1); return; // Persistent producer still proceeds.
  }
  (void)liveTail->append(sequence, line, bytes);
  xSemaphoreGive(liveTailMutex);
}
std::atomic<uint32_t> durableMarkerSequence{0};
portMUX_TYPE policyMux = portMUX_INITIALIZER_UNLOCKED;
bicino_diagnostics::CapturePolicy runtimePolicy;
char pendingPolicyCommand[161] = {};
std::atomic<bool> policyPersistencePending{false};
std::atomic<bool> policyPersisted{false};
std::atomic<bool> legacyDetailedCapture{false};
uint32_t lastPolicyPersistAttemptMs = 0;
uint32_t lastPolicyHealthMs = 0;
uint32_t lastMemorySampleMs = 0;
void persistCapturePolicyIfNeeded();
void restoreCapturePolicy();
void revokeCapturePolicy();

int synchronizeDiagnosticFile(FILE *file) {
  power_management::ScopedLock powerLock(power_management::LockDomain::Storage);
  if (file == nullptr || storage == nullptr || storage->flush(file) != 0)
    return EOF;
  return ::fsync(::fileno(file));
}

ChunkFile retentionFiles[kMaximumRetainedFiles] = {};
ChunkFile filePruneCandidates[kFilePruneBatch] = {};

struct SemaphoreGuard {
  explicit SemaphoreGuard(SemaphoreHandle_t handleRef) : handle(handleRef) {
    if (handle != nullptr)
      locked = xSemaphoreTake(handle, portMAX_DELAY) == pdTRUE;
  }
  ~SemaphoreGuard() {
    if (locked)
      xSemaphoreGive(handle);
  }
  SemaphoreHandle_t handle;
  bool locked = false;
};

const char *diagnosticsRoot() {
  return storage == nullptr ? "/sdcard" : storage->diagnosticsRootPath();
}

struct ChunkFileScan {
  std::size_t storedCount = 0;
  std::size_t totalCount = 0;
  std::size_t pruneCandidateCount = 0;
};

bool chunkFileOlder(const ChunkFile &left, const ChunkFile &right) {
  if (left.boot != right.boot)
    return left.boot < right.boot;
  return left.chunk < right.chunk;
}

void considerFilePruneCandidate(const ChunkFile &file,
                                ChunkFile *candidates,
                                std::size_t capacity,
                                std::size_t &count) {
  if (candidates == nullptr || capacity == 0)
    return;
  if (count < capacity) {
    candidates[count++] = file;
  } else if (chunkFileOlder(file, candidates[count - 1])) {
    candidates[count - 1] = file;
  } else {
    return;
  }
  std::sort(candidates, candidates + count, chunkFileOlder);
}

bool removeChunkFile(const ChunkFile &file) {
  if (storage == nullptr)
    return false;
  char path[224] = {};
  snprintf(path, sizeof(path),
           "%s/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
           diagnosticsRoot(),
           static_cast<unsigned long>(file.boot),
           static_cast<unsigned long>(file.chunk));
  const bool removed = storage->remove(path);
  if (removed) bicino_diagnostics::removeSegmentDescriptor(*storage, path);
  return removed;
}

void removeEmptyBootDirectories() {
  if (storage == nullptr)
    return;
  char bootsRoot[192] = {};
  snprintf(bootsRoot, sizeof(bootsRoot),
           "%s/BICINO/DIAGNOSTICS/v1/boots", diagnosticsRoot());
  DIR *boots = opendir(bootsRoot);
  if (boots == nullptr)
    return;
  const uint32_t currentBoot = bootSequence.load();
  while (struct dirent *entry = readdir(boots)) {
    uint32_t boot = 0;
    if (!parseUnsigned(entry->d_name, boot) || boot == currentBoot)
      continue;
    char path[224] = {};
    snprintf(path, sizeof(path), "%s/%s", bootsRoot, entry->d_name);
    DIR *directory = opendir(path);
    if (directory == nullptr)
      continue;
    bool empty = true;
    while (struct dirent *child = readdir(directory)) {
      if (strcmp(child->d_name, ".") != 0 &&
          strcmp(child->d_name, "..") != 0) {
        empty = false;
        break;
      }
    }
    closedir(directory);
    if (empty)
      (void)storage->rmdir(path);
  }
  closedir(boots);
}

const char *levelName(Level level) {
  switch (level) {
  case Level::Debug:
    return "debug";
  case Level::Info:
    return "info";
  case Level::Warning:
    return "warning";
  case Level::Error:
    return "error";
  case Level::Trace:
    return "trace";
  case Level::Fault:
    return "fault";
  }
  return "info";
}

bool validToken(const char *value, std::size_t maxLength) {
  if (value == nullptr || value[0] == '\0')
    return false;
  const std::size_t length = strnlen(value, maxLength + 1);
  if (length == 0 || length > maxLength)
    return false;
  for (std::size_t i = 0; i < length; ++i) {
    const char c = value[i];
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) {
      return false;
    }
  }
  return true;
}

bool validCaptureID(const char *value) {
  if (value == nullptr || strnlen(value, 48) != 36)
    return false;
  for (std::size_t index = 0; index < 36; ++index) {
    const char c = value[index];
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (c != '-')
        return false;
      continue;
    }
    const bool hex = (c >= '0' && c <= '9') ||
                     (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    if (!hex)
      return false;
  }
  return true;
}

bool validIssueCode(const char *value) {
  return value != nullptr &&
         (strcmp(value, "navigation_wrong") == 0 ||
          strcmp(value, "device_blank") == 0 ||
          strcmp(value, "connection_drop") == 0 ||
          strcmp(value, "sensor_missing") == 0 ||
          strcmp(value, "other") == 0);
}

bool parseUnsigned(const char *value, uint32_t &out) {
  if (value == nullptr || value[0] == '\0')
    return false;
  uint64_t parsed = 0;
  for (const char *cursor = value; *cursor != '\0'; ++cursor) {
    if (*cursor < '0' || *cursor > '9')
      return false;
    parsed = parsed * 10U + static_cast<unsigned>(*cursor - '0');
    if (parsed > UINT32_MAX)
      return false;
  }
  out = static_cast<uint32_t>(parsed);
  return true;
}

void copyCapture(char *out, std::size_t capacity) {
  portENTER_CRITICAL(&captureMux);
  strncpy(out, activeCapture, capacity - 1);
  out[capacity - 1] = '\0';
  portEXIT_CRITICAL(&captureMux);
}

void initializeFaultCapsules() {
  const uint32_t selectedBootSequence = bootSequence.load();
  portENTER_CRITICAL(&faultCapsuleMux);
  pendingFaultCapsuleValid = validFaultCapsule(retainedFaultCapsule) &&
                             retainedFaultCapsule.bootSequence != selectedBootSequence;
  if (pendingFaultCapsuleValid)
    pendingFaultCapsule = retainedFaultCapsule;

  memset(&currentFaultCapsule, 0, sizeof(currentFaultCapsule));
  currentFaultCapsule.bootSequence = selectedBootSequence;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const boot_diagnostics::Snapshot snapshot = boot_diagnostics::snapshot();
  currentFaultCapsule.resetReason = snapshot.resetReason;
  currentFaultCapsule.activeStage = static_cast<uint16_t>(snapshot.activeStage);
  currentFaultCapsule.completedStage =
      static_cast<uint16_t>(snapshot.completedStage);
#endif
  sealFaultCapsule(currentFaultCapsule);
  portEXIT_CRITICAL(&faultCapsuleMux);
}

void updateFaultCapsule(Level level, const char *category, const char *event,
                        bool storageFailure) {
  const uint32_t selectedBootSequence = bootSequence.load();
  portENTER_CRITICAL(&faultCapsuleMux);
  if (!validFaultCapsuleEnvelope(currentFaultCapsule) ||
      currentFaultCapsule.bootSequence != selectedBootSequence) {
    memset(&currentFaultCapsule, 0, sizeof(currentFaultCapsule));
    currentFaultCapsule.bootSequence = selectedBootSequence;
  }
  const uint32_t nowMs = millis();
  if (currentFaultCapsule.eventCount == 0)
    currentFaultCapsule.firstMissingUptimeMs = nowMs;
  currentFaultCapsule.lastMissingUptimeMs = nowMs;
  currentFaultCapsule.eventCount++;
  if (storageFailure)
    currentFaultCapsule.storageErrorCount++;
  if (level == Level::Warning || level == Level::Error || level == Level::Fault || storageFailure) {
    if (category != nullptr) {
      strncpy(currentFaultCapsule.lastCriticalCategory, category,
              sizeof(currentFaultCapsule.lastCriticalCategory) - 1);
      currentFaultCapsule.lastCriticalCategory[
          sizeof(currentFaultCapsule.lastCriticalCategory) - 1] = '\0';
    }
    if (event != nullptr) {
      strncpy(currentFaultCapsule.lastCriticalEvent, event,
              sizeof(currentFaultCapsule.lastCriticalEvent) - 1);
      currentFaultCapsule.lastCriticalEvent[
          sizeof(currentFaultCapsule.lastCriticalEvent) - 1] = '\0';
    }
  }
  currentFaultCapsule.droppedCount = dropped.load();
  sealFaultCapsule(currentFaultCapsule);
  retainedFaultCapsule = currentFaultCapsule;
  faultCapsuleGeneration.fetch_add(1, std::memory_order_release);
  portEXIT_CRITICAL(&faultCapsuleMux);
}

void clearFaultCapsule(uint32_t capsuleBoot, uint32_t capsuleChecksum) {
  portENTER_CRITICAL(&faultCapsuleMux);
  const bool pendingMatches =
      pendingFaultCapsuleValid &&
      faultCapsuleIdentityMatches(pendingFaultCapsule, capsuleBoot,
                                  capsuleChecksum);
  if (pendingMatches) {
    pendingFaultCapsuleValid = false;
    memset(&pendingFaultCapsule, 0, sizeof(pendingFaultCapsule));
    pendingFaultCapsuleQueuedChecksum.store(0, std::memory_order_release);
    // The pending capsule was copied from RTC at boot. Clear that exact
    // retained value after acknowledgement, but never erase a newer capsule
    // written by the current boot while the old record was queued.
    if (faultCapsuleIdentityMatches(retainedFaultCapsule, capsuleBoot,
                                    capsuleChecksum)) {
      memset(&retainedFaultCapsule, 0, sizeof(retainedFaultCapsule));
    }
  }
  if (faultCapsuleIdentityMatches(currentFaultCapsule, capsuleBoot,
                                  capsuleChecksum)) {
    memset(&currentFaultCapsule, 0, sizeof(currentFaultCapsule));
    memset(&retainedFaultCapsule, 0, sizeof(retainedFaultCapsule));
    currentFaultCapsuleQueuedChecksum.store(0, std::memory_order_release);
  }
  portEXIT_CRITICAL(&faultCapsuleMux);
}

bool utcNow(char *out, std::size_t capacity) {
  const time_t now = time(nullptr);
  if (now < 1700000000)
    return false;
  struct tm utc = {};
  gmtime_r(&now, &utc);
  return strftime(out, capacity, "%Y-%m-%dT%H:%M:%SZ", &utc) > 0;
}

uint32_t persistentBootSequence(uint32_t requested) {
  uint32_t selected = requested == 0 ? 1 : requested;
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded())
    return selected;
  char bootsPath[192] = {};
  snprintf(bootsPath, sizeof(bootsPath), "%s/BICINO/DIAGNOSTICS/v1/boots",
           diagnosticsRoot());
  DIR *boots = opendir(bootsPath);
  if (boots == nullptr)
    return selected;
  uint32_t newest = 0;
  while (struct dirent *entry = readdir(boots)) {
    uint32_t existing = 0;
    if (parseUnsigned(entry->d_name, existing))
      newest = std::max(newest, existing);
  }
  closedir(boots);
  if (newest == UINT32_MAX)
    return 0;
  selected = std::max(selected, newest + 1);
  return selected;
}

bool initializePersistentBootSequenceIfNeeded() {
  if (persistentBootSequenceReady.load(std::memory_order_acquire))
    return true;
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded())
    return false;
  const uint32_t selected = persistentBootSequence(runtimeBootSequence);
  if (selected == 0)
    return false;
  bootSequence.store(selected, std::memory_order_release);
  persistentBootSequenceReady.store(true, std::memory_order_release);
  return true;
}

enum class ActiveFileCloseResult : uint8_t {
  Ready = 0,
  FlushFailed,
  CloseFailed,
};

ActiveFileCloseResult closeActiveFile() {
  if (activeFile == nullptr)
    return ActiveFileCloseResult::Ready;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  runtime_watchdog_diagnostics::notePhase(
      runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
      runtime_watchdog_diagnostics::Phase::DiagnosticsFlush,
      nextSequence.load(std::memory_order_relaxed));
#endif
  const int flushResult =
      storage != nullptr ? synchronizeDiagnosticFile(activeFile) : fflush(activeFile);
  const int closeResult =
      storage != nullptr ? storage->close(activeFile) : fclose(activeFile);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  runtime_watchdog_diagnostics::notePhase(
      runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
      runtime_watchdog_diagnostics::Phase::Waiting,
      nextSequence.load(std::memory_order_relaxed));
#endif
  activeFile = nullptr;
  if (flushResult != 0)
    return ActiveFileCloseResult::FlushFailed;
  if (closeResult != 0)
    return ActiveFileCloseResult::CloseFailed;
  return ActiveFileCloseResult::Ready;
}

ActiveFileCloseResult closeAndAdvanceActiveChunk() {
  char closingPath[sizeof(activePath)] = {};
  if (activePath[0] != '\0')
    strncpy(closingPath, activePath, sizeof(closingPath) - 1);
  uint8_t digest[32] = {};
  const bool digestReady = activeDigestValid && mbedtls_sha256_finish(&activeDigest, digest) == 0;
  activeDigestValid = false;
  const uint32_t sealedBytes = activeFileBytes;
  const ActiveFileCloseResult closeResult = closeActiveFile();
  if (digestReady && sealedBytes > 0 && closeResult == ActiveFileCloseResult::Ready && storage != nullptr) {
    bicino_diagnostics::SegmentDescriptor descriptor;
    descriptor.boot = bootSequence.load(); descriptor.chunk = activeChunk; descriptor.bytes = sealedBytes;
    for (unsigned index = 0; index < 32; ++index)
      std::snprintf(descriptor.sha256 + index * 2, 3, "%02x", digest[index]);
    if (!bicino_diagnostics::writeSegmentDescriptor(*storage, closingPath, descriptor))
      updateFaultCapsule(Level::Warning, "logger", "catalog_cache_unavailable", false);
  }
  // stdio may buffer a short capture entirely until fclose(). Determine
  // whether the chunk exists only after the close has flushed those bytes.
  const bool hadActiveChunk = closingPath[0] != '\0' &&
                              (activeFileBytes > 0 ||
                               (storage != nullptr &&
                                storage->size(closingPath) > 0));
  activePath[0] = '\0';
  activeFileBytes = 0;
  if (hadActiveChunk) {
    ++activeChunk;
    activeChunkSnapshot.store(activeChunk);
    pruneRetention();
  }
  return closeResult;
}

const char *closeFailureEvent(ActiveFileCloseResult result) {
  return result == ActiveFileCloseResult::CloseFailed ? "close_failed"
                                                       : "flush_failed";
}

bool ensurePaths() {
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded())
    return false;
  char path[192] = {};
  snprintf(path, sizeof(path), "%s/BICINO", diagnosticsRoot());
  storage->mkdir(path);
  snprintf(path, sizeof(path), "%s/BICINO/DIAGNOSTICS", diagnosticsRoot());
  storage->mkdir(path);
  snprintf(path, sizeof(path), "%s/BICINO/DIAGNOSTICS/v1", diagnosticsRoot());
  storage->mkdir(path);
  char bootsPath[160] = {};
  snprintf(bootsPath, sizeof(bootsPath),
           "%s/BICINO/DIAGNOSTICS/v1/boots", diagnosticsRoot());
  storage->mkdir(bootsPath);
  char bootPath[192] = {};
  const uint32_t selectedBootSequence = bootSequence.load();
  snprintf(bootPath, sizeof(bootPath), "%s/%lu", bootsPath,
           static_cast<unsigned long>(selectedBootSequence));
  storage->mkdir(bootPath);
  return true;
}

bool openActiveFile() {
  if (activeFile != nullptr)
    return true;
  if (!ensurePaths())
    return false;
  // Preserve any legacy/failed chunk that already reached the hard limit.
  // Never append to it: the transfer contract rejects oversized chunks.
  for (std::size_t attempt = 0; attempt < kMaximumRetainedFiles; ++attempt) {
    snprintf(activePath, sizeof(activePath),
             "%s/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
             diagnosticsRoot(),
             static_cast<unsigned long>(bootSequence.load()),
             static_cast<unsigned long>(activeChunk));
    const uint64_t existingBytes = storage->size(activePath);
    if (existingBytes >= kChunkBytes) {
      ++activeChunk;
      activeChunkSnapshot.store(activeChunk);
      continue;
    }
    activeFile = storage->open(activePath, "a");
    if (activeFile == nullptr)
      return false;
    activeFileBytes = static_cast<uint32_t>(existingBytes);
    mbedtls_sha256_free(&activeDigest);
    mbedtls_sha256_init(&activeDigest);
    activeDigestValid = existingBytes == 0 && mbedtls_sha256_starts(&activeDigest, 0) == 0;
    return true;
  }
  activePath[0] = '\0';
  activeFileBytes = 0;
  return false;
}

void abandonActiveChunkAfterUncertainWrite() {
  activeDigestValid = false;
  const bool hadPath = activePath[0] != '\0';
  (void)closeActiveFile();
  activePath[0] = '\0';
  activeFileBytes = 0;
  if (hadPath) {
    ++activeChunk;
    activeChunkSnapshot.store(activeChunk);
  }
}

ChunkFileScan collectChunkFiles(ChunkFile *files, std::size_t capacity,
                                ChunkFile *pruneCandidates,
                                std::size_t pruneCandidateCapacity) {
  ChunkFileScan scan;
  if (files == nullptr || capacity == 0 || storage == nullptr ||
      !storage->getDiagnosticsSdLoaded()) {
    return scan;
  }
  char bootsRoot[192] = {};
  snprintf(bootsRoot, sizeof(bootsRoot),
           "%s/BICINO/DIAGNOSTICS/v1/boots", diagnosticsRoot());
  DIR *boots = opendir(bootsRoot);
  if (boots == nullptr)
    return scan;

  const uint32_t selectedBoot = bootSequence.load();
  const uint32_t selectedActiveChunk = activeChunk;
  while (struct dirent *bootEntry = readdir(boots)) {
    uint32_t boot = 0;
    if ((bootEntry->d_type == DT_DIR || bootEntry->d_type == DT_UNKNOWN) &&
        parseUnsigned(bootEntry->d_name, boot)) {
      char bootPath[192] = {};
      snprintf(bootPath, sizeof(bootPath),
               "%s/%s", bootsRoot, bootEntry->d_name);
      DIR *bootDirectory = opendir(bootPath);
      if (bootDirectory == nullptr)
        continue;
      while (struct dirent *chunkEntry = readdir(bootDirectory)) {
        const char *name = chunkEntry->d_name;
        if (strncmp(name, "events-", 7) != 0 ||
            strlen(name) < 14 ||
            strcmp(name + strlen(name) - 6, ".jsonl") != 0) {
          continue;
        }
        char number[16] = {};
        const std::size_t numberLength = strlen(name) - 7 - 6;
        if (numberLength == 0 || numberLength >= sizeof(number))
          continue;
        memcpy(number, name + 7, numberLength);
        uint32_t chunk = 0;
        if (!parseUnsigned(number, chunk))
          continue;
        ChunkFile file = {};
        file.boot = boot;
        file.chunk = chunk;
        char path[224] = {};
        snprintf(path, sizeof(path), "%s/%s", bootPath, name);
        file.bytes = static_cast<uint32_t>(storage->size(path));
        struct stat metadata = {};
        file.modifiedAt = ::stat(path, &metadata) == 0 ? metadata.st_mtime : 0;
        if (scan.storedCount < capacity)
          files[scan.storedCount++] = file;
        ++scan.totalCount;
        const bool isActive = file.boot == selectedBoot &&
                              file.chunk == selectedActiveChunk;
        if (!isActive) {
          considerFilePruneCandidate(file, pruneCandidates,
                                     pruneCandidateCapacity,
                                     scan.pruneCandidateCount);
        }
      }
      closedir(bootDirectory);
    }
  }
  closedir(boots);
  std::sort(files, files + scan.storedCount, chunkFileOlder);
  return scan;
}

void pruneRetention() {
  SemaphoreGuard retentionGuard(retentionMutex);
  const uint32_t leaseDeadline =
      retentionLeaseDeadlineMs.load(std::memory_order_acquire);
  if (retention_policy::snapshotLeaseActive(millis(), leaseDeadline))
    return;
  if (leaseDeadline != 0)
    retentionLeaseDeadlineMs.store(0, std::memory_order_release);
  std::size_t count = 0;
  while (true) {
    const ChunkFileScan scan = collectChunkFiles(
        retentionFiles, kMaximumRetainedFiles, filePruneCandidates,
        kFilePruneBatch);
    if (scan.totalCount <= kMaximumRetainedFiles) {
      count = scan.storedCount;
      break;
    }
    const std::size_t deleteCount = std::min(
        scan.totalCount - kMaximumRetainedFiles, scan.pruneCandidateCount);
    bool removedAny = false;
    for (std::size_t index = 0; index < deleteCount; ++index)
      removedAny = removeChunkFile(filePruneCandidates[index]) || removedAny;
    if (!removedAny)
      return;
    vTaskDelay(1);
  }
  if (count == 0) {
    removeEmptyBootDirectories();
    return;
  }

  const uint32_t newestBoot = retentionFiles[count - 1].boot;
  const uint32_t oldestAllowedBoot =
      newestBoot >= kRetentionBoots - 1 ? newestBoot - (kRetentionBoots - 1) : 0;
  uint64_t totalBytes = 0;
  uint64_t freeBytes = storage->diagnosticsSdFreeBytes();
  const storage_policy::Budget budget = storage_policy::budgetForBackend(
      storage->storageBackend() == StorageBackend::InternalFFat);
  const time_t now = time(nullptr);
  for (std::size_t index = 0; index < count; ++index)
    totalBytes += retentionFiles[index].bytes;

  for (std::size_t index = 0; index < count; ++index) {
    const ChunkFile &file = retentionFiles[index];
    const bool isActive = file.boot == bootSequence.load() &&
                          file.chunk == activeChunk;
    const bool tooOldByBoot = file.boot < oldestAllowedBoot;
    const bool tooOldByDate = retention_policy::expiredByWallClock(
        static_cast<uint64_t>(std::max<time_t>(now, 0)),
        static_cast<uint64_t>(std::max<time_t>(file.modifiedAt, 0)),
        kRetentionDays);
    const bool tooOld = tooOldByBoot || tooOldByDate;
    const bool overBudget = storage_policy::constraintsExceeded(
        totalBytes, freeBytes, kChunkBytes, budget);
    if (isActive || (!tooOld && !overBudget))
      continue;
    if (removeChunkFile(file)) {
      totalBytes -= std::min<uint64_t>(totalBytes, file.bytes);
      freeBytes = storage->diagnosticsSdFreeBytes();
    }
  }
  removeEmptyBootDirectories();
}

bool hasChunkWriteReserve() {
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded())
    return false;
  const uint64_t freeBytes = storage->diagnosticsSdFreeBytes();
  const storage_policy::Budget budget = storage_policy::budgetForBackend(
      storage->storageBackend() == StorageBackend::InternalFFat);
  return storage_policy::hasWriteReserve(freeBytes, kChunkBytes, budget);
}

bool prepareChunkWriteReserve() {
  if (hasChunkWriteReserve())
    return true;
  pruneRetention();
  return hasChunkWriteReserve();
}

bool writeQueuedEvent(const QueuedEvent &event) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  runtime_watchdog_diagnostics::notePhase(
      runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
      runtime_watchdog_diagnostics::Phase::DiagnosticsWrite,
      event.sequence);
#endif
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded()) {
    abandonActiveChunkAfterUncertainWrite();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_unavailable", true);
    return false;
  }
  if (event.rotateBeforeWrite) {
    const ActiveFileCloseResult closeResult = closeAndAdvanceActiveChunk();
    if (closeResult != ActiveFileCloseResult::Ready) {
      storage->markDiagnosticsSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage",
                         closeFailureEvent(closeResult), true);
      return false;
    }
  }
  if (activeFile == nullptr && !prepareChunkWriteReserve()) {
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "free_space_reserved", true);
    return false;
  }
  if (!openActiveFile()) {
    storage->markDiagnosticsSdUnavailable();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_unavailable", true);
    return false;
  }
  if (activeFileBytes + event.length > kChunkBytes) {
    const ActiveFileCloseResult closeResult = closeAndAdvanceActiveChunk();
    if (closeResult != ActiveFileCloseResult::Ready) {
      storage->markDiagnosticsSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage",
                         closeFailureEvent(closeResult), true);
      return false;
    }
    if (!prepareChunkWriteReserve()) {
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "free_space_reserved", true);
      return false;
    }
    if (!openActiveFile()) {
      storage->markDiagnosticsSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "chunk_open_failed", true);
      return false;
    }
  }
  const size_t result = storage->write(activeFile,
                                       reinterpret_cast<const uint8_t *>(event.line),
                                       event.length);
  if (result != event.length) {
    abandonActiveChunkAfterUncertainWrite();
    storage->markDiagnosticsSdUnavailable();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_failed", true);
    return false;
  }
  if (activeDigestValid && mbedtls_sha256_update(&activeDigest,
          reinterpret_cast<const uint8_t *>(event.line), result) != 0) activeDigestValid = false;
  activeFileBytes += static_cast<uint32_t>(result);
  lastWrittenEventSequence.store(event.sequence, std::memory_order_release);
  const uint32_t nowMs = millis();
  if (event.critical || static_cast<uint32_t>(nowMs - lastCheckpointMs) >= 5000U) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    runtime_watchdog_diagnostics::notePhase(
        runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
        runtime_watchdog_diagnostics::Phase::DiagnosticsFlush,
        event.sequence);
#endif
    if (synchronizeDiagnosticFile(activeFile) != 0) {
      abandonActiveChunkAfterUncertainWrite();
      storage->markDiagnosticsSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "flush_failed", true);
      return false;
    }
    lastCheckpointMs = nowMs;
    durableEventSequence.store(event.sequence, std::memory_order_release);
    durableSequenceValid.store(true, std::memory_order_release);
    if (event.issueMarker != 0) {
      portENTER_CRITICAL(&captureMux);
      if (std::strcmp(event.capture, activeCapture) == 0)
        durableMarkerSequence.store(event.issueMarker, std::memory_order_release);
      portEXIT_CRITICAL(&captureMux);
    }
  }
  const uint32_t writtenCount = written.fetch_add(1) + 1;
  const bool alreadyPrunedThisBoot =
      retentionPrunedThisBoot.exchange(true, std::memory_order_acq_rel);
  // Early-crash loops may never reach the periodic 16-write cadence or a
  // clean chunk close. Prune after the first successful write of every boot
  // so prior short boots still obey the 20-boot/size retention ceilings.
  if (retention_policy::shouldPruneAfterWrite(writtenCount,
                                              alreadyPrunedThisBoot)) {
    pruneRetention();
  }
  if (event.clearsFaultCapsule) {
    clearFaultCapsule(event.faultCapsuleBoot,
                      event.faultCapsuleChecksum);
  }
  if (event.rotateAfterWrite) {
    const ActiveFileCloseResult closeResult = closeAndAdvanceActiveChunk();
    if (closeResult != ActiveFileCloseResult::Ready) {
      storage->markDiagnosticsSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage",
                         closeFailureEvent(closeResult), true);
      return false;
    }
  }
  if (faultCapsuleGeneration.load(std::memory_order_acquire) !=
      faultCapsuleQueuedGeneration.load(std::memory_order_acquire))
    (void)flushFaultCapsulesIfPossible();
  return true;
}

bool flushFaultCapsulesIfPossible() {
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded() ||
      faultCapsuleFlushMutex == nullptr ||
      xSemaphoreTake(faultCapsuleFlushMutex, 0) != pdTRUE)
    return false;

  FaultCapsuleState pending = {};
  FaultCapsuleState current = {};
  bool hasPending = false;
  bool hasCurrent = false;
  uint32_t generation = 0;
  portENTER_CRITICAL(&faultCapsuleMux);
  hasPending = pendingFaultCapsuleValid;
  if (hasPending)
    pending = pendingFaultCapsule;
  hasCurrent = validFaultCapsule(currentFaultCapsule);
  if (hasCurrent)
    current = currentFaultCapsule;
  generation = faultCapsuleGeneration.load(std::memory_order_acquire);
  portEXIT_CRITICAL(&faultCapsuleMux);

  auto flush = [](const FaultCapsuleState &capsule,
                  std::atomic<uint32_t> &queuedChecksum) {
    if (queuedChecksum.load(std::memory_order_acquire) == capsule.checksum)
      return true;
    char fields[512] = {};
    if (!formatFaultCapsuleFields(capsule, fields, sizeof(fields)))
      return false;
    const bool queued = recordInternal(
        Level::Warning, "storage", "storage_gap", fields, true,
        capsule.bootSequence, capsule.eventCount, capsule.checksum);
    if (queued)
      queuedChecksum.store(capsule.checksum, std::memory_order_release);
    return queued;
  };

  bool queuedAll = true;
  if (hasPending)
    queuedAll = flush(pending, pendingFaultCapsuleQueuedChecksum) && queuedAll;
  if (hasCurrent)
    queuedAll = flush(current, currentFaultCapsuleQueuedChecksum) && queuedAll;
  if (queuedAll)
    faultCapsuleQueuedGeneration.store(generation,
                                       std::memory_order_release);
  xSemaphoreGive(faultCapsuleFlushMutex);
  return queuedAll;
}

uint16_t queuedDepth() {
  return static_cast<uint16_t>(
      (normalQueue == nullptr ? 0 : uxQueueMessagesWaiting(normalQueue)) +
      (criticalQueue == nullptr ? 0 : uxQueueMessagesWaiting(criticalQueue)));
}

bool peekNextEvent(QueuedEvent &event, QueueHandle_t &selected) {
  QueuedEvent normal = {};
  QueuedEvent critical = {};
  const bool hasNormal =
      normalQueue != nullptr && xQueuePeek(normalQueue, &normal, 0) == pdTRUE;
  const bool hasCritical = criticalQueue != nullptr &&
                           xQueuePeek(criticalQueue, &critical, 0) == pdTRUE;
  const queue_policy::Selection selection = queue_policy::select(
      hasNormal, normal.sequence, hasCritical, critical.sequence);
  if (selection == queue_policy::Selection::None)
    return false;
  if (selection == queue_policy::Selection::Normal) {
    event = normal;
    selected = normalQueue;
  } else {
    event = critical;
    selected = criticalQueue;
  }
  return true;
}

bool completeSealIfReady() {
  if (!sealRequested.load(std::memory_order_acquire))
    return false;
  if (queueMutationMutex == nullptr ||
      xSemaphoreTake(queueMutationMutex, 0) != pdTRUE) {
    return false;
  }
  QueuedEvent next = {};
  QueueHandle_t selected = nullptr;
  const bool hasNext = peekNextEvent(next, selected);
  xSemaphoreGive(queueMutationMutex);
  const uint32_t cutoff = sealSequenceCutoff.load(std::memory_order_acquire);
  if (!queue_policy::readyToSeal(hasNext, next.sequence, cutoff))
    return false;

  transfer_policy::SealPreparation result =
      transfer_policy::SealPreparation::Ready;
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded()) {
    result = transfer_policy::SealPreparation::StorageUnavailable;
  } else {
    const ActiveFileCloseResult closeResult = closeAndAdvanceActiveChunk();
    if (closeResult != ActiveFileCloseResult::Ready) {
      result = closeResult == ActiveFileCloseResult::CloseFailed
                   ? transfer_policy::SealPreparation::CloseFailed
                   : transfer_policy::SealPreparation::FlushFailed;
      storage->markDiagnosticsSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage",
                         closeFailureEvent(closeResult), true);
    }
  }
  sealPreparationResult.store(result, std::memory_order_release);
  // Publish completion before exposing an idle request slot. Otherwise a
  // retry can publish a new cutoff and consume this predecessor's late give.
  if (sealComplete != nullptr)
    xSemaphoreGive(sealComplete);
  sealRequested.store(false, std::memory_order_release);
  return true;
}

void writerTask(void *) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  runtime_watchdog_diagnostics::registerCurrentTask(
      runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
      runtime_watchdog_diagnostics::Phase::Waiting);
#endif
  uint32_t lastMountAttemptMs = 0;
  lastStorageAvailable.store(
      storage != nullptr && storage->getDiagnosticsSdLoaded(),
      std::memory_order_release);
  while (true) {
    if (completeSealIfReady())
      continue;
    QueuedEvent event = {};
    QueueHandle_t selected = nullptr;
    bool hasNext = false;
    bool dequeued = false;
    const bool transitionPaused =
        storageTransitionRequested.load(std::memory_order_acquire) &&
        !sealRequested.load(std::memory_order_acquire);
    if (queueMutationMutex != nullptr &&
        xSemaphoreTake(queueMutationMutex, 0) == pdTRUE) {
      hasNext = peekNextEvent(event, selected);
      if (hasNext && !transitionPaused &&
          xQueueReceive(selected, &event, 0) == pdTRUE) {
        if (selected == normalQueue && event.critical) {
          const uint16_t spilled =
              normalQueueCriticalCount.load(std::memory_order_acquire);
          if (spilled > 0) {
            normalQueueCriticalCount.fetch_sub(1,
                                               std::memory_order_acq_rel);
          }
        }
        dequeued = true;
      }
      xSemaphoreGive(queueMutationMutex);
    }
    if (dequeued) {
      writeQueuedEvent(event);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      runtime_watchdog_diagnostics::notePhase(
          runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
          runtime_watchdog_diagnostics::Phase::Waiting,
          event.sequence);
#endif
    } else if (!hasNext || transitionPaused) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      runtime_watchdog_diagnostics::heartbeat(
          runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter);
#endif
      vTaskDelay(pdMS_TO_TICKS(50));
    }

    if (storage == nullptr)
      continue;
    // A map-storage remount owns the backend after the seal completes. Keep
    // newly queued records in RAM until the caller resumes the writer so no
    // FILE can be opened between the seal and SD.end()/FFat.end().
    if (storageTransitionRequested.load(std::memory_order_acquire) &&
        !sealRequested.load(std::memory_order_acquire)) {
      vTaskDelay(pdMS_TO_TICKS(10));
      continue;
    }
    const uint32_t nowMs = millis();
    persistCapturePolicyIfNeeded();
    if (activeFile != nullptr &&
        (checkpointRequested.exchange(false) ||
         static_cast<uint32_t>(nowMs - lastCheckpointMs) >= 5000U)) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      runtime_watchdog_diagnostics::notePhase(
          runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
          runtime_watchdog_diagnostics::Phase::DiagnosticsFlush,
          nextSequence.load(std::memory_order_relaxed));
#endif
      if (synchronizeDiagnosticFile(activeFile) == 0) {
        lastCheckpointMs = nowMs;
        durableEventSequence.store(lastWrittenEventSequence.load(), std::memory_order_release);
      } else {
        abandonActiveChunkAfterUncertainWrite();
        storage->markDiagnosticsSdUnavailable();
        storageErrors.fetch_add(1);
        updateFaultCapsule(Level::Error, "storage", "flush_failed", true);
      }
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      runtime_watchdog_diagnostics::notePhase(
          runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
          runtime_watchdog_diagnostics::Phase::Waiting,
          nextSequence.load(std::memory_order_relaxed));
#endif
    }
    const bool recoveryAllowed = storageRecoveryAllowedProbe == nullptr ||
                                 storageRecoveryAllowedProbe();
    if (recoveryAllowed && storage->canRetryDiagnosticsSd() &&
        static_cast<uint32_t>(nowMs - lastMountAttemptMs) >= 5000U) {
      lastMountAttemptMs = nowMs;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      runtime_watchdog_diagnostics::notePhase(
          runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
          runtime_watchdog_diagnostics::Phase::DiagnosticsRecovery,
          nextSequence.load(std::memory_order_relaxed));
#endif
      storage->ensureDiagnosticsSdMounted();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      runtime_watchdog_diagnostics::notePhase(
          runtime_watchdog_diagnostics::Role::RideDiagnosticsWriter,
          runtime_watchdog_diagnostics::Phase::Waiting,
          nextSequence.load(std::memory_order_relaxed));
#endif
    }
    const bool available = storage->getDiagnosticsSdLoaded();
    const bool wasAvailable =
        lastStorageAvailable.exchange(available, std::memory_order_acq_rel);
    if (available && !wasAvailable)
      (void)flushFaultCapsulesIfPossible();
  }
}

void startWriterTask() {
#if PERSISTENT_RIDE_DIAGNOSTICS
  if (recorderResourcesReady.load(std::memory_order_acquire) &&
      writerTaskHandle == nullptr) {
    // Arduino's SPI FatFs backend can busy-wait for up to its card-response
    // timeout inside fopen()/fflush(). Keep that lowest-priority I/O task off
    // CPU0, whose idle task is covered by the production task watchdog, and
    // let the UI/setup task preempt it on CPU1 while a card is recovering.
    const BaseType_t created = xTaskCreatePinnedToCore(
        writerTask, "ride_diag_writer", 6144, nullptr, 0, &writerTaskHandle, 1);
    recorderWriterReady.store(created == pdPASS, std::memory_order_release);
    if (created != pdPASS) {
      writerTaskHandle = nullptr;
      Serial.println("RIDE_DIAGNOSTICS: recorder_ready=0 reason=writer_task");
      updateFaultCapsule(Level::Error, "logger", "writer_unavailable", false);
    }
  }
#endif
}

bool enqueue(QueuedEvent &event) {
  QueueHandle_t target = event.critical ? criticalQueue : normalQueue;
  if (target == nullptr || queueMutationMutex == nullptr ||
      xSemaphoreTake(queueMutationMutex, 0) != pdTRUE) {
    dropped.fetch_add(1);
    return false;
  }
  // Spilled critical records occupy the tail of the normal queue. Holding
  // normal traffic until they drain preserves the invariant that any
  // noncritical records are at the head and can be evicted safely.
  if (!event.critical &&
      normalQueueCriticalCount.load(std::memory_order_acquire) != 0) {
    xSemaphoreGive(queueMutationMutex);
    dropped.fetch_add(1);
    return false;
  }
  BaseType_t result = xQueueSend(target, &event, 0);
  if (result != pdTRUE && event.critical && normalQueue != nullptr) {
    // Critical records may consume otherwise unused normal capacity. If both
    // lanes are full, evict one lower-priority record before dropping the
    // warning/error/lifecycle evidence that the reserved lane exists to keep.
    const queue_policy::CriticalOverflow overflow =
        queue_policy::criticalOverflow(
            uxQueueSpacesAvailable(normalQueue) > 0,
            static_cast<uint16_t>(uxQueueMessagesWaiting(normalQueue)),
            normalQueueCriticalCount.load(std::memory_order_acquire));
    if (overflow == queue_policy::CriticalOverflow::UseNormal) {
      normalQueueCriticalCount.fetch_add(1, std::memory_order_acq_rel);
      result = xQueueSend(normalQueue, &event, 0);
      if (result != pdTRUE)
        normalQueueCriticalCount.fetch_sub(1, std::memory_order_acq_rel);
    } else if (overflow == queue_policy::CriticalOverflow::EvictNormal) {
      QueuedEvent evicted = {};
      if (xQueueReceive(normalQueue, &evicted, 0) == pdTRUE) {
        if (evicted.critical) {
          // Defensive invariant recovery. Queue mutation is serialized with
          // the writer, so this should be unreachable, but never sacrifice or
          // reorder a protected record if state is found inconsistent.
          (void)xQueueSend(normalQueue, &evicted, 0);
        } else {
          dropped.fetch_add(1);
          normalQueueCriticalCount.fetch_add(1,
                                             std::memory_order_acq_rel);
          result = xQueueSend(normalQueue, &event, 0);
          if (result != pdTRUE)
            normalQueueCriticalCount.fetch_sub(1,
                                               std::memory_order_acq_rel);
        }
      }
    }
  }
  if (result != pdTRUE) {
    xSemaphoreGive(queueMutationMutex);
    dropped.fetch_add(1);
    return false;
  }
  enqueued.fetch_add(1);
  const UBaseType_t depth = queuedDepth();
  uint16_t previous = maxQueueDepth.load();
  while (depth > previous &&
         !maxQueueDepth.compare_exchange_weak(previous,
                                               static_cast<uint16_t>(depth))) {
  }
  xSemaphoreGive(queueMutationMutex);
  return true;
}

bool enqueueFormattedEvent(Level level, const char *category, const char *event,
                           const char *fieldsJson, const char *capture,
                           const char *wallTime, bool hasWallTime,
                           uint32_t uptimeMs, bool clearsFaultCapsule,
                           uint32_t faultBoot, uint32_t faultEventCount,
                           bool rotateBeforeWrite = false,
                           bool rotateAfterWrite = false,
                           uint32_t faultChecksum = 0) {
  const uint32_t sequence = nextSequence.fetch_add(1);
  char detail[320] = {};
  strncpy(detail, fieldsJson + 1, sizeof(detail) - 1);
  const std::size_t detailLength = strlen(detail);
  if (detailLength > 0 && detail[detailLength - 1] == '}')
    detail[detailLength - 1] = '\0';
  const bool hasDetail = detail[0] != '\0';
  QueuedEvent queued = {};
  const int length = snprintf(
      queued.line, sizeof(queued.line),
      "{\"schema\":1,\"source\":\"firmware\",\"sequence\":%lu,\"level\":\"%s\",\"category\":\"%s\",\"event\":\"%s\",\"uptimeMs\":%lu%s%s%s%s%s%s,\"fields\":{\"bootSequence\":%lu,\"firmwareFingerprint\":\"%08lX\"%s%s}}\n",
      static_cast<unsigned long>(sequence), levelName(level), category, event,
      static_cast<unsigned long>(uptimeMs),
      capture[0] == '\0' ? "" : ",\"captureId\":\"", capture,
      capture[0] == '\0' ? "" : "\"",
      hasWallTime ? ",\"wallTime\":\"" : "", wallTime,
      hasWallTime ? "\"" : "",
      static_cast<unsigned long>(bootSequence.load()),
      static_cast<unsigned long>(firmwareFingerprint),
      hasDetail ? "," : "", detail);
  if (length <= 0 || static_cast<std::size_t>(length) >= sizeof(queued.line)) {
    dropped.fetch_add(1);
    return false;
  }
  queued.sequence = sequence;
  std::strncpy(queued.capture, capture, sizeof(queued.capture) - 1);
  if (std::strcmp(category, "user") == 0 && std::strcmp(event, "issue_marker") == 0) {
    const char *marker = std::strstr(fieldsJson, "\"sequence\":");
    if (marker != nullptr)
      queued.issueMarker = static_cast<uint32_t>(std::strtoul(marker + 11, nullptr, 10));
  }
  queued.length = static_cast<uint16_t>(length);
  queued.critical = level == Level::Error || level == Level::Warning || level == Level::Fault ||
                    strcmp(category, "user") == 0 ||
                    strcmp(category, "lifecycle") == 0;
  queued.rotateBeforeWrite = rotateBeforeWrite;
  queued.rotateAfterWrite = rotateAfterWrite;
  queued.clearsFaultCapsule = clearsFaultCapsule;
  queued.faultCapsuleBoot = faultBoot;
  queued.faultCapsuleEventCount = faultEventCount;
  queued.faultCapsuleChecksum = faultChecksum;
  const bool admitted = enqueue(queued);
  if (admitted) observeLiveTail(queued.sequence, queued.line, queued.length);
  return admitted;
}

} // namespace

void begin(Storage &storageRef, uint32_t bootSequenceRef,
           uint32_t firmwareFingerprintRef) {
  storage = &storageRef;
  runtimeBootSequence = bootSequenceRef == 0 ? 1 : bootSequenceRef;
  bootSequence.store(runtimeBootSequence);
  persistentBootSequenceReady.store(false);
  if (storage->getDiagnosticsSdLoaded())
    (void)initializePersistentBootSequenceIfNeeded();
  firmwareFingerprint = firmwareFingerprintRef == 0 ? 1 : firmwareFingerprintRef;
  activeChunk = 1;
  activeChunkSnapshot.store(activeChunk);
  portENTER_CRITICAL(&captureMux);
  captureGeneration = 0;
  portEXIT_CRITICAL(&captureMux);
  activePath[0] = '\0';
  nextSequence.store(0);
  retentionPrunedThisBoot.store(false, std::memory_order_release);
  normalQueueCriticalCount.store(0, std::memory_order_release);
  clockAnchorEmitted.store(false);
  checkpointRequested.store(false);
#if DETAILED_RIDE_DIAGNOSTICS
  detailedCapture.store(false);
#endif
  lastMarkerSequence.store(0);
#if PERSISTENT_RIDE_DIAGNOSTICS
  faultCapsuleGeneration.store(0, std::memory_order_release);
  faultCapsuleQueuedGeneration.store(UINT32_MAX, std::memory_order_release);
  pendingFaultCapsuleQueuedChecksum.store(0, std::memory_order_release);
  currentFaultCapsuleQueuedChecksum.store(0, std::memory_order_release);
  initializeFaultCapsules();
  lastStorageAvailable.store(storage->getDiagnosticsSdLoaded(),
                             std::memory_order_release);
  if (normalQueue == nullptr) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    normalQueue = createEventQueue(kNormalQueueCapacity, normalQueueEvents,
                                   normalQueueControl);
#else
    normalQueue = xQueueCreate(kNormalQueueCapacity, sizeof(QueuedEvent));
#endif
  }
  if (criticalQueue == nullptr) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    criticalQueue = createEventQueue(kCriticalQueueCapacity,
                                     criticalQueueEvents, criticalQueueControl);
#else
    criticalQueue = xQueueCreate(kCriticalQueueCapacity, sizeof(QueuedEvent));
#endif
  }
  if (producerMutex == nullptr)
    producerMutex = xSemaphoreCreateMutex();
  if (queueMutationMutex == nullptr)
    queueMutationMutex = xSemaphoreCreateMutex();
  if (faultCapsuleFlushMutex == nullptr)
    faultCapsuleFlushMutex = xSemaphoreCreateMutex();
  if (sealComplete == nullptr)
    sealComplete = xSemaphoreCreateBinary();
  if (retentionMutex == nullptr)
    retentionMutex = xSemaphoreCreateMutex();
  const bool resourcesReady = normalQueue != nullptr && criticalQueue != nullptr &&
      producerMutex != nullptr && queueMutationMutex != nullptr &&
      faultCapsuleFlushMutex != nullptr && sealComplete != nullptr &&
      retentionMutex != nullptr;
  recorderResourcesReady.store(resourcesReady, std::memory_order_release);
  if (!resourcesReady) {
    Serial.println("RIDE_DIAGNOSTICS: recorder_ready=0 reason=resources");
    updateFaultCapsule(Level::Error, "logger", "resources_unavailable", false);
    return;
  }
  char fields[320] = {};
  snprintf(fields, sizeof(fields),
           "{\"runtimeBootSequence\":%lu,\"firmwareTarget\":\"%s\",\"firmwareBuild\":%lu}",
           static_cast<unsigned long>(runtimeBootSequence),
           firmware_metadata::target(),
           static_cast<unsigned long>(firmware_metadata::build()));
  record(Level::Info, "boot", "recorder_started", fields);
  restoreCapturePolicy();
  (void)flushFaultCapsulesIfPossible();
#else
  (void)storageRef;
  (void)bootSequenceRef;
  (void)firmwareFingerprintRef;
#endif
}

void startWriter() {
#if PERSISTENT_RIDE_DIAGNOSTICS
  startWriterTask();
#endif
}

bool recorderReady() {
  return recorderResourcesReady.load(std::memory_order_acquire) &&
         recorderWriterReady.load(std::memory_order_acquire);
}

void setStorageRecoveryAllowedProbe(StorageRecoveryAllowedProbe probe) {
  storageRecoveryAllowedProbe = probe;
}

void process(uint32_t nowMs) {
#if PERSISTENT_RIDE_DIAGNOSTICS
  portENTER_CRITICAL(&policyMux);
  const bool policyExpired = runtimePolicy.expire(nowMs);
  const bool detailedPolicy = runtimePolicy.detailed(nowMs);
  const auto policyCounts = runtimePolicy.counters();
  portEXIT_CRITICAL(&policyMux);
  if (policyExpired)
    (void)record(Level::Info, "capture", "policy_expired", "{}");
  if (static_cast<uint32_t>(nowMs - lastPolicyHealthMs) >= 30000U) {
    lastPolicyHealthMs = nowMs;
    char fields[160] = {};
    std::snprintf(fields, sizeof(fields), "{\"filteredCount\":%lu,\"rateLimitedCount\":%lu}",
                  static_cast<unsigned long>(policyCounts.filtered),
                  static_cast<unsigned long>(policyCounts.rateLimited));
    (void)record(Level::Info, "logger", "policy_health", fields);
  }
  if (detailedPolicy && static_cast<uint32_t>(nowMs - lastMemorySampleMs) >= 1000U) {
    lastMemorySampleMs = nowMs;
    char fields[180] = {};
    std::snprintf(fields, sizeof(fields),
       "{\"freeInternalBytes\":%lu,\"largestInternalBytes\":%lu,\"freePsramBytes\":%lu}",
       static_cast<unsigned long>(heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)),
       static_cast<unsigned long>(heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)),
       static_cast<unsigned long>(heap_caps_get_free_size(MALLOC_CAP_SPIRAM)));
    (void)record(Level::Debug, "memory", "heap_snapshot", fields);
  }
#endif
#if PERSISTENT_RIDE_DIAGNOSTICS && DETAILED_RIDE_DIAGNOSTICS
  // The writer task owns file handles. This hook is intentionally tiny so it
  // can be called from the LVGL loop without adding storage latency there.
  const DetailedCaptureLease lease = detailedCaptureLease();
  if (lease.active &&
      capture_policy::detailedCaptureExpired(nowMs, lease.deadlineMs)) {
    // The bind may be replaced while the expiry record is queued. Only the
    // exact lease that was observed may be revoked.
    if (clearCaptureIfMatches(lease)) {
      (void)record(Level::Warning, "lifecycle", "detailed_capture_expired",
                   "{\"durationLimit\":\"4h\"}");
    }
  }
#else
  (void)nowMs;
#endif
}

bool enqueueEventWithProducerLockHeld(
    Level level, const char *category, const char *event,
    const char *fieldsJson, bool clearsFaultCapsule, uint32_t faultBoot,
    uint32_t faultEventCount, const char *captureOverride = nullptr,
    bool rotateBeforeWrite = false, bool rotateAfterWrite = false,
    uint32_t faultChecksum = 0) {
  char capture[48] = {};
  bool pendingBoundary = false;
  if (captureOverride != nullptr) {
    strncpy(capture, captureOverride, sizeof(capture) - 1);
    pendingBoundary =
        captureBoundaryPending.load(std::memory_order_acquire);
  } else {
    portENTER_CRITICAL(&captureMux);
    strncpy(capture, activeCapture, sizeof(capture) - 1);
    capture[sizeof(capture) - 1] = '\0';
    pendingBoundary =
        captureBoundaryPending.load(std::memory_order_relaxed);
    portEXIT_CRITICAL(&captureMux);
  }
  char wallTime[32] = {};
  const bool hasWallTime = utcNow(wallTime, sizeof(wallTime));
  const uint32_t uptimeMs = millis();
  bool rotateBefore = rotateBeforeWrite || pendingBoundary;
  if (hasWallTime && strcmp(event, "clock_anchor") != 0 &&
      !clockAnchorEmitted.exchange(true)) {
    const bool anchorEnqueued = enqueueFormattedEvent(
            Level::Info, "lifecycle", "clock_anchor",
            "{\"clockSynchronized\":true}", capture, wallTime, true,
            uptimeMs, false, 0, 0, rotateBefore);
    if (!anchorEnqueued) {
      clockAnchorEmitted.store(false);
    } else if (rotateBefore) {
      captureBoundaryPending.store(false, std::memory_order_release);
      rotateBefore = false;
    }
  }
  const bool enqueued = enqueueFormattedEvent(
      level, category, event, fieldsJson, capture, wallTime, hasWallTime,
      uptimeMs, clearsFaultCapsule, faultBoot, faultEventCount,
      rotateBefore, rotateAfterWrite, faultChecksum);
  if (enqueued && rotateBefore)
    captureBoundaryPending.store(false, std::memory_order_release);
  return enqueued;
}

bool recordInternal(Level level, const char *category, const char *event,
                    const char *fieldsJson, bool clearsFaultCapsule,
                    uint32_t faultBoot, uint32_t faultEventCount,
                    uint32_t faultChecksum) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)level;
  (void)category;
  (void)event;
  (void)fieldsJson;
  return false;
#else
  bicino_diagnostics::Severity severity = bicino_diagnostics::Severity::Info;
  switch (level) {
    case Level::Trace: severity = bicino_diagnostics::Severity::Trace; break;
    case Level::Debug: severity = bicino_diagnostics::Severity::Debug; break;
    case Level::Info: break;
    case Level::Warning: severity = bicino_diagnostics::Severity::Warning; break;
    case Level::Error: severity = bicino_diagnostics::Severity::Error; break;
    case Level::Fault: severity = bicino_diagnostics::Severity::Fault; break;
  }
  portENTER_CRITICAL(&policyMux);
  const bool legacyAutomation = legacyDetailedCapture.load(std::memory_order_relaxed) &&
      detailedCaptureEnabled() && category != nullptr && std::strcmp(category, "rideAutomation") == 0 &&
      severity == bicino_diagnostics::Severity::Debug;
  const bool admitted = legacyAutomation || runtimePolicy.admit(severity, category, kMaximumEventBytes, millis());
  portEXIT_CRITICAL(&policyMux);
  if (!admitted) return false;
  if (!validToken(category, 32) || !validToken(event, 64)) {
    dropped.fetch_add(1);
    return false;
  }
  const std::size_t fieldsLength =
      fieldsJson == nullptr ? 0 : strnlen(fieldsJson, 320);
  if (fieldsLength < 2 || fieldsLength >= 320 || fieldsJson[0] != '{' ||
      fieldsJson[fieldsLength - 1] != '}' ||
      strchr(fieldsJson, '\n') != nullptr || strchr(fieldsJson, '\r') != nullptr) {
    dropped.fetch_add(1);
    return false;
  }
  if (!validateFieldsJson(fieldsJson, fieldsLength)) {
    dropped.fetch_add(1);
    return false;
  }
  if (storage == nullptr ||
      (!storage->getDiagnosticsSdLoaded() &&
       !storageTransitionRequested.load(std::memory_order_acquire))) {
    dropped.fetch_add(1);
    storageErrors.fetch_add(1);
    updateFaultCapsule(level, category, event, true);
    return false;
  }
  if (producerMutex == nullptr ||
      xSemaphoreTake(producerMutex, 0) != pdTRUE) {
    dropped.fetch_add(1);
    updateFaultCapsule(level, category, event, false);
    return false;
  }
  if (!initializePersistentBootSequenceIfNeeded()) {
    xSemaphoreGive(producerMutex);
    dropped.fetch_add(1);
    storageErrors.fetch_add(1);
    updateFaultCapsule(level, category, event, true);
    return false;
  }
  const bool enqueuedEvent = enqueueEventWithProducerLockHeld(
      level, category, event, fieldsJson, clearsFaultCapsule, faultBoot,
      faultEventCount, nullptr, false, false, faultChecksum);
  xSemaphoreGive(producerMutex);
  if (!enqueuedEvent) {
    updateFaultCapsule(level, category, event, false);
    return false;
  }
  return true;
#endif
}

bool record(Level level, const char *category, const char *event,
            const char *fieldsJson) {
  return recordInternal(level, category, event, fieldsJson, false, 0, 0);
}

bool recordHealth(const char *reason) {
  if (reason == nullptr || !validToken(reason, 32))
    return false;
  const Stats snapshot = stats();
  char fields[320] = {};
  if (!detail::formatHealthFields(snapshot, reason, fields, sizeof(fields)))
    return false;
  return record(Level::Info, "logger", "health", fields);
}

bool recordClockAnchor() {
  const bool recorded = record(
      Level::Info, "lifecycle", "clock_anchor",
      "{\"clockSynchronized\":true}");
  if (recorded)
    clockAnchorEmitted.store(true);
  return recorded;
}

bool markIssue(const char *code, uint32_t markerSequence) {
  if (!validIssueCode(code) || markerSequence == 0 ||
      !control::markerSequenceCanAdvance(lastMarkerSequence.load(),
                                         markerSequence))
    return false;
  char fields[96] = {};
  snprintf(fields, sizeof(fields), "{\"code\":\"%s\",\"sequence\":%lu}",
           code, static_cast<unsigned long>(markerSequence));
  if (!record(Level::Warning, "user", "issue_marker", fields))
    return false;
  lastMarkerSequence.store(markerSequence);
  checkpointRequested.store(true);
  return true;
}

bool bindCaptureInternal(const char *captureID, bool detailed) {
  if (!validCaptureID(captureID))
    return false;
#if !defined(RIDE_AUTOMATION_SHADOW) || !DETAILED_RIDE_DIAGNOSTICS
  if (detailed)
    return false;
#endif
#if !DETAILED_RIDE_DIAGNOSTICS
  detailed = false;
#endif
  char previousCapture[48] = {};
  // The desired capture/mode is session state, not a storage operation. Apply
  // it even while the SD writer is busy or the card is temporarily absent;
  // the first successfully queued record will enforce the pending boundary.
  portENTER_CRITICAL(&captureMux);
#if DETAILED_RIDE_DIAGNOSTICS
  const bool previousDetailed =
      detailedCapture.load(std::memory_order_relaxed);
  strncpy(previousCapture, activeCapture, sizeof(previousCapture) - 1);
  const bool requiresBoundary = control::bindingRequiresChunkBoundary(
      previousCapture,
      previousDetailed ? control::CaptureMode::Detailed
                       : control::CaptureMode::Standard,
      captureID,
      detailed ? control::CaptureMode::Detailed
               : control::CaptureMode::Standard);
#else
  strncpy(previousCapture, activeCapture, sizeof(previousCapture) - 1);
  const bool requiresBoundary =
      std::strcmp(previousCapture, captureID) != 0;
#endif
  if (requiresBoundary)
    captureBoundaryPending.store(true, std::memory_order_relaxed);
  strncpy(activeCapture, captureID, sizeof(activeCapture) - 1);
  activeCapture[sizeof(activeCapture) - 1] = '\0';
  ++captureGeneration;
  if (captureGeneration == 0)
    captureGeneration = 1;
#if DETAILED_RIDE_DIAGNOSTICS
  const uint32_t nextDetailedDeadline =
      capture_policy::detailedCaptureDeadlineAfterBinding(
          millis(),
          detailedCaptureDeadlineMs.load(std::memory_order_relaxed),
          requiresBoundary, detailed);
  detailedCaptureDeadlineMs.store(nextDetailedDeadline,
                                  std::memory_order_relaxed);
  detailedCapture.store(detailed, std::memory_order_relaxed);
#endif
  if (std::strcmp(previousCapture, captureID) != 0)
    durableMarkerSequence.store(0, std::memory_order_relaxed);
  const uint32_t previousMarkerSequence = lastMarkerSequence.load();
  lastMarkerSequence.store(control::markerSequenceAfterBinding(
      previousCapture, captureID, previousMarkerSequence));
  portEXIT_CRITICAL(&captureMux);
  if (storage != nullptr && storage->getDiagnosticsSdLoaded() &&
      producerMutex != nullptr &&
      xSemaphoreTake(producerMutex, 0) == pdTRUE) {
    const bool ready = initializePersistentBootSequenceIfNeeded();
    const bool enqueued = ready && enqueueEventWithProducerLockHeld(
        Level::Info, "transfer", "capture_bound",
#if DETAILED_RIDE_DIAGNOSTICS
        detailed ? "{\"active\":true}" : "{\"active\":false}",
#else
        "{\"active\":false}",
#endif
        false, 0, 0, captureID);
    xSemaphoreGive(producerMutex);
    if (!enqueued)
      updateFaultCapsule(Level::Warning, "transfer", "capture_bound", false);
  } else {
    updateFaultCapsule(Level::Warning, "transfer", "capture_bound",
                       storage == nullptr ||
                           !storage->getDiagnosticsSdLoaded());
  }
  return true;
}

bool bindCapture(const char *captureID, bool detailed) {
  if (!validCaptureID(captureID)) return false;
  // Legacy owners deliberately replace any v2 policy. A later reconnect must
  // not resurrect a previously persisted detailed request.
  revokeCapturePolicy();
  legacyDetailedCapture.store(detailed, std::memory_order_release);
  return bindCaptureInternal(captureID, detailed);
}

bool clearCaptureInternal(const DetailedCaptureLease *expected) {
  char previousCapture[48] = {};
  // Once the expected lease still matches, revocation is unconditional.
  // Boundary evidence is durable best-effort, but a contended queue must
  // never leave the matching detailed telemetry active.
  portENTER_CRITICAL(&captureMux);
#if DETAILED_RIDE_DIAGNOSTICS
  if (expected != nullptr &&
      !capture_policy::detailedCaptureLeaseMatches(
          activeCapture, captureGeneration,
          detailedCaptureDeadlineMs.load(std::memory_order_relaxed),
          expected->captureId, expected->generation,
          expected->deadlineMs)) {
    portEXIT_CRITICAL(&captureMux);
    return false;
  }
#else
  (void)expected;
#endif
  strncpy(previousCapture, activeCapture, sizeof(previousCapture) - 1);
  activeCapture[0] = '\0';
  durableMarkerSequence.store(0, std::memory_order_relaxed);
#if DETAILED_RIDE_DIAGNOSTICS
  detailedCaptureDeadlineMs.store(0, std::memory_order_relaxed);
  detailedCapture.store(false, std::memory_order_relaxed);
#endif
  lastMarkerSequence.store(0, std::memory_order_relaxed);
  ++captureGeneration;
  if (captureGeneration == 0)
    captureGeneration = 1;
  portEXIT_CRITICAL(&captureMux);
  checkpointRequested.store(true);
  if (previousCapture[0] == '\0')
    return true;
  bool enqueued = false;
  if (producerMutex != nullptr &&
      xSemaphoreTake(producerMutex, 0) == pdTRUE) {
    if (initializePersistentBootSequenceIfNeeded()) {
      enqueued = enqueueEventWithProducerLockHeld(
          Level::Warning, "transfer", "capture_ended", "{}", false, 0,
          0, previousCapture, false, true);
    }
    xSemaphoreGive(producerMutex);
  }
  if (!enqueued) {
    captureBoundaryPending.store(true, std::memory_order_release);
    updateFaultCapsule(Level::Warning, "transfer", "capture_ended",
                       storage == nullptr ||
                           !storage->getDiagnosticsSdLoaded());
  }
  return true;
}

void clearCapture() {
  revokeCapturePolicy();
  legacyDetailedCapture.store(false, std::memory_order_release);
  (void)clearCaptureInternal(nullptr);
}

DetailedCaptureLease detailedCaptureLease() {
#if !DETAILED_RIDE_DIAGNOSTICS
  return {};
#else
  DetailedCaptureLease lease;
  portENTER_CRITICAL(&captureMux);
  lease.active = detailedCapture.load(std::memory_order_relaxed);
  lease.generation = captureGeneration;
  lease.deadlineMs = detailedCaptureDeadlineMs.load(std::memory_order_relaxed);
  strncpy(lease.captureId, activeCapture, sizeof(lease.captureId) - 1);
  lease.captureId[sizeof(lease.captureId) - 1] = '\0';
  portEXIT_CRITICAL(&captureMux);
  return lease;
#endif
}

bool clearCaptureIfMatches(const DetailedCaptureLease &lease) {
#if !DETAILED_RIDE_DIAGNOSTICS
  (void)lease;
  return false;
#else
  if (!lease.active)
    return false;
  return clearCaptureInternal(&lease);
#endif
}

const char *captureId() { return activeCapture; }

bool detailedCaptureEnabled() {
#if !DETAILED_RIDE_DIAGNOSTICS
  return false;
#else
  portENTER_CRITICAL(&captureMux);
  const bool detailed = detailedCapture.load(std::memory_order_relaxed);
  const uint32_t deadline =
      detailedCaptureDeadlineMs.load(std::memory_order_relaxed);
  portEXIT_CRITICAL(&captureMux);
  if (!detailed)
    return false;
  return !capture_policy::detailedCaptureExpired(millis(), deadline);
#endif
}

transfer_policy::SealPreparation
sealActiveChunkForTransfer(uint32_t timeoutMs) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)timeoutMs;
  return transfer_policy::SealPreparation::RecorderUnavailable;
#else
  const uint32_t startedMs = millis();
  const auto remainingMs = [startedMs, timeoutMs]() -> uint32_t {
    const uint32_t elapsed = static_cast<uint32_t>(millis() - startedMs);
    return elapsed >= timeoutMs ? 0 : timeoutMs - elapsed;
  };
  if (writerTaskHandle == nullptr || producerMutex == nullptr ||
      sealComplete == nullptr || storage == nullptr) {
    return transfer_policy::SealPreparation::RecorderUnavailable;
  }
  if (!storage->getDiagnosticsSdLoaded())
    return transfer_policy::SealPreparation::StorageUnavailable;

  // Producers deliberately use a non-blocking mutex and record a retained gap
  // when they race the seal. Converge those transient races inside this one
  // bounded request instead of rejecting the download and requiring the user
  // to press the button again.
  while (remainingMs() > 0) {
    while (faultCapsuleGeneration.load(std::memory_order_acquire) !=
           faultCapsuleQueuedGeneration.load(std::memory_order_acquire)) {
      if (flushFaultCapsulesIfPossible())
        continue;
      if (remainingMs() == 0)
        return transfer_policy::SealPreparation::SealFailed;
      vTaskDelay(pdMS_TO_TICKS(5));
    }

    const uint32_t producerWaitMs = remainingMs();
    if (producerWaitMs == 0 ||
        xSemaphoreTake(producerMutex, pdMS_TO_TICKS(producerWaitMs)) !=
            pdTRUE) {
      return transfer_policy::SealPreparation::DrainTimeout;
    }
    // A callback may have recorded a gap between the capsule flush and this
    // lock acquisition. Release and converge it instead of failing one-shot.
    if (faultCapsuleGeneration.load(std::memory_order_acquire) !=
        faultCapsuleQueuedGeneration.load(std::memory_order_acquire)) {
      xSemaphoreGive(producerMutex);
      continue;
    }
    if (!initializePersistentBootSequenceIfNeeded()) {
      xSemaphoreGive(producerMutex);
      return transfer_policy::SealPreparation::SealFailed;
    }
    // Join a predecessor that timed out while the writer was already closing,
    // then publish a new cutoff. Storage is never torn down under that writer.
    while (sealRequested.load(std::memory_order_acquire)) {
      if (remainingMs() == 0) {
        xSemaphoreGive(producerMutex);
        return transfer_policy::SealPreparation::DrainTimeout;
      }
      vTaskDelay(pdMS_TO_TICKS(5));
    }
    while (xSemaphoreTake(sealComplete, 0) == pdTRUE) {
    }
    sealPreparationResult.store(transfer_policy::SealPreparation::SealFailed,
                                std::memory_order_release);
    sealSequenceCutoff.store(nextSequence.load(), std::memory_order_release);
    // Publish only after the cutoff/result/completion slot describe this
    // exact request. The writer re-peeks both priority queues afterward.
    sealRequested.store(true, std::memory_order_release);
    xSemaphoreGive(producerMutex);

    const uint32_t completionWaitMs = remainingMs();
    if (completionWaitMs == 0 ||
        xSemaphoreTake(sealComplete, pdMS_TO_TICKS(completionWaitMs)) !=
            pdTRUE) {
      // The writer still owns an in-flight close. A later request must join
      // it rather than consuming this request's eventual completion signal.
      return transfer_policy::SealPreparation::DrainTimeout;
    }
    const transfer_policy::SealPreparation result =
        sealPreparationResult.load(std::memory_order_acquire);
    if (!transfer_policy::sealReady(result))
      return result;
    if (faultCapsuleGeneration.load(std::memory_order_acquire) ==
        faultCapsuleQueuedGeneration.load(std::memory_order_acquire)) {
      return transfer_policy::SealPreparation::Ready;
    }
    // A producer raced the just-completed seal. The next loop persists that
    // bounded gap into a new chunk and seals it within the same deadline.
  }
  return transfer_policy::SealPreparation::DrainTimeout;
#endif
}

bool sealActiveChunk(uint32_t timeoutMs) {
  return transfer_policy::sealReady(sealActiveChunkForTransfer(timeoutMs));
}

bool beginStorageTransition(uint32_t timeoutMs) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)timeoutMs;
  return true;
#else
  if (storageTransitionRequested.exchange(true,
                                          std::memory_order_acq_rel)) {
    return false;
  }
  if (storage == nullptr || !storage->getDiagnosticsSdLoaded())
    return true;
  if (sealActiveChunk(timeoutMs))
    return true;
  storageTransitionRequested.store(false, std::memory_order_release);
  return false;
#endif
}

void endStorageTransition() {
  storageTransitionRequested.store(false, std::memory_order_release);
}

bool prepareForShutdown(uint32_t timeoutMs) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)timeoutMs;
  return true;
#else
  (void)recordHealth("shutdown");
  (void)record(Level::Warning, "lifecycle", "controlled_shutdown", "{}");
  checkpointRequested.store(true);
  // This is a one-way storage transition. Once shutdown begins, keep the
  // writer paused after its seal through peripheral power-off/deep sleep so a
  // post-cutoff producer cannot reopen a FILE beneath SPI teardown.
  storageTransitionRequested.store(true, std::memory_order_release);
  const bool sealed = sealActiveChunk(timeoutMs);
  if (!sealed)
    updateFaultCapsule(Level::Error, "lifecycle",
                       "controlled_shutdown_unsealed", true);
  return sealed;
#endif
}

void armTransferSnapshotLease(uint32_t durationMs) {
  const uint32_t bounded = std::min<uint32_t>(
      std::max<uint32_t>(durationMs, 30U * 1000U), 15U * 60U * 1000U);
  uint32_t deadline = millis() + bounded;
  if (deadline == 0)
    deadline = 1;
  // Publish the lease without waiting behind a retention scan. The writer is
  // the sole pruning owner, and a transfer seal cannot complete until any
  // scan that started before this store has returned to the writer loop.
  // Every later prune observes the lease before touching closed chunks. This
  // lets diagnostics acquire the snapshot boundary before requesting its
  // seal, rather than putting a full retained-directory scan inside the
  // bounded seal deadline.
  retentionLeaseDeadlineMs.store(deadline, std::memory_order_release);
}

void beginTransferSnapshotLease(uint32_t durationMs) {
  // Index creation has no writer-owned seal to serve as its synchronization
  // point, so wait for any pre-existing prune before refreshing the lease and
  // enumerating closed chunks.
  SemaphoreGuard retentionGuard(retentionMutex);
  armTransferSnapshotLease(durationMs);
}

void refreshTransferSnapshotLease(uint32_t durationMs) {
  beginTransferSnapshotLease(durationMs);
}

void endTransferSnapshotLease() {
  retentionLeaseDeadlineMs.store(0, std::memory_order_release);
}

Stats stats() {
  return {
      enqueued.load(),
      written.load(),
      dropped.load(),
      storageErrors.load(),
      queuedDepth(),
      maxQueueDepth.load(),
      storage != nullptr && storage->getDiagnosticsSdLoaded(),
      recorderReady(),
  };
}

uint32_t currentBootSequence() { return bootSequence.load(); }

uint32_t currentActiveChunk() { return activeChunkSnapshot.load(); }

bool isClosedChunk(uint32_t boot, uint32_t chunk) {
  const uint32_t selectedBootSequence = bootSequence.load();
  if (boot == 0 || chunk == 0 || boot > selectedBootSequence)
    return false;
  if (boot < selectedBootSequence)
    return true;
  return chunk < activeChunkSnapshot.load();
}

namespace {
void revokeCapturePolicy() {
  portENTER_CRITICAL(&policyMux);
  runtimePolicy.stop();
  if (pendingPolicyCommand[0] != '\0') {
    std::memset(pendingPolicyCommand, 0, sizeof(pendingPolicyCommand));
    policyPersistencePending.store(true, std::memory_order_release);
    policyPersisted.store(false, std::memory_order_release);
  }
  portEXIT_CRITICAL(&policyMux);
}
void persistCapturePolicyIfNeeded() {
  if (!policyPersistencePending.load(std::memory_order_acquire) ||
      static_cast<uint32_t>(millis() - lastPolicyPersistAttemptMs) < 1000U) return;
  lastPolicyPersistAttemptMs = millis();
  char command[161] = {};
  portENTER_CRITICAL(&policyMux);
  std::memcpy(command, pendingPolicyCommand, sizeof(command));
  portEXIT_CRITICAL(&policyMux);
  Preferences preferences;
  const bool opened = preferences.begin("bicino-diag-v2", false);
  const bool saved = opened && (command[0] == '\0'
      ? (!preferences.isKey("capture") || preferences.remove("capture"))
      : preferences.putString("capture", command) == std::strlen(command));
  if (opened) preferences.end();
  portENTER_CRITICAL(&policyMux);
  if (saved && std::strcmp(command, pendingPolicyCommand) == 0) {
    policyPersistencePending.store(false, std::memory_order_release);
    policyPersisted.store(true, std::memory_order_release);
  }
  portEXIT_CRITICAL(&policyMux);
}
void restoreCapturePolicy() {
  Preferences preferences;
  if (!preferences.begin("bicino-diag-v2", true)) return;
  char retained[161] = {};
  const std::size_t size = preferences.getStringLength("capture");
  const bool read = size > 1 && size <= sizeof(retained) &&
      preferences.getString("capture", retained, sizeof(retained)) == size;
  preferences.end();
  if (read) (void)bindCapturePolicyV2(std::string(retained), true);
}
} // namespace

bool bindCapturePolicyV2(const std::string &command, bool restoring) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)command; (void)restoring;
  return false;
#else
  bicino_diagnostics::CaptureRequest request;
  if (!bicino_diagnostics::parseCaptureRequest(command, request)) return false;
  const time_t wall = std::time(nullptr);
  const uint32_t epoch = wall >= 1700000000 && static_cast<uint64_t>(wall) <= UINT32_MAX
                             ? static_cast<uint32_t>(wall) : 0;
  portENTER_CRITICAL(&policyMux);
  const auto result = runtimePolicy.apply(request, millis(), epoch);
  if (result == bicino_diagnostics::ApplyResult::Applied) {
    if (restoring && epoch == 0) runtimePolicy.stop();
    std::memset(pendingPolicyCommand, 0, sizeof(pendingPolicyCommand));
    std::memcpy(pendingPolicyCommand, command.data(), command.size());
    policyPersistencePending.store(!restoring, std::memory_order_release);
    policyPersisted.store(restoring, std::memory_order_release);
  }
  const auto effective = runtimePolicy.effectiveLevels(millis());
  portEXIT_CRITICAL(&policyMux);
  if (result != bicino_diagnostics::ApplyResult::Applied &&
      result != bicino_diagnostics::ApplyResult::Duplicate) return false;
  legacyDetailedCapture.store(false, std::memory_order_release);
  const int automationDomain = bicino_diagnostics::domainIndex("rideAutomation");
  const bool automationDetailed = automationDomain >= 0 && effective[automationDomain] < 2;
  if (result == bicino_diagnostics::ApplyResult::Applied && !bindCaptureInternal(
          request.captureId,
#if DETAILED_RIDE_DIAGNOSTICS
          automationDetailed
#else
          false
#endif
          )) return false;
  (void)automationDetailed;
  if (restoring && epoch == 0)
    (void)record(Level::Warning, "capture", "clock_unavailable_on_restore",
                 "{\"reason\":\"baseline_only\"}");
  return true;
#endif
}

std::string capturePolicyStatusV2() {
  const uint32_t now = millis();
  portENTER_CRITICAL(&policyMux);
  const auto request = runtimePolicy.request();
  const auto effective = runtimePolicy.effectiveLevels(now);
  const auto counts = runtimePolicy.counters();
  const uint32_t remaining = runtimePolicy.remainingSeconds(now);
  const bool persisted = policyPersisted.load(std::memory_order_relaxed);
  portEXIT_CRITICAL(&policyMux);
  std::string levels;
  levels.reserve(effective.size());
  for (auto level : effective) levels += static_cast<char>('0' + level);
  char body[640] = {};
  std::snprintf(body, sizeof(body),
      "{\"schema\":2,\"contractSHA256\":\"%s\",\"captureID\":\"%s\","
      "\"generation\":%lu,\"effectiveLevels\":\"%s\",\"remainingSeconds\":%lu,"
      "\"filtered\":%lu,\"rateLimited\":%lu,\"durableSequence\":%lu,"
      "\"markerQueued\":%lu,\"markerDurable\":%lu,\"policyPersisted\":%s,"
      "\"detailedAutomationAvailable\":%s,\"crashAvailable\":false}",
      bicino_diagnostics::contract::kSha256, request.captureId,
      static_cast<unsigned long>(request.generation), levels.c_str(),
      static_cast<unsigned long>(remaining), static_cast<unsigned long>(counts.filtered),
      static_cast<unsigned long>(counts.rateLimited), static_cast<unsigned long>(durableEventSequence.load()),
      static_cast<unsigned long>(std::max(lastMarkerSequence.load(), durableMarkerSequence.load())), static_cast<unsigned long>(durableMarkerSequence.load()),
      persisted ? "true" : "false",
#if DETAILED_RIDE_DIAGNOSTICS
      "true"
#else
      "false"
#endif
      );
  return std::string(body);
}

bool markIssueV2(const char *code, uint32_t markerSequence, const char *incidentId) {
  if (!validIssueCode(code) || !bicino_diagnostics::validUuid(incidentId) ||
      !control::markerSequenceCanAdvance(lastMarkerSequence.load(), markerSequence)) return false;
  char fields[160] = {};
  std::snprintf(fields, sizeof(fields), "{\"code\":\"%s\",\"sequence\":%lu,\"incidentId\":\"%s\"}",
                code, static_cast<unsigned long>(markerSequence), incidentId);
  if (!record(Level::Warning, "user", "issue_marker", fields)) return false;
  lastMarkerSequence.store(markerSequence);
  checkpointRequested.store(true);
  return true;
}

// One explicit owner-authenticated read arms a 30-second in-memory observation
// window. It never changes persistent capture or enters disruptive Wi-Fi mode.
bool requestLiveTailV2(const std::string &command) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)command; return false;
#else
  bicino_diagnostics::TailRequest request;
  if (!bicino_diagnostics::parseTailRequest(command, request)) return false;
  if (liveTailMutex == nullptr) liveTailMutex = xSemaphoreCreateMutex();
  if (liveTailMutex == nullptr || xSemaphoreTake(liveTailMutex, pdMS_TO_TICKS(5)) != pdTRUE) return false;
  if (liveTail == nullptr) {
    void *memory = heap_caps_malloc(sizeof(LiveTail), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (memory != nullptr) { liveTail = new (memory) LiveTail(); liveTail->begin(bootSequence.load()); }
  }
  if (liveTail == nullptr) { xSemaphoreGive(liveTailMutex); return false; }
  pendingLiveTail = request; liveTailPending.store(true, std::memory_order_release);
  liveTailDeadlineMs.store(millis() + 30000U, std::memory_order_release);
  xSemaphoreGive(liveTailMutex);
  return true;
#endif
}

std::string takeLiveTailStatusV2() {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  return {};
#else
  if (!liveTailPending.load(std::memory_order_acquire) || liveTailMutex == nullptr) return {};
  auto *page = static_cast<LiveTail::Page *>(heap_caps_calloc(1, sizeof(LiveTail::Page), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (page == nullptr) return {};
  new (page) LiveTail::Page();
  if (xSemaphoreTake(liveTailMutex, pdMS_TO_TICKS(5)) != pdTRUE) { heap_caps_free(page); return {}; }
  const auto request = pendingLiveTail;
  if (liveTail == nullptr || !liveTailPending.exchange(false)) {
    xSemaphoreGive(liveTailMutex); heap_caps_free(page); return {};
  }
  liveTail->page(request, *page);
  xSemaphoreGive(liveTailMutex);
  char header[512] = {};
  std::snprintf(header, sizeof(header),
    "{\"schema\":2,\"source\":\"firmware\",\"bootSequence\":%lu,\"requestedBoot\":%lu,"
    "\"requestedAfter\":%lu,\"nextSequence\":%lu,\"oldestSequence\":%lu,\"newestSequence\":%lu,"
    "\"bootChanged\":%s,\"gap\":%s,\"more\":%s,\"liveDropped\":%lu,"
    "\"durableSequence\":%lu,\"durableSequenceValid\":%s,\"events\":[",
    static_cast<unsigned long>(page->boot), static_cast<unsigned long>(request.boot),
    static_cast<unsigned long>(request.after), static_cast<unsigned long>(page->next),
    static_cast<unsigned long>(page->oldest), static_cast<unsigned long>(page->newest),
    page->bootChanged ? "true" : "false", page->gap ? "true" : "false", page->more ? "true" : "false",
    static_cast<unsigned long>(liveTailDropped.load()), static_cast<unsigned long>(durableEventSequence.load()),
    durableSequenceValid.load() ? "true" : "false");
  std::string body(header);
  body.reserve(512 + page->count * kMaximumEventBytes);
  for (std::size_t i = 0; i < page->count; ++i) {
    if (i != 0) body += ',';
    body.append(page->events[i].line, page->events[i].length - 1);
  }
  body += "]}";
  heap_caps_free(page);
  return body;
#endif
}

} // namespace ride_diagnostics
