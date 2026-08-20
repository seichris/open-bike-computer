#pragma once

#include <cstdint>

namespace ride_diagnostics::queue_policy {

enum class Selection : uint8_t { None = 0, Normal = 1, Critical = 2 };

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

} // namespace ride_diagnostics::queue_policy
