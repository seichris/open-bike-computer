/**
 * @file mapTapArbiter.hpp
 * @brief Pure grace-period arbiter for standalone Map screen taps.
 */

#pragma once

#include <cstdint>

namespace map_tap_arbiter {

class Controller {
public:
  static constexpr uint32_t kGracePeriodMs = 160;

  void arm(uint32_t nowMs) {
    armedAtMs_ = nowMs;
    pending_ = true;
  }

  void cancel() { pending_ = false; }

  bool consumeIfReady(uint32_t nowMs, bool standaloneMapActive,
                      uint8_t contactCount, bool pinchOwnsInput) {
    if (!pending_)
      return false;
    if (!standaloneMapActive || contactCount > 0 || pinchOwnsInput) {
      cancel();
      return false;
    }
    if (static_cast<uint32_t>(nowMs - armedAtMs_) < kGracePeriodMs)
      return false;
    pending_ = false;
    return true;
  }

  bool pending() const { return pending_; }

private:
  bool pending_ = false;
  uint32_t armedAtMs_ = 0;
};

} // namespace map_tap_arbiter
