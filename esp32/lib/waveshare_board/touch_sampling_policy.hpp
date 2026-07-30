#pragma once

#include <cstdint>

namespace waveshare_board::touch_sampling_policy {

// CST9217 INT is a transient hint rather than a persistent touch level on the
// tested 1.75-inch board. When idle fallback is enabled, the caller's existing
// cadence and failure backoff remain authoritative even if INT is high. A
// board with a reliable interrupt may disable fallback and still sample active
// gestures, a newly latched interrupt, and the short post-touch window.
constexpr bool shouldAttemptRead(bool allowIdleFallback,
                                 bool interruptActive, bool touchPressed,
                                 bool interruptPending, uint32_t nowMs,
                                 uint32_t fastPollUntilMs) {
  const bool fastPollActive =
      static_cast<int32_t>(fastPollUntilMs - nowMs) > 0;
  return allowIdleFallback || interruptActive || touchPressed ||
         interruptPending || fastPollActive;
}

} // namespace waveshare_board::touch_sampling_policy
