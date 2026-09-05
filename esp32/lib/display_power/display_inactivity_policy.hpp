#pragma once

#include <cstdint>

namespace display_inactivity {

constexpr uint32_t kDimAfterMs = 15'000;
constexpr uint32_t kDisplayOffAfterMs = 45'000;
constexpr uint32_t kTransferInactivityTimeoutMs = 300'000;

enum class Mode : uint8_t {
  Active = 0,
  Dimmed,
  DisplayOff,
  Transfer,
};

constexpr bool isTouchWakeDisplayMode(Mode currentMode) {
  return currentMode == Mode::Dimmed || currentMode == Mode::DisplayOff;
}

constexpr bool touchWakeRequested(Mode currentMode, bool interruptNotified,
                                  bool controllerInterruptActive) {
  return interruptNotified ||
         (isTouchWakeDisplayMode(currentMode) && controllerInterruptActive);
}

constexpr bool touchActivityAdvanced(uint32_t currentGeneration,
                                     uint32_t observedGeneration) {
  return currentGeneration != observedGeneration;
}

constexpr bool shouldPollTouchWhileDisplayInactive(Mode currentMode,
                                                    bool decodedTouchPollingRequired) {
  return decodedTouchPollingRequired && isTouchWakeDisplayMode(currentMode);
}

struct Context {
  bool navigating = false;
  bool workoutActive = false;
  bool automaticDisplayOffEnabled = true;
  bool transferActive = false;
  bool attentionActive = false;
};

struct Update {
  Mode previous = Mode::Active;
  Mode current = Mode::Active;
  bool changed = false;
  bool displayWakeRequired = false;
};

constexpr uint32_t elapsedMs(uint32_t nowMs, uint32_t sinceMs) {
  return nowMs - sinceMs;
}

constexpr bool transferInactivityElapsed(uint32_t nowMs,
                                         uint32_t lastUsefulTrafficMs,
                                         uint32_t timeoutMs,
                                         bool authorizedRequestInProgress) {
  const uint32_t elapsed = elapsedMs(nowMs, lastUsefulTrafficMs);
  // The UI task samples nowMs before the HTTPS worker can publish newer
  // authenticated traffic. Treat a modular delta in the upper half-range as
  // a slightly future timestamp, not as nearly 2^32 ms of inactivity. Real
  // timer wrap remains a small forward delta and is still accepted.
  return timeoutMs > 0 && !authorizedRequestInProgress &&
         elapsed < 0x8000'0000U && elapsed >= timeoutMs;
}

constexpr bool maneuverDataBecameActive(uint16_t previousDistanceMeters,
                                        bool previousHasInstruction,
                                        uint16_t currentDistanceMeters,
                                        bool currentHasInstruction) {
  return previousDistanceMeters == 0 && !previousHasInstruction &&
         (currentDistanceMeters > 0 || currentHasInstruction);
}

constexpr uint8_t maneuverDistanceBucket(uint16_t distanceMeters) {
  if (distanceMeters == 0)
    return 0;
  if (distanceMeters <= 25)
    return 1;
  if (distanceMeters <= 50)
    return 2;
  if (distanceMeters <= 100)
    return 3;
  if (distanceMeters <= 200)
    return 4;
  if (distanceMeters <= 500)
    return 5;
  if (distanceMeters <= 1'000)
    return 6;
  return 7;
}

constexpr bool crossedCloserManeuverDistanceThreshold(
    uint16_t previousDistanceMeters, uint16_t currentDistanceMeters) {
  return previousDistanceMeters > 0 &&
         maneuverDistanceBucket(currentDistanceMeters) <
             maneuverDistanceBucket(previousDistanceMeters);
}

class Policy {
public:
  void begin(uint32_t nowMs) {
    initialized_ = true;
    lastMeaningfulActivityMs_ = nowMs;
    heldAwake_ = false;
    automaticDisplayOffEnabled_ = true;
    mode_ = Mode::Active;
  }

  void noteMeaningfulActivity(uint32_t nowMs) {
    if (!initialized_) {
      begin(nowMs);
      return;
    }
    lastMeaningfulActivityMs_ = nowMs;
  }

  Update update(uint32_t nowMs, const Context &context) {
    if (!initialized_) {
      begin(nowMs);
    }

    if (automaticDisplayOffEnabled_ != context.automaticDisplayOffEnabled) {
      // Changing this preference is itself a meaningful boundary. Start a
      // fresh idle interval so enabling automatic display-off never applies
      // the time spent with the preference disabled retroactively.
      automaticDisplayOffEnabled_ = context.automaticDisplayOffEnabled;
      lastMeaningfulActivityMs_ = nowMs;
    }

    const bool heldAwake =
        context.navigating || context.workoutActive || context.transferActive ||
        context.attentionActive;
    if (heldAwake_ && !heldAwake) {
      // Leaving navigation, workout, transfer, pairing, or audio should start
      // a fresh idle interval instead of immediately inheriting the time spent
      // held.
      lastMeaningfulActivityMs_ = nowMs;
    }
    heldAwake_ = heldAwake;

    Mode requested = Mode::Active;
    if (context.transferActive) {
      requested = Mode::Transfer;
    } else if (context.navigating || context.workoutActive ||
               context.attentionActive) {
      requested = Mode::Active;
    } else if (!context.automaticDisplayOffEnabled) {
      requested = Mode::Active;
    } else {
      const uint32_t idleMs = elapsedMs(nowMs, lastMeaningfulActivityMs_);
      if (idleMs >= kDisplayOffAfterMs) {
        requested = Mode::DisplayOff;
      } else if (idleMs >= kDimAfterMs) {
        requested = Mode::Dimmed;
      }
    }

    Update result;
    result.previous = mode_;
    result.current = requested;
    result.changed = requested != mode_;
    result.displayWakeRequired =
        mode_ == Mode::DisplayOff && requested != Mode::DisplayOff;
    mode_ = requested;
    return result;
  }

  Mode mode() const { return mode_; }
  uint32_t lastMeaningfulActivityMs() const {
    return lastMeaningfulActivityMs_;
  }

private:
  bool initialized_ = false;
  bool heldAwake_ = false;
  bool automaticDisplayOffEnabled_ = true;
  uint32_t lastMeaningfulActivityMs_ = 0;
  Mode mode_ = Mode::Active;
};

} // namespace display_inactivity
