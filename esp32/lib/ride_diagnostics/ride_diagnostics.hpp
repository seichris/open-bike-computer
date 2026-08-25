#pragma once

#include "ride_diagnostics_transfer_policy.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

class Storage;

namespace ride_diagnostics {

enum class Level : uint8_t {
  Debug = 0,
  Info = 1,
  Warning = 2,
  Error = 3,
};

struct Stats {
  uint32_t enqueued;
  uint32_t written;
  uint32_t dropped;
  uint32_t storageErrors;
  uint16_t queueDepth;
  uint16_t maxQueueDepth;
  bool storageAvailable;
};

constexpr std::size_t kCaptureIdBytes = 48;

// Snapshot used by expiry/lifecycle owners. The generation, identifier, and
// deadline must all still match before a stale owner may revoke a fresh bind.
struct DetailedCaptureLease {
  bool active = false;
  uint32_t generation = 0;
  uint32_t deadlineMs = 0;
  char captureId[kCaptureIdBytes] = {};
};

constexpr std::size_t kMaximumEventBytes = 768;
constexpr std::size_t kNormalQueueCapacity = 24;
constexpr std::size_t kCriticalQueueCapacity = 8;
constexpr std::size_t kQueueCapacity =
    kNormalQueueCapacity + kCriticalQueueCapacity;
constexpr std::size_t kChunkBytes = 256 * 1024;
constexpr std::size_t kRetentionBytes = 32 * 1024 * 1024;
constexpr std::size_t kMinimumFreeSpaceBytes = 8 * 1024 * 1024;
constexpr uint8_t kRetentionBoots = 20;
constexpr uint8_t kRetentionDays = 14;

namespace retention_policy {

constexpr uint64_t kMinimumTrustworthyEpoch = 1'700'000'000ULL;

inline bool expiredByWallClock(uint64_t nowEpoch, uint64_t modifiedEpoch,
                               uint8_t retentionDays) {
  if (nowEpoch < kMinimumTrustworthyEpoch ||
      modifiedEpoch < kMinimumTrustworthyEpoch || modifiedEpoch > nowEpoch) {
    return false;
  }
  const uint64_t retentionSeconds =
      static_cast<uint64_t>(retentionDays) * 24ULL * 60ULL * 60ULL;
  return modifiedEpoch < nowEpoch - retentionSeconds;
}

inline bool snapshotLeaseActive(uint32_t nowMs, uint32_t deadlineMs) {
  return deadlineMs != 0 &&
         static_cast<int32_t>(deadlineMs - nowMs) > 0;
}

inline bool shouldPruneAfterWrite(uint32_t writtenCount,
                                  bool alreadyPrunedThisBoot) {
  return !alreadyPrunedThisBoot || (writtenCount % 16U) == 0U;
}

} // namespace retention_policy

namespace capture_policy {

constexpr uint32_t kDetailedCaptureDurationMs = 4U * 60U * 60U * 1000U;

inline uint32_t detailedCaptureDeadline(uint32_t nowMs) {
  const uint32_t deadline = nowMs + kDetailedCaptureDurationMs;
  // Zero is the disabled sentinel. Preserve a finite deadline when the
  // unsigned sum lands exactly on that value near millis() wrap.
  return deadline == 0 ? 1 : deadline;
}

inline bool detailedCaptureExpired(uint32_t nowMs, uint32_t deadlineMs) {
  return deadlineMs != 0 &&
         static_cast<int32_t>(nowMs - deadlineMs) >= 0;
}

inline uint32_t detailedCaptureDeadlineAfterBinding(
    uint32_t nowMs, uint32_t currentDeadlineMs, bool bindingChanged,
    bool detailed) {
  if (!detailed)
    return 0;
  if (!bindingChanged && currentDeadlineMs != 0)
    return currentDeadlineMs;
  return detailedCaptureDeadline(nowMs);
}

inline bool detailedCaptureLeaseMatches(
    const char *activeCaptureId, uint32_t activeGeneration,
    uint32_t activeDeadlineMs, const char *expectedCaptureId,
    uint32_t expectedGeneration, uint32_t expectedDeadlineMs) {
  return activeCaptureId != nullptr && expectedCaptureId != nullptr &&
         activeCaptureId[0] != '\0' && expectedCaptureId[0] != '\0' &&
         activeGeneration == expectedGeneration &&
         activeDeadlineMs == expectedDeadlineMs &&
         std::strcmp(activeCaptureId, expectedCaptureId) == 0;
}

} // namespace capture_policy

void begin(Storage &storage, uint32_t bootSequence, uint32_t firmwareFingerprint);
// Start persistent SD writes after boot-time map recovery has released storage.
// Events recorded between begin() and this handoff remain queued.
void startWriter();
void process(uint32_t nowMs);
using StorageRecoveryAllowedProbe = bool (*)();
void setStorageRecoveryAllowedProbe(StorageRecoveryAllowedProbe probe);

bool record(Level level, const char *category, const char *event,
            const char *fieldsJson = "{}");
bool recordClockAnchor();
bool markIssue(const char *code, uint32_t markerSequence);
bool bindCapture(const char *captureId, bool detailed = false);
void clearCapture();
DetailedCaptureLease detailedCaptureLease();
bool clearCaptureIfMatches(const DetailedCaptureLease &lease);
const char *captureId();
bool detailedCaptureEnabled();
transfer_policy::SealPreparation
sealActiveChunkForTransfer(uint32_t timeoutMs = 5000);
bool sealActiveChunk(uint32_t timeoutMs = 2000);
// Pause the writer after sealing its current cutoff so a caller can remount
// storage without a recorder FILE reopening between seal and unmount.
bool beginStorageTransition(uint32_t timeoutMs = 2000);
void endStorageTransition();
bool prepareForShutdown(uint32_t timeoutMs = 2000);
void beginTransferSnapshotLease(uint32_t durationMs = 10U * 60U * 1000U);
void refreshTransferSnapshotLease(uint32_t durationMs = 10U * 60U * 1000U);
void endTransferSnapshotLease();
Stats stats();
uint32_t currentBootSequence();
uint32_t currentActiveChunk();
bool isClosedChunk(uint32_t boot, uint32_t chunk);

} // namespace ride_diagnostics
