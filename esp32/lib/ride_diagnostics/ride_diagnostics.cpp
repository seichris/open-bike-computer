#include "ride_diagnostics.hpp"
#include "ride_diagnostics_format.hpp"
#include "ride_diagnostics_queue_policy.hpp"

#include <Arduino.h>
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

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "../boot_diagnostics/boot_diagnostics.hpp"
#endif

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#ifndef PERSISTENT_RIDE_DIAGNOSTICS
#define PERSISTENT_RIDE_DIAGNOSTICS 0
#endif

namespace ride_diagnostics {

bool recordInternal(Level level, const char *category, const char *event,
                    const char *fieldsJson, bool clearsFaultCapsule,
                    uint32_t faultBoot, uint32_t faultEventCount);

namespace {

bool flushFaultCapsulesIfPossible();

struct QueuedEvent {
  uint32_t sequence;
  uint16_t length;
  bool critical;
  bool clearsFaultCapsule;
  uint32_t faultCapsuleBoot;
  uint32_t faultCapsuleEventCount;
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
TaskHandle_t writerTaskHandle = nullptr;
SemaphoreHandle_t producerMutex = nullptr;
SemaphoreHandle_t sealComplete = nullptr;
FILE *activeFile = nullptr;
uint32_t activeChunk = 1;
std::atomic<uint32_t> activeChunkSnapshot{1};
std::atomic<uint32_t> bootSequence{1};
std::atomic<bool> persistentBootSequenceReady{false};
uint32_t firmwareFingerprint = 0;
std::atomic<uint32_t> nextSequence{0};
std::atomic<uint32_t> enqueued{0};
std::atomic<uint32_t> written{0};
std::atomic<uint32_t> dropped{0};
std::atomic<uint32_t> storageErrors{0};
std::atomic<uint32_t> faultCapsuleGeneration{0};
std::atomic<uint32_t> faultCapsuleQueuedGeneration{0};
std::atomic<uint16_t> maxQueueDepth{0};
char activeCapture[48] = {};
portMUX_TYPE captureMux = portMUX_INITIALIZER_UNLOCKED;
std::atomic<bool> detailedCapture{false};
std::atomic<uint32_t> lastMarkerSequence{0};
char activePath[192] = {};
std::atomic<bool> lastStorageAvailable{false};
std::atomic<bool> sealRequested{false};
std::atomic<uint32_t> sealSequenceCutoff{0};
std::atomic<bool> sealSucceeded{false};
std::atomic<bool> clockAnchorEmitted{false};
std::atomic<bool> checkpointRequested{false};
uint32_t runtimeBootSequence = 0;
uint32_t lastCheckpointMs = 0;
ChunkFile retentionFiles[kMaximumRetainedFiles] = {};
ChunkFile filePruneCandidates[kFilePruneBatch] = {};

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
           "/sdcard/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
           static_cast<unsigned long>(file.boot),
           static_cast<unsigned long>(file.chunk));
  return storage->remove(path);
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
  if (level == Level::Warning || level == Level::Error || storageFailure) {
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

void clearFaultCapsule(const FaultCapsuleState &capsule) {
  portENTER_CRITICAL(&faultCapsuleMux);
  if (pendingFaultCapsuleValid &&
      pendingFaultCapsule.bootSequence == capsule.bootSequence &&
      pendingFaultCapsule.eventCount == capsule.eventCount) {
    pendingFaultCapsuleValid = false;
    memset(&pendingFaultCapsule, 0, sizeof(pendingFaultCapsule));
  }
  if (currentFaultCapsule.bootSequence == capsule.bootSequence &&
      currentFaultCapsule.eventCount == capsule.eventCount) {
    memset(&currentFaultCapsule, 0, sizeof(currentFaultCapsule));
    memset(&retainedFaultCapsule, 0, sizeof(retainedFaultCapsule));
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
  if (storage == nullptr || !storage->getSdLoaded())
    return selected;
  DIR *boots = opendir("/sdcard/BICINO/DIAGNOSTICS/v1/boots");
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
  if (storage == nullptr || !storage->getSdLoaded())
    return false;
  const uint32_t selected = persistentBootSequence(runtimeBootSequence);
  if (selected == 0)
    return false;
  bootSequence.store(selected, std::memory_order_release);
  persistentBootSequenceReady.store(true, std::memory_order_release);
  return true;
}

bool closeActiveFile() {
  if (activeFile == nullptr)
    return true;
  const int flushResult =
      storage != nullptr ? storage->flush(activeFile) : fflush(activeFile);
  const int closeResult =
      storage != nullptr ? storage->close(activeFile) : fclose(activeFile);
  activeFile = nullptr;
  return flushResult == 0 && closeResult == 0;
}

bool ensurePaths() {
  if (storage == nullptr || !storage->getSdLoaded())
    return false;
  storage->mkdir("/sdcard/BICINO");
  storage->mkdir("/sdcard/BICINO/DIAGNOSTICS");
  storage->mkdir("/sdcard/BICINO/DIAGNOSTICS/v1");
  char bootsPath[160] = {};
  snprintf(bootsPath, sizeof(bootsPath),
           "/sdcard/BICINO/DIAGNOSTICS/v1/boots");
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
  snprintf(activePath, sizeof(activePath),
           "/sdcard/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
           static_cast<unsigned long>(bootSequence.load()),
           static_cast<unsigned long>(activeChunk));
  activeFile = storage->open(activePath, "a");
  return activeFile != nullptr;
}

ChunkFileScan collectChunkFiles(ChunkFile *files, std::size_t capacity,
                                ChunkFile *pruneCandidates,
                                std::size_t pruneCandidateCapacity) {
  ChunkFileScan scan;
  if (files == nullptr || capacity == 0 || storage == nullptr ||
      !storage->getSdLoaded()) {
    return scan;
  }
  DIR *boots = opendir("/sdcard/BICINO/DIAGNOSTICS/v1/boots");
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
               "/sdcard/BICINO/DIAGNOSTICS/v1/boots/%s",
               bootEntry->d_name);
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
  if (count == 0)
    return;

  const uint32_t newestBoot = retentionFiles[count - 1].boot;
  const uint32_t oldestAllowedBoot =
      newestBoot >= kRetentionBoots - 1 ? newestBoot - (kRetentionBoots - 1) : 0;
  uint64_t totalBytes = 0;
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
    if (isActive || (!tooOld && totalBytes <= kRetentionBytes))
      continue;
    if (removeChunkFile(file))
      totalBytes -= std::min<uint64_t>(totalBytes, file.bytes);
  }
}

bool hasChunkWriteReserve() {
  if (storage == nullptr || !storage->getSdLoaded())
    return false;
  const uint64_t freeBytes = storage->removableSdFreeBytes();
  return freeBytes == UINT64_MAX ||
         freeBytes >= kMinimumFreeSpaceBytes + kChunkBytes;
}

bool prepareChunkWriteReserve() {
  if (hasChunkWriteReserve())
    return true;
  pruneRetention();
  return hasChunkWriteReserve();
}

bool writeQueuedEvent(const QueuedEvent &event) {
  if (storage == nullptr || !storage->getSdLoaded()) {
    closeActiveFile();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_unavailable", true);
    return false;
  }
  if (activeFile == nullptr && !prepareChunkWriteReserve()) {
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "free_space_reserved", true);
    return false;
  }
  if (!openActiveFile()) {
    storage->markSdUnavailable();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_unavailable", true);
    return false;
  }
  if (storage->size(activePath) + event.length > kChunkBytes) {
    if (!closeActiveFile()) {
      storage->markSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "flush_failed", true);
      return false;
    }
    if (!prepareChunkWriteReserve()) {
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "free_space_reserved", true);
      return false;
    }
    ++activeChunk;
    activeChunkSnapshot.store(activeChunk);
    if (!openActiveFile()) {
      storage->markSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "chunk_open_failed", true);
      return false;
    }
  }
  const size_t result = storage->write(activeFile,
                                       reinterpret_cast<const uint8_t *>(event.line),
                                       event.length);
  if (result != event.length) {
    closeActiveFile();
    storage->markSdUnavailable();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_failed", true);
    return false;
  }
  const uint32_t nowMs = millis();
  if (event.critical || static_cast<uint32_t>(nowMs - lastCheckpointMs) >= 5000U) {
    if (storage->flush(activeFile) != 0) {
      closeActiveFile();
      storage->markSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "flush_failed", true);
      return false;
    }
    lastCheckpointMs = nowMs;
  }
  const uint32_t writtenCount = written.fetch_add(1) + 1;
  if ((writtenCount % 16U) == 0U)
    pruneRetention();
  if (event.clearsFaultCapsule) {
    FaultCapsuleState capsule = {};
    capsule.magic = kFaultCapsuleMagic;
    capsule.bootSequence = event.faultCapsuleBoot;
    capsule.eventCount = event.faultCapsuleEventCount;
    clearFaultCapsule(capsule);
  }
  if (faultCapsuleGeneration.load(std::memory_order_acquire) !=
      faultCapsuleQueuedGeneration.load(std::memory_order_acquire))
    (void)flushFaultCapsulesIfPossible();
  return true;
}

bool flushFaultCapsulesIfPossible() {
  if (storage == nullptr || !storage->getSdLoaded())
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

  auto flush = [](const FaultCapsuleState &capsule) {
    char fields[512] = {};
    if (!formatFaultCapsuleFields(capsule, fields, sizeof(fields)))
      return false;
    return recordInternal(Level::Warning, "storage", "storage_gap", fields,
                          true, capsule.bootSequence, capsule.eventCount);
  };

  bool queuedAll = true;
  if (hasPending)
    queuedAll = flush(pending) && queuedAll;
  if (hasCurrent)
    queuedAll = flush(current) && queuedAll;
  if (queuedAll)
    faultCapsuleQueuedGeneration.store(generation,
                                       std::memory_order_release);
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

bool completeSealIfReady(bool hasNext, const QueuedEvent &next) {
  if (!sealRequested.load(std::memory_order_acquire))
    return false;
  const uint32_t cutoff = sealSequenceCutoff.load(std::memory_order_acquire);
  if (!queue_policy::readyToSeal(hasNext, next.sequence, cutoff))
    return false;

  bool success = storage != nullptr && storage->getSdLoaded();
  const bool hadActiveChunk = success && activeFile != nullptr &&
                              activePath[0] != '\0';
  if (!closeActiveFile()) {
    success = false;
    if (storage != nullptr) {
      storage->markSdUnavailable();
      storageErrors.fetch_add(1);
      updateFaultCapsule(Level::Error, "storage", "flush_failed", true);
    }
  }
  if (success)
    activePath[0] = '\0';
  if (success && hadActiveChunk) {
    ++activeChunk;
    activeChunkSnapshot.store(activeChunk);
    pruneRetention();
  }
  sealSucceeded.store(success, std::memory_order_release);
  sealRequested.store(false, std::memory_order_release);
  if (sealComplete != nullptr)
    xSemaphoreGive(sealComplete);
  return true;
}

void writerTask(void *) {
  uint32_t lastMountAttemptMs = 0;
  lastStorageAvailable.store(storage != nullptr && storage->getSdLoaded(),
                             std::memory_order_release);
  while (true) {
    QueuedEvent event = {};
    QueueHandle_t selected = nullptr;
    const bool hasNext = peekNextEvent(event, selected);
    if (!completeSealIfReady(hasNext, event) && hasNext &&
        xQueueReceive(selected, &event, 0) == pdTRUE) {
      writeQueuedEvent(event);
    } else if (!hasNext) {
      vTaskDelay(pdMS_TO_TICKS(50));
    }

    if (storage == nullptr)
      continue;
    const uint32_t nowMs = millis();
    if (activeFile != nullptr &&
        (checkpointRequested.exchange(false) ||
         static_cast<uint32_t>(nowMs - lastCheckpointMs) >= 5000U)) {
      if (storage->flush(activeFile) == 0) {
        lastCheckpointMs = nowMs;
      } else {
        closeActiveFile();
        storage->markSdUnavailable();
        storageErrors.fetch_add(1);
        updateFaultCapsule(Level::Error, "storage", "flush_failed", true);
      }
    }
    if (storage->canRetryRemovableSd() &&
        static_cast<uint32_t>(nowMs - lastMountAttemptMs) >= 5000U) {
      lastMountAttemptMs = nowMs;
      storage->ensureSdMounted(false);
    }
    const bool available = storage->getSdLoaded();
    const bool wasAvailable =
        lastStorageAvailable.exchange(available, std::memory_order_acq_rel);
    if (available && !wasAvailable)
      (void)flushFaultCapsulesIfPossible();
  }
}

void startWriterTask() {
#if PERSISTENT_RIDE_DIAGNOSTICS
  if (normalQueue != nullptr && criticalQueue != nullptr &&
      writerTaskHandle == nullptr) {
    xTaskCreatePinnedToCore(writerTask, "ride_diag_writer", 6144, nullptr, 1,
                            &writerTaskHandle, 0);
  }
#endif
}

bool enqueue(QueuedEvent &event) {
  QueueHandle_t target = event.critical ? criticalQueue : normalQueue;
  if (target == nullptr) {
    dropped.fetch_add(1);
    return false;
  }
  const BaseType_t result = xQueueSend(target, &event, 0);
  if (result != pdTRUE) {
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
  return true;
}

bool enqueueFormattedEvent(Level level, const char *category, const char *event,
                           const char *fieldsJson, const char *capture,
                           const char *wallTime, bool hasWallTime,
                           uint32_t uptimeMs, bool clearsFaultCapsule,
                           uint32_t faultBoot, uint32_t faultEventCount) {
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
  queued.length = static_cast<uint16_t>(length);
  queued.critical = level == Level::Error || level == Level::Warning;
  queued.clearsFaultCapsule = clearsFaultCapsule;
  queued.faultCapsuleBoot = faultBoot;
  queued.faultCapsuleEventCount = faultEventCount;
  return enqueue(queued);
}

} // namespace

void begin(Storage &storageRef, uint32_t bootSequenceRef,
           uint32_t firmwareFingerprintRef) {
  storage = &storageRef;
  runtimeBootSequence = bootSequenceRef == 0 ? 1 : bootSequenceRef;
  bootSequence.store(runtimeBootSequence);
  persistentBootSequenceReady.store(false);
  if (storage->getSdLoaded())
    (void)initializePersistentBootSequenceIfNeeded();
  firmwareFingerprint = firmwareFingerprintRef == 0 ? 1 : firmwareFingerprintRef;
  activeChunk = 1;
  activeChunkSnapshot.store(activeChunk);
  activePath[0] = '\0';
  nextSequence.store(0);
  clockAnchorEmitted.store(false);
  checkpointRequested.store(false);
  detailedCapture.store(false);
  lastMarkerSequence.store(0);
#if PERSISTENT_RIDE_DIAGNOSTICS
  faultCapsuleGeneration.store(0, std::memory_order_release);
  faultCapsuleQueuedGeneration.store(UINT32_MAX, std::memory_order_release);
  initializeFaultCapsules();
  lastStorageAvailable.store(storage->getSdLoaded(), std::memory_order_release);
  if (normalQueue == nullptr)
    normalQueue = xQueueCreate(kNormalQueueCapacity, sizeof(QueuedEvent));
  if (criticalQueue == nullptr)
    criticalQueue = xQueueCreate(kCriticalQueueCapacity, sizeof(QueuedEvent));
  if (producerMutex == nullptr)
    producerMutex = xSemaphoreCreateMutex();
  if (sealComplete == nullptr)
    sealComplete = xSemaphoreCreateBinary();
  char fields[320] = {};
  snprintf(fields, sizeof(fields),
           "{\"runtimeBootSequence\":%lu,\"firmwareTarget\":\"%s\",\"firmwareBuild\":%lu}",
           static_cast<unsigned long>(runtimeBootSequence),
           firmware_metadata::target(),
           static_cast<unsigned long>(firmware_metadata::build()));
  record(Level::Info, "boot", "recorder_started", fields);
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

void process(uint32_t nowMs) {
  (void)nowMs;
#if PERSISTENT_RIDE_DIAGNOSTICS
  // The writer task owns file handles. This hook is intentionally tiny so it
  // can be called from the LVGL loop without adding storage latency there.
#endif
}

bool recordInternal(Level level, const char *category, const char *event,
                    const char *fieldsJson, bool clearsFaultCapsule,
                    uint32_t faultBoot, uint32_t faultEventCount) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)level;
  (void)category;
  (void)event;
  (void)fieldsJson;
  return false;
#else
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
  if (storage == nullptr || !storage->getSdLoaded()) {
    dropped.fetch_add(1);
    storageErrors.fetch_add(1);
    updateFaultCapsule(level, category, event, true);
    return false;
  }
  char capture[48] = {};
  copyCapture(capture, sizeof(capture));
  char wallTime[32] = {};
  const bool hasWallTime = utcNow(wallTime, sizeof(wallTime));
  const uint32_t uptimeMs = millis();
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
  if (hasWallTime && strcmp(event, "clock_anchor") != 0 &&
      !clockAnchorEmitted.exchange(true)) {
    if (!enqueueFormattedEvent(
            Level::Info, "lifecycle", "clock_anchor",
            "{\"clockSynchronized\":true}", capture, wallTime, true,
            uptimeMs, false, 0, 0)) {
      clockAnchorEmitted.store(false);
    }
  }
  const bool enqueuedEvent = enqueueFormattedEvent(
      level, category, event, fieldsJson, capture, wallTime, hasWallTime,
      uptimeMs, clearsFaultCapsule, faultBoot, faultEventCount);
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

bool markIssue(const char *code, uint32_t markerSequence) {
  if (!validIssueCode(code) || markerSequence == 0 ||
      markerSequence <= lastMarkerSequence.load())
    return false;
  char fields[96] = {};
  snprintf(fields, sizeof(fields), "{\"code\":\"%s\",\"sequence\":%lu}",
           code, static_cast<unsigned long>(markerSequence));
  if (!record(Level::Info, "user", "issue_marker", fields))
    return false;
  lastMarkerSequence.store(markerSequence);
  checkpointRequested.store(true);
  return true;
}

bool bindCapture(const char *captureID, bool detailed) {
  if (!validCaptureID(captureID))
    return false;
#if !defined(RIDE_AUTOMATION_SHADOW)
  if (detailed)
    return false;
#endif
  char previousCapture[48] = {};
  bool changed = false;
  portENTER_CRITICAL(&captureMux);
  strncpy(previousCapture, activeCapture, sizeof(previousCapture) - 1);
  changed = strncmp(activeCapture, captureID, sizeof(activeCapture)) != 0;
  strncpy(activeCapture, captureID, sizeof(activeCapture) - 1);
  activeCapture[sizeof(activeCapture) - 1] = '\0';
  portEXIT_CRITICAL(&captureMux);
  const bool previousDetailed = detailedCapture.exchange(detailed);
  const uint32_t previousMarkerSequence = lastMarkerSequence.load();
  if (changed)
    lastMarkerSequence.store(0);
  if (record(Level::Info, "transfer", "capture_bound",
             detailed ? "{\"active\":true}" : "{\"active\":false}")) {
    return true;
  }
  portENTER_CRITICAL(&captureMux);
  if (strncmp(activeCapture, captureID, sizeof(activeCapture)) == 0) {
    strncpy(activeCapture, previousCapture, sizeof(activeCapture) - 1);
    activeCapture[sizeof(activeCapture) - 1] = '\0';
    detailedCapture.store(previousDetailed);
    lastMarkerSequence.store(previousMarkerSequence);
  }
  portEXIT_CRITICAL(&captureMux);
  return false;
}

void clearCapture() {
  char previousCapture[48] = {};
  copyCapture(previousCapture, sizeof(previousCapture));
  if (previousCapture[0] != '\0')
    record(Level::Info, "transfer", "capture_ended", "{}");
  portENTER_CRITICAL(&captureMux);
  activeCapture[0] = '\0';
  portEXIT_CRITICAL(&captureMux);
  detailedCapture.store(false);
  lastMarkerSequence.store(0);
  checkpointRequested.store(true);
}

const char *captureId() { return activeCapture; }

bool detailedCaptureEnabled() { return detailedCapture.load(); }

bool sealActiveChunk(uint32_t timeoutMs) {
#if !PERSISTENT_RIDE_DIAGNOSTICS
  (void)timeoutMs;
  return false;
#else
  if (writerTaskHandle == nullptr || producerMutex == nullptr ||
      sealComplete == nullptr || storage == nullptr || !storage->getSdLoaded()) {
    return false;
  }
  // A removable card can reappear after an outage. Queue the retained gap
  // capsule before taking the producer lock so the sealed cutoff includes the
  // recovery evidence. recordInternal() takes the same producer lock.
  if (faultCapsuleGeneration.load(std::memory_order_acquire) !=
          faultCapsuleQueuedGeneration.load(std::memory_order_acquire) &&
      !flushFaultCapsulesIfPossible()) {
    return false;
  }
  if (xSemaphoreTake(producerMutex, pdMS_TO_TICKS(timeoutMs)) != pdTRUE)
    return false;
  // A producer or writer failure may have updated the capsule between the
  // flush above and this lock acquisition. Never advertise a checkpoint that
  // knowingly omits that evidence; the next explicit request will retry it.
  if (faultCapsuleGeneration.load(std::memory_order_acquire) !=
      faultCapsuleQueuedGeneration.load(std::memory_order_acquire)) {
    xSemaphoreGive(producerMutex);
    return false;
  }
  if (!initializePersistentBootSequenceIfNeeded()) {
    xSemaphoreGive(producerMutex);
    return false;
  }
  if (sealRequested.exchange(true)) {
    xSemaphoreGive(producerMutex);
    return false;
  }
  while (xSemaphoreTake(sealComplete, 0) == pdTRUE) {
  }
  sealSucceeded.store(false);
  sealSequenceCutoff.store(nextSequence.load(), std::memory_order_release);
  xSemaphoreGive(producerMutex);
  if (xSemaphoreTake(sealComplete, pdMS_TO_TICKS(timeoutMs)) != pdTRUE) {
    sealRequested.store(false);
    return false;
  }
  if (!sealSucceeded.load(std::memory_order_acquire))
    return false;
  // Producers use a non-blocking mutex so a callback that races with the
  // short seal critical section records its omission in the fault capsule
  // instead of stalling BLE/UI work. Do not advertise the sealed checkpoint
  // if such a gap appeared after the pre-seal capsule flush; a retry will
  // enqueue that gap and seal it into the next immutable chunk.
  return faultCapsuleGeneration.load(std::memory_order_acquire) ==
         faultCapsuleQueuedGeneration.load(std::memory_order_acquire);
#endif
}

Stats stats() {
  return {
      enqueued.load(),
      written.load(),
      dropped.load(),
      storageErrors.load(),
      queuedDepth(),
      maxQueueDepth.load(),
      storage != nullptr && storage->getSdLoaded(),
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

} // namespace ride_diagnostics
