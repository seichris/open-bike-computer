#include "ride_diagnostics.hpp"
#include "ride_diagnostics_format.hpp"

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
#include <freertos/task.h>

#ifndef PERSISTENT_RIDE_DIAGNOSTICS
#define PERSISTENT_RIDE_DIAGNOSTICS 0
#endif

namespace ride_diagnostics {

bool recordInternal(Level level, const char *category, const char *event,
                    const char *fieldsJson, bool clearsFaultCapsule,
                    uint32_t faultBoot, uint32_t faultEventCount);

namespace {

struct QueuedEvent {
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
using detail::validateFieldsJson;
using detail::validFaultCapsule;

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

Storage *storage = nullptr;
QueueHandle_t queue = nullptr;
TaskHandle_t writerTaskHandle = nullptr;
FILE *activeFile = nullptr;
uint32_t activeChunk = 1;
std::atomic<uint32_t> activeChunkSnapshot{1};
uint32_t bootSequence = 0;
uint32_t firmwareFingerprint = 0;
std::atomic<uint32_t> nextSequence{0};
std::atomic<uint32_t> enqueued{0};
std::atomic<uint32_t> written{0};
std::atomic<uint32_t> dropped{0};
std::atomic<uint32_t> storageErrors{0};
std::atomic<uint16_t> maxQueueDepth{0};
char activeCapture[48] = {};
portMUX_TYPE captureMux = portMUX_INITIALIZER_UNLOCKED;
char activePath[192] = {};
std::atomic<bool> lastStorageAvailable{false};

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
  portENTER_CRITICAL(&faultCapsuleMux);
  pendingFaultCapsuleValid = validFaultCapsule(retainedFaultCapsule) &&
                             retainedFaultCapsule.bootSequence != bootSequence;
  if (pendingFaultCapsuleValid)
    pendingFaultCapsule = retainedFaultCapsule;

  memset(&currentFaultCapsule, 0, sizeof(currentFaultCapsule));
  currentFaultCapsule.magic = kFaultCapsuleMagic;
  currentFaultCapsule.bootSequence = bootSequence;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const boot_diagnostics::Snapshot snapshot = boot_diagnostics::snapshot();
  currentFaultCapsule.resetReason = snapshot.resetReason;
  currentFaultCapsule.activeStage = static_cast<uint16_t>(snapshot.activeStage);
  currentFaultCapsule.completedStage =
      static_cast<uint16_t>(snapshot.completedStage);
#endif
  portEXIT_CRITICAL(&faultCapsuleMux);
}

void updateFaultCapsule(Level level, const char *category, const char *event,
                        bool storageFailure) {
  portENTER_CRITICAL(&faultCapsuleMux);
  if (currentFaultCapsule.magic != kFaultCapsuleMagic ||
      currentFaultCapsule.bootSequence != bootSequence) {
    memset(&currentFaultCapsule, 0, sizeof(currentFaultCapsule));
    currentFaultCapsule.magic = kFaultCapsuleMagic;
    currentFaultCapsule.bootSequence = bootSequence;
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
  retainedFaultCapsule = currentFaultCapsule;
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

void closeActiveFile() {
  if (activeFile != nullptr) {
    fflush(activeFile);
    if (storage != nullptr)
      storage->close(activeFile);
    else
      fclose(activeFile);
    activeFile = nullptr;
  }
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
  snprintf(bootPath, sizeof(bootPath), "%s/%lu", bootsPath,
           static_cast<unsigned long>(bootSequence));
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
           static_cast<unsigned long>(bootSequence),
           static_cast<unsigned long>(activeChunk));
  activeFile = storage->open(activePath, "a");
  return activeFile != nullptr;
}

std::size_t collectChunkFiles(ChunkFile *files, std::size_t capacity) {
  if (files == nullptr || capacity == 0 || storage == nullptr ||
      !storage->getSdLoaded()) {
    return 0;
  }
  DIR *boots = opendir("/sdcard/BICINO/DIAGNOSTICS/v1/boots");
  if (boots == nullptr)
    return 0;

  std::size_t count = 0;
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
        if (!parseUnsigned(number, chunk) || count >= capacity)
          continue;
        ChunkFile &file = files[count];
        file.boot = boot;
        file.chunk = chunk;
        char path[224] = {};
        snprintf(path, sizeof(path), "%s/%s", bootPath, name);
        file.bytes = static_cast<uint32_t>(storage->size(path));
        struct stat metadata = {};
        file.modifiedAt = ::stat(path, &metadata) == 0 ? metadata.st_mtime : 0;
        ++count;
      }
      closedir(bootDirectory);
    }
  }
  closedir(boots);
  std::sort(files, files + count, [](const ChunkFile &left,
                                    const ChunkFile &right) {
    if (left.boot != right.boot)
      return left.boot < right.boot;
    return left.chunk < right.chunk;
  });
  return count;
}

void pruneRetention() {
  ChunkFile files[kMaximumRetainedFiles] = {};
  const std::size_t count = collectChunkFiles(files, kMaximumRetainedFiles);
  if (count == 0)
    return;

  const uint32_t newestBoot = files[count - 1].boot;
  const uint32_t oldestAllowedBoot =
      newestBoot >= kRetentionBoots - 1 ? newestBoot - (kRetentionBoots - 1) : 0;
  uint64_t totalBytes = 0;
  const time_t now = time(nullptr);
  const bool validClock = now >= static_cast<time_t>(1700000000);
  const time_t oldestAllowedTime =
      validClock ? now - static_cast<time_t>(kRetentionDays) * 24 * 60 * 60 : 0;
  for (std::size_t index = 0; index < count; ++index)
    totalBytes += files[index].bytes;

  for (std::size_t index = 0; index < count; ++index) {
    const ChunkFile &file = files[index];
    const bool isActive = file.boot == bootSequence && file.chunk == activeChunk;
    const bool tooOldByBoot = file.boot < oldestAllowedBoot;
    const bool tooOldByDate = validClock && file.modifiedAt > 0 &&
                              file.modifiedAt < oldestAllowedTime;
    const bool tooOld = tooOldByBoot || tooOldByDate;
    if (isActive || (!tooOld && totalBytes <= kRetentionBytes))
      continue;
    char path[224] = {};
    snprintf(path, sizeof(path),
             "/sdcard/BICINO/DIAGNOSTICS/v1/boots/%lu/events-%06lu.jsonl",
             static_cast<unsigned long>(file.boot),
             static_cast<unsigned long>(file.chunk));
    if (storage->remove(path))
      totalBytes -= std::min<uint64_t>(totalBytes, file.bytes);
  }
}

bool writeQueuedEvent(const QueuedEvent &event) {
  if (storage == nullptr || !storage->getSdLoaded()) {
    closeActiveFile();
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_unavailable", true);
    return false;
  }
  if (!openActiveFile()) {
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_unavailable", true);
    return false;
  }
  if (storage->size(activePath) + event.length > kChunkBytes) {
    closeActiveFile();
    ++activeChunk;
    activeChunkSnapshot.store(activeChunk);
    if (!openActiveFile()) {
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
    storageErrors.fetch_add(1);
    updateFaultCapsule(Level::Error, "storage", "write_failed", true);
    return false;
  }
  if (event.critical || (nextSequence.load() % 16U) == 0U)
    fflush(activeFile);
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
  return true;
}

void flushFaultCapsulesIfPossible() {
  if (storage == nullptr || !storage->getSdLoaded())
    return;

  FaultCapsuleState pending = {};
  FaultCapsuleState current = {};
  bool hasPending = false;
  bool hasCurrent = false;
  portENTER_CRITICAL(&faultCapsuleMux);
  hasPending = pendingFaultCapsuleValid;
  if (hasPending)
    pending = pendingFaultCapsule;
  hasCurrent = validFaultCapsule(currentFaultCapsule);
  if (hasCurrent)
    current = currentFaultCapsule;
  portEXIT_CRITICAL(&faultCapsuleMux);

  auto flush = [](const FaultCapsuleState &capsule) {
    char fields[512] = {};
    if (!formatFaultCapsuleFields(capsule, fields, sizeof(fields)))
      return false;
    return recordInternal(Level::Warning, "storage", "storage_gap", fields,
                          true, capsule.bootSequence, capsule.eventCount);
  };

  if (hasPending)
    (void)flush(pending);
  if (hasCurrent)
    (void)flush(current);
}

void writerTask(void *) {
  QueuedEvent event = {};
  uint32_t lastMountAttemptMs = 0;
  lastStorageAvailable.store(storage != nullptr && storage->getSdLoaded(),
                             std::memory_order_release);
  while (true) {
    if (xQueueReceive(queue, &event, pdMS_TO_TICKS(1000)) == pdTRUE)
      writeQueuedEvent(event);

    if (storage == nullptr)
      continue;
    const uint32_t nowMs = millis();
    if (!storage->getSdLoaded() &&
        static_cast<uint32_t>(nowMs - lastMountAttemptMs) >= 5000U) {
      lastMountAttemptMs = nowMs;
      storage->ensureSdMounted(false);
    }
    const bool available = storage->getSdLoaded();
    const bool wasAvailable =
        lastStorageAvailable.exchange(available, std::memory_order_acq_rel);
    if (available && !wasAvailable)
      flushFaultCapsulesIfPossible();
  }
}

void startWriterTask() {
#if PERSISTENT_RIDE_DIAGNOSTICS
  if (queue != nullptr && writerTaskHandle == nullptr) {
    xTaskCreatePinnedToCore(writerTask, "ride_diag_writer", 4096, nullptr, 1,
                            &writerTaskHandle, 0);
  }
#endif
}

bool enqueue(QueuedEvent &event) {
  if (queue == nullptr) {
    dropped.fetch_add(1);
    return false;
  }
  const BaseType_t result = event.critical
                                ? xQueueSendToFront(queue, &event, 0)
                                : xQueueSend(queue, &event, 0);
  if (result != pdTRUE) {
    dropped.fetch_add(1);
    return false;
  }
  enqueued.fetch_add(1);
  const UBaseType_t depth = uxQueueMessagesWaiting(queue);
  uint16_t previous = maxQueueDepth.load();
  while (depth > previous &&
         !maxQueueDepth.compare_exchange_weak(previous,
                                               static_cast<uint16_t>(depth))) {
  }
  return true;
}

} // namespace

void begin(Storage &storageRef, uint32_t bootSequenceRef,
           uint32_t firmwareFingerprintRef) {
  storage = &storageRef;
  bootSequence = bootSequenceRef == 0 ? 1 : bootSequenceRef;
  firmwareFingerprint = firmwareFingerprintRef == 0 ? 1 : firmwareFingerprintRef;
  activeChunk = 1;
  activeChunkSnapshot.store(activeChunk);
#if PERSISTENT_RIDE_DIAGNOSTICS
  initializeFaultCapsules();
  lastStorageAvailable.store(storage->getSdLoaded(), std::memory_order_release);
  if (queue == nullptr)
    queue = xQueueCreate(kQueueCapacity, sizeof(QueuedEvent));
  char fields[320] = {};
  snprintf(fields, sizeof(fields),
           "{\"bootSequence\":%lu,\"firmwareFingerprint\":\"%08lX\",\"firmwareTarget\":\"%s\",\"firmwareBuild\":%lu}",
           static_cast<unsigned long>(bootSequence),
           static_cast<unsigned long>(firmwareFingerprint),
           firmware_metadata::target(),
           static_cast<unsigned long>(firmware_metadata::build()));
  record(Level::Info, "boot", "recorder_started", fields);
  flushFaultCapsulesIfPossible();
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
  const uint32_t sequence = nextSequence.fetch_add(1);
  char capture[48] = {};
  copyCapture(capture, sizeof(capture));
  char wallTime[32] = {};
  const bool hasWallTime = utcNow(wallTime, sizeof(wallTime));
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
      static_cast<unsigned long>(millis()),
      capture[0] == '\0' ? "" : ",\"captureId\":\"", capture,
      capture[0] == '\0' ? "" : "\"",
      hasWallTime ? ",\"wallTime\":\"" : "", wallTime,
      hasWallTime ? "\"" : "",
      static_cast<unsigned long>(bootSequence),
      static_cast<unsigned long>(firmwareFingerprint),
      hasDetail ? "," : "", detail);
  if (length <= 0 || static_cast<std::size_t>(length) >= sizeof(queued.line)) {
    dropped.fetch_add(1);
    return false;
  }
  queued.length = static_cast<uint16_t>(length);
  queued.critical = level == Level::Error || level == Level::Warning;
  queued.clearsFaultCapsule = clearsFaultCapsule;
  queued.faultCapsuleBoot = faultBoot;
  queued.faultCapsuleEventCount = faultEventCount;
  if (!enqueue(queued)) {
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

bool markIssue(const char *code) {
  if (!validIssueCode(code))
    return false;
  char fields[64] = {};
  snprintf(fields, sizeof(fields), "{\"code\":\"%s\"}", code);
  return record(Level::Info, "user", "issue_marker", fields);
}

bool bindCapture(const char *captureID) {
  if (!validCaptureID(captureID))
    return false;
  portENTER_CRITICAL(&captureMux);
  strncpy(activeCapture, captureID, sizeof(activeCapture) - 1);
  activeCapture[sizeof(activeCapture) - 1] = '\0';
  portEXIT_CRITICAL(&captureMux);
  return record(Level::Info, "transfer", "capture_bound", "{}");
}

void clearCapture() {
  char previousCapture[48] = {};
  copyCapture(previousCapture, sizeof(previousCapture));
  if (previousCapture[0] != '\0')
    record(Level::Info, "transfer", "capture_ended", "{}");
  portENTER_CRITICAL(&captureMux);
  activeCapture[0] = '\0';
  portEXIT_CRITICAL(&captureMux);
}

const char *captureId() { return activeCapture; }

Stats stats() {
  return {
      enqueued.load(),
      written.load(),
      dropped.load(),
      storageErrors.load(),
      static_cast<uint16_t>(queue == nullptr ? 0 : uxQueueMessagesWaiting(queue)),
      maxQueueDepth.load(),
      storage != nullptr && storage->getSdLoaded(),
  };
}

uint32_t currentBootSequence() { return bootSequence; }

uint32_t currentActiveChunk() { return activeChunkSnapshot.load(); }

bool isClosedChunk(uint32_t boot, uint32_t chunk) {
  if (boot == 0 || chunk == 0 || boot > bootSequence)
    return false;
  if (boot < bootSequence)
    return true;
  return chunk < activeChunkSnapshot.load();
}

} // namespace ride_diagnostics
