#pragma once

#include <cstdint>

namespace waveshare_board::touch_sampling_policy {

// A short INT pulse is remembered by the caller's generation latch. Keep a
// bounded follow-up window after that event (including a failed first read),
// and keep sampling an active gesture even when INT has returned high. A fully
// idle controller is not polled without evidence of touch activity.
// Cadence, failure backoff and the one immediate attempt per new edge remain
// the caller's responsibility.
class ReadWindow {
public:
  void arm(uint32_t nowMs, uint32_t durationMs) {
    startedMs_ = nowMs;
    durationMs_ = durationMs;
    armed_ = true;
  }

  bool active(uint32_t nowMs) {
    if (armed_ && nowMs - startedMs_ >= durationMs_) {
      armed_ = false;
    }
    return armed_;
  }

  bool shouldAttemptRead(bool interruptActive, bool touchPressed,
                         bool interruptPending, uint32_t nowMs) {
    const bool windowActive = active(nowMs);
    return interruptActive || touchPressed || interruptPending || windowActive;
  }

private:
  bool armed_ = false;
  uint32_t startedMs_ = 0;
  uint32_t durationMs_ = 0;
};

} // namespace waveshare_board::touch_sampling_policy
