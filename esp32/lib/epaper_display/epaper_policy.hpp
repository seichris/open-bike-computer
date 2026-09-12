#pragma once

#include <cstdint>

namespace epaper {
// Experimental defaults, deliberately excluded from release/factory profiles.
// Physical qualification must establish temperature and panel wear limits.
constexpr uint32_t routineIntervalMs = 1000;
constexpr uint32_t waveformRestMs = 250;
constexpr uint32_t cleaningIntervalMs = 60000;
constexpr uint32_t busyTimeoutMs = 10000;
constexpr uint16_t partialLimit = 20;

class PresentationPolicy {
public:
  bool ready(uint32_t now, bool urgent) const {
    return !fault_ && !sleeping_ && !busy_ &&
           (!history_ || uint32_t(now - finishedAt_) >=
                             (urgent ? waveformRestMs : routineIntervalMs));
  }
  bool fullRequired(uint32_t now) const {
    return !history_ || partials_ >= partialLimit ||
           uint32_t(now - cleanedAt_) >= cleaningIntervalMs;
  }
  void start() { busy_ = true; }
  void complete(uint32_t now, bool full) {
    busy_ = false;
    history_ = true;
    finishedAt_ = now;
    if (full) { partials_ = 0; cleanedAt_ = now; }
    else ++partials_;
  }
  // One reset/reinitialize retry; a second failure latches until explicit wake.
  bool fail() {
    busy_ = false;
    history_ = false;
    if (++failures_ > 1) fault_ = true;
    return !fault_;
  }
  void recovered() { failures_ = 0; }
  void sleep() { sleeping_ = true; history_ = false; }
  void wake() { sleeping_ = false; history_ = false; fault_ = false; failures_ = 0; }
  bool fault() const { return fault_; }
  bool busy() const { return busy_; }
private:
  bool history_ = false, busy_ = false, fault_ = false, sleeping_ = false;
  uint8_t failures_ = 0;
  uint16_t partials_ = 0;
  uint32_t finishedAt_ = 0, cleanedAt_ = 0;
};
} // namespace epaper
