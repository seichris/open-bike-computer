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
// static glass on a timer. The owner chose 160 on 2026-10-30 after seeing only
// very slight ghosting at that count on one panel at room temperature; cold,
// heat and a second panel remain qualification items. The panel diagnostic
// keeps 20 so its pattern cycles still reach a count-driven cleaning.
constexpr uint32_t busyTimeoutMs = 10000;
#ifdef EPAPER_DISPLAY_TEST
constexpr uint16_t partialLimit = 20;
#else
constexpr uint16_t partialLimit = 160;
#endif
constexpr uint32_t panelIdleSleepMs = 60000;
// A latched fault no longer lasts until reboot. After this delay the worker
// retries one full refresh, which resets and reinitializes the controller; each
// failed retry doubles the delay up to the maximum.
constexpr uint32_t faultRetryInitialMs = 5000;
constexpr uint32_t faultRetryMaximumMs = 300000;

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

// The pairing comparison stays attested on glass through a partial waveform of
// a frame with the same pairing and context: the code's pixels are unchanged,
// and a partial waveform drives only changed pixels. A full waveform flashes the
// whole panel and a different frame may replace the code, so both withdraw the
// attestation before they start; a failed waveform withdraws it too.
constexpr bool keepsComparisonOnGlass(uint32_t shownPairing,
                                      uint32_t shownContext,
                                      uint32_t framePairing,
                                      uint32_t frameContext,
                                      bool fullWaveform) {
  return shownPairing != 0 && !fullWaveform && framePairing == shownPairing &&
         frameContext == shownContext;
}

// A confirmation needs the comparison for the current pairing and context.
constexpr bool comparisonOnGlass(uint32_t shownPairing, uint32_t shownContext,
                                 uint32_t currentPairing,
                                 uint32_t currentContext) {
  return currentPairing != 0 && shownPairing == currentPairing &&
         shownContext == currentContext;
}

class PresentationPolicy {
public:
  // An idle-sleeping panel still takes a frame, so changed content can wake
  // it; an explicitly sleeping panel waits for an explicit wake. A latched
  // fault takes a frame only when its retry is due.
  bool ready(uint32_t now, bool urgent) const {
    if (busy_ || explicitSleep()) return false;
    if (fault_) return faultRetryDue(now);
    return !history_ ||
           (uint32_t(now - finishedAt_) >=
                (lastFull_ ? fullWaveformRestMs : waveformRestMs) &&
            (urgent || uint32_t(now - startedAt_) >= routineIntervalMs));
  }
  bool faultRetryDue(uint32_t now) const {
    return fault_ && uint32_t(now - faultedAt_) >= faultRetryDelayMs();
  }
  uint32_t faultRetryDelayMs() const {
    uint32_t delay = faultRetryInitialMs;
    for (uint8_t i = 0; i < faultRetries_ && delay < faultRetryMaximumMs; ++i)
      delay *= 2;
    return delay < faultRetryMaximumMs ? delay : faultRetryMaximumMs;
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
           uint32_t(now - finishedAt_) >= panelIdleSleepMs &&
           (!sleepRetryPending_ ||
            uint32_t(now - sleepFailedAt_) >= panelIdleSleepMs);
  }
  // Routine cadence is start-to-start; the independent completion rest floor
  // prevents slow/failed panels from being driven back-to-back.
  void start(uint32_t now) { busy_ = true; startedAt_ = now; }
  void complete(uint32_t now, bool full) {
    busy_ = false;
    history_ = true;
    finishedAt_ = now;
    lastFull_ = full;
    sleepRetryPending_ = false;
    if (full) { partials_ = 0; }
    else ++partials_;
  }
  // The first failure allows one reset/reinitialize retry; a second latches a
  // fault. A failed fault retry keeps the fault and lengthens the next delay.
  bool fail(uint32_t now) {
    busy_ = false;
    history_ = false;
    baseReason_ = RefreshReason::Recovery;
    if (fault_) {
      faultedAt_ = now;
      if (faultRetries_ < UINT8_MAX) ++faultRetries_;
      return false;
    }
    if (++failures_ > 1) {
      fault_ = true;
      faultedAt_ = now;
      faultRetries_ = 0;
    }
    return !fault_;
  }
  void recovered() { failures_ = 0; fault_ = false; faultRetries_ = 0; }
  void sleep(bool explicitRequest = false) {
    sleeping_ = true;
    explicitSleep_ = explicitRequest;
    history_ = false;
    sleepRetryPending_ = false;
  }
  // A failed sleep command retries after its own idle interval; it does not
  // pose as a waveform or delay the next frame.
  void sleepFailed(uint32_t now) {
    sleepRetryPending_ = true;
    sleepFailedAt_ = now;
  }
  void wake() {
    sleeping_ = false; explicitSleep_ = false; history_ = false;
    fault_ = false; failures_ = 0; faultRetries_ = 0;
    baseReason_ = RefreshReason::Wake;
  }
  bool fault() const { return fault_; }
  bool busy() const { return busy_; }
  bool sleeping() const { return sleeping_; }
  bool explicitSleep() const { return sleeping_ && explicitSleep_; }
  uint16_t partialsSinceFull() const { return partials_; }
  uint32_t lastWaveformMs() const { return finishedAt_; }
private:
  bool history_ = false, busy_ = false, fault_ = false, sleeping_ = false;
  bool explicitSleep_ = false, lastFull_ = false, sleepRetryPending_ = false;
  RefreshReason baseReason_ = RefreshReason::Startup;
  uint8_t failures_ = 0, faultRetries_ = 0;
  uint16_t partials_ = 0;
  uint32_t startedAt_ = 0, finishedAt_ = 0, faultedAt_ = 0, sleepFailedAt_ = 0;
};
} // namespace epaper
