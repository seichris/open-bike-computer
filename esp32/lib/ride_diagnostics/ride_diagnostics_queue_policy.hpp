#pragma once

#include <cstdint>

namespace ride_diagnostics::queue_policy {

// These counters describe admission failures, not SD write failures. Keep
// them boot-local and scalar so a retained summary can identify lost records
// without persisting rejected fields or transport payloads.
enum class DropReason : uint8_t {
  InvalidToken, InvalidFields, StorageUnavailable, ProducerUnavailable, ProducerBusy,
  BootIdentityUnavailable, QueueUnavailable, QueueBusy, CriticalSpill,
  QueueFull, NormalEvicted, RecordTooLarge, Count,
};

inline const char *dropReasonName(DropReason reason) {
  switch (reason) {
  case DropReason::InvalidToken: return "invalid_token";
  case DropReason::InvalidFields: return "invalid_fields";
  case DropReason::StorageUnavailable: return "storage_unavailable";
  case DropReason::ProducerUnavailable: return "producer_unavailable";
  case DropReason::ProducerBusy: return "producer_busy";
  case DropReason::BootIdentityUnavailable: return "boot_identity_unavailable";
  case DropReason::QueueUnavailable: return "queue_unavailable";
  case DropReason::QueueBusy: return "queue_busy";
  case DropReason::CriticalSpill: return "critical_spill";
  case DropReason::QueueFull: return "queue_full";
  case DropReason::NormalEvicted: return "normal_evicted";
  case DropReason::RecordTooLarge: return "record_too_large";
  case DropReason::Count: break;
  }
  return "unknown";
}

enum class Selection : uint8_t { None = 0, Normal = 1, Critical = 2 };
enum class CriticalOverflow : uint8_t {
  Drop = 0,
  UseNormal = 1,
  EvictNormal = 2,
};

inline Selection select(bool hasNormal, uint32_t normalSequence,
                        bool hasCritical, uint32_t criticalSequence) {
  if (!hasNormal && !hasCritical)
    return Selection::None;
  if (hasNormal && (!hasCritical || normalSequence < criticalSequence))
    return Selection::Normal;
  return Selection::Critical;
}

inline bool readyToSeal(bool hasNext, uint32_t nextSequence,
                        uint32_t cutoff) {
  return !hasNext || nextSequence >= cutoff;
}

inline CriticalOverflow criticalOverflow(bool normalHasSpace,
                                         uint16_t normalEntries,
                                         uint16_t spilledCriticalEntries) {
  if (normalHasSpace)
    return CriticalOverflow::UseNormal;
  if (normalEntries > spilledCriticalEntries)
    return CriticalOverflow::EvictNormal;
  return CriticalOverflow::Drop;
}

} // namespace ride_diagnostics::queue_policy
