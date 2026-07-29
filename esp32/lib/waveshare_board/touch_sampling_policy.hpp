#pragma once

#include <cstdint>

namespace waveshare_board::touch_sampling_policy {

// Automatic light sleep relies on the controller interrupt as the idle wake
// source. Avoid speculative CST9217 reads while INT is high: the controller
// may NACK those reads, and a failed transaction can leave the ESP-IDF I2C
// state machine needing recovery after a sleep/wake boundary. Active gestures,
// a newly latched interrupt, and the short post-touch fallback window continue
// to sample normally.
constexpr bool shouldAttemptRead(bool automaticLightSleep,
                                 bool interruptActive, bool touchPressed,
                                 bool interruptPending, uint32_t nowMs,
                                 uint32_t fastPollUntilMs) {
  const bool fastPollActive =
      static_cast<int32_t>(fastPollUntilMs - nowMs) > 0;
  return !automaticLightSleep || interruptActive || touchPressed ||
         interruptPending || fastPollActive;
}

} // namespace waveshare_board::touch_sampling_policy
