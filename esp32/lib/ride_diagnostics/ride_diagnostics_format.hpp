#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace ride_diagnostics::detail {

constexpr uint32_t kFaultCapsuleMagic = 0x52444350; // "RDCP"

struct FaultCapsuleState {
  uint32_t magic;
  uint32_t bootSequence;
  uint32_t firstMissingUptimeMs;
  uint32_t lastMissingUptimeMs;
  uint32_t eventCount;
  uint32_t droppedCount;
  uint32_t storageErrorCount;
  uint32_t resetReason;
  uint16_t activeStage;
  uint16_t completedStage;
  char lastCriticalCategory[24];
  char lastCriticalEvent[48];
};

inline bool validFaultCapsule(const FaultCapsuleState &capsule) {
  return capsule.magic == kFaultCapsuleMagic && capsule.bootSequence != 0 &&
         capsule.eventCount != 0;
}

inline bool formatFaultCapsuleFields(const FaultCapsuleState &capsule,
                                     char *out, std::size_t capacity) {
  if (!validFaultCapsule(capsule) || out == nullptr || capacity == 0)
    return false;
  const int length = std::snprintf(
      out, capacity,
      "{\"bootSequence\":%lu,\"firstMissingUptimeMs\":%lu,"
      "\"lastMissingUptimeMs\":%lu,\"eventCount\":%lu,"
      "\"droppedCount\":%lu,\"storageErrorCount\":%lu,"
      "\"resetReason\":%lu,\"activeStage\":%u,"
      "\"completedStage\":%u,\"lastCriticalCategory\":\"%s\","
      "\"lastCriticalEvent\":\"%s\"}",
      static_cast<unsigned long>(capsule.bootSequence),
      static_cast<unsigned long>(capsule.firstMissingUptimeMs),
      static_cast<unsigned long>(capsule.lastMissingUptimeMs),
      static_cast<unsigned long>(capsule.eventCount),
      static_cast<unsigned long>(capsule.droppedCount),
      static_cast<unsigned long>(capsule.storageErrorCount),
      static_cast<unsigned long>(capsule.resetReason),
      static_cast<unsigned>(capsule.activeStage),
      static_cast<unsigned>(capsule.completedStage),
      capsule.lastCriticalCategory[0] == '\0' ? "unknown"
                                              : capsule.lastCriticalCategory,
      capsule.lastCriticalEvent[0] == '\0' ? "storage_unavailable"
                                           : capsule.lastCriticalEvent);
  return length > 0 && static_cast<std::size_t>(length) < capacity;
}

} // namespace ride_diagnostics::detail
