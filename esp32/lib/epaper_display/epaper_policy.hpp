#pragma once

#include <cstdint>

namespace epaper {
// Experimental defaults, deliberately excluded from release/factory profiles.
// Physical qualification must establish temperature and panel wear limits.
constexpr uint32_t routineIntervalMs = 1000;
constexpr uint32_t waveformRestMs = 250;
constexpr uint32_t fullWaveformRestMs = 1000;
// The panel documentation specifies waveform timings but no safe elapsed-time
// cleaning interval. Count successful partial waveforms instead of refreshing
// static glass on a timer. The provisional count remains a qualification item.
constexpr uint32_t busyTimeoutMs = 10000;
constexpr uint16_t partialLimit = 20;
constexpr uint32_t panelIdleSleepMs = 60000;

enum class RefreshReason : uint8_t { Startup, Partial, Cleaning, Wake, Recovery };
constexpr const char *refreshReasonName(RefreshReason reason) {
  switch (reason) {
  case RefreshReason::Startup: return "startup";
  case RefreshReason::Partial: return "partial";
  case RefreshReason::Cleaning: return "cleaning";
  case RefreshReason::Wake: return "wake";
  case RefreshReason::Recovery: return "recovery";
  }
  return "unknown";
}

class PresentationPolicy {
public:
  bool ready(uint32_t now, bool urgent, bool allowSleeping = false) const {
    return !fault_ && (!sleeping_ || allowSleeping) && !busy_ &&
           (!history_ ||
            (uint32_t(now - finishedAt_) >=
                 (lastFull_ ? fullWaveformRestMs : waveformRestMs) &&
             (urgent || uint32_t(now - startedAt_) >= routineIntervalMs)));
  }
  RefreshReason nextReason() const {
    return !history_ ? baseReason_ : partials_ >= partialLimit
        ? RefreshReason::Cleaning : RefreshReason::Partial;
  }
  bool fullRequired(uint32_t = 0) const {
    return nextReason() != RefreshReason::Partial;
  }
  bool shouldSleep(uint32_t now) const {
    return history_ && !fault_ && !sleeping_ && !busy_ &&
           uint32_t(now - finishedAt_) >= panelIdleSleepMs;
  }
  // Routine cadence is start-to-start; the independent completion rest floor
  // prevents slow/failed panels from being driven back-to-back.
  void start(uint32_t now) { busy_ = true; startedAt_ = now; }
  void complete(uint32_t now, bool full) {
    busy_ = false;
    history_ = true;
    finishedAt_ = now;
    lastFull_ = full;
    if (full) { partials_ = 0; }
    else ++partials_;
  }
  // One reset/reinitialize retry; a second failure latches until explicit wake.
  bool fail() {
    busy_ = false;
    history_ = false;
    baseReason_ = RefreshReason::Recovery;
    if (++failures_ > 1) fault_ = true;
    return !fault_;
  }
  void recovered() { failures_ = 0; }
  void sleep() { sleeping_ = true; history_ = false; }
  void sleepFailed(uint32_t now) { finishedAt_ = now; }
  void wake() {
    sleeping_ = false; history_ = false; fault_ = false; failures_ = 0;
    baseReason_ = RefreshReason::Wake;
  }
  bool fault() const { return fault_; }
  bool busy() const { return busy_; }
  bool sleeping() const { return sleeping_; }
  uint16_t partialsSinceFull() const { return partials_; }
  uint32_t lastWaveformMs() const { return finishedAt_; }
private:
  bool history_ = false, busy_ = false, fault_ = false, sleeping_ = false;
  bool lastFull_ = false;
  RefreshReason baseReason_ = RefreshReason::Startup;
  uint8_t failures_ = 0;
  uint16_t partials_ = 0;
  uint32_t startedAt_ = 0, finishedAt_ = 0;
};
} // namespace epaper
