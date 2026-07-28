/**
 * @file touchInterruptGate.hpp
 * @brief Pure generation gating for interrupt-driven touch reads.
 */

#pragma once

#include <cstdint>

namespace touch_interrupt_gate {

inline bool hasUnattemptedGeneration(uint32_t generated,
                                     uint32_t attempted) {
  return generated != attempted;
}

inline bool shouldBypassThrottle(uint32_t generated, uint32_t attempted) {
  // A new edge gets one immediate read attempt. If that attempt fails, the
  // attempted generation catches up and ordinary cadence/backoff applies
  // until either its retry deadline or a newer edge arrives.
  return hasUnattemptedGeneration(generated, attempted);
}

} // namespace touch_interrupt_gate
