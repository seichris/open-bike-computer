#pragma once

#include <cstdint>

namespace ride_diagnostics::queue_policy {

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
