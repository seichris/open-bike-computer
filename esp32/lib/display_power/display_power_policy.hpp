#pragma once

#include <cstdint>

namespace display_power {

constexpr uint8_t kAutomaticDisplayOffSettingID = 36;
constexpr uint8_t kDisplayInactivityTimeoutsSettingID = 38;
constexpr bool kDefaultAutomaticDisplayOffEnabled = true;
constexpr uint16_t kDefaultDimAfterSeconds = 15;
constexpr uint16_t kDefaultDisplayOffAfterSeconds = 45;
constexpr uint16_t kMinimumDimAfterSeconds = 5;
constexpr uint16_t kMaximumDimAfterSeconds = 600;
constexpr uint16_t kMinimumDisplayOffAfterSeconds = 10;
constexpr uint16_t kMaximumDisplayOffAfterSeconds = 3'600;
constexpr uint16_t kMinimumInactivityStageGapSeconds = 5;
// ESP32 NVS keys are limited to 15 characters (excluding the terminator).
constexpr char kAutomaticDisplayOffPreferencesKey[] = "autoDisplayOff";
constexpr char kDisplayInactivityTimeoutsPreferencesKey[] = "idleTimeouts";
static_assert(sizeof(kAutomaticDisplayOffPreferencesKey) - 1 <= 15,
              "automatic display-off NVS key exceeds the ESP32 limit");
static_assert(sizeof(kDisplayInactivityTimeoutsPreferencesKey) - 1 <= 15,
              "display inactivity timeouts NVS key exceeds the ESP32 limit");
constexpr uint8_t kMinimumBrightnessPercent = 5;
constexpr uint8_t kMaximumBrightnessPercent = 100;
constexpr uint8_t kDefaultBrightnessPercent = 100;
constexpr uint8_t kDefaultDimmedBrightnessPercent = 20;

constexpr bool isBooleanSettingValue(int32_t value) {
  return value == 0 || value == 1;
}

template <typename Manager>
bool applyAutomaticDisplayOffSetting(Manager &manager, int32_t value) {
  return isBooleanSettingValue(value) &&
         manager.requestAutomaticDisplayOff(value == 1);
}

struct InactivityTimeouts {
  uint16_t dimAfterSeconds = kDefaultDimAfterSeconds;
  uint16_t displayOffAfterSeconds = kDefaultDisplayOffAfterSeconds;
};

constexpr bool areInactivityTimeoutsValid(uint16_t dimAfterSeconds,
                                          uint16_t displayOffAfterSeconds) {
  return dimAfterSeconds >= kMinimumDimAfterSeconds &&
         dimAfterSeconds <= kMaximumDimAfterSeconds &&
         displayOffAfterSeconds >= kMinimumDisplayOffAfterSeconds &&
         displayOffAfterSeconds <= kMaximumDisplayOffAfterSeconds &&
         displayOffAfterSeconds >=
             dimAfterSeconds + kMinimumInactivityStageGapSeconds;
}

constexpr uint32_t encodeInactivityTimeouts(uint16_t dimAfterSeconds,
                                            uint16_t displayOffAfterSeconds) {
  return static_cast<uint32_t>(dimAfterSeconds) |
         (static_cast<uint32_t>(displayOffAfterSeconds) << 16);
}

constexpr bool decodeInactivityTimeouts(int32_t packedValue,
                                        InactivityTimeouts &timeouts) {
  const uint32_t packed = static_cast<uint32_t>(packedValue);
  const uint16_t dimAfterSeconds = static_cast<uint16_t>(packed & 0xFFFFU);
  const uint16_t displayOffAfterSeconds =
      static_cast<uint16_t>((packed >> 16) & 0xFFFFU);
  if (!areInactivityTimeoutsValid(dimAfterSeconds, displayOffAfterSeconds)) {
    return false;
  }
  timeouts.dimAfterSeconds = dimAfterSeconds;
  timeouts.displayOffAfterSeconds = displayOffAfterSeconds;
  return true;
}

template <typename Manager>
bool applyInactivityTimeoutsSetting(Manager &manager, int32_t packedValue) {
  InactivityTimeouts timeouts;
  return decodeInactivityTimeouts(packedValue, timeouts) &&
         manager.requestDisplayInactivityTimeouts(
             timeouts.dimAfterSeconds, timeouts.displayOffAfterSeconds);
}

constexpr bool isBrightnessPercentInRange(int32_t value) {
  return value >= kMinimumBrightnessPercent &&
         value <= kMaximumBrightnessPercent;
}

constexpr uint8_t clampBrightnessPercent(int32_t value) {
  return value < kMinimumBrightnessPercent
             ? kMinimumBrightnessPercent
             : (value > kMaximumBrightnessPercent
                    ? kMaximumBrightnessPercent
                    : static_cast<uint8_t>(value));
}

constexpr uint8_t panelCommandForPercent(uint8_t percent) {
  const uint16_t clamped = clampBrightnessPercent(percent);
  return static_cast<uint8_t>((clamped * 255u + 50u) / 100u);
}

enum class State : uint8_t {
  Active = 0,
  Dimmed,
  Off,
};

struct PanelUpdate {
  State state = State::Active;
  uint8_t brightnessCommand = 255;
  bool turnDisplayOn = false;
  bool turnDisplayOff = false;
  bool setBrightness = false;
};

class Policy {
public:
  void restoreSavedBrightness(bool hasSavedValue, int32_t savedValue) {
    savedBrightnessPercent_ =
        hasSavedValue ? clampBrightnessPercent(savedValue)
                      : kDefaultBrightnessPercent;
    recomputePending();
  }

  void requestUserBrightness(int32_t requestedPercent) {
    savedBrightnessPercent_ = clampBrightnessPercent(requestedPercent);
    recomputePending();
  }

  void requestState(State state) {
    requestedState_ = state;
    recomputePending();
  }

  State state() const { return requestedState_; }
  uint8_t savedBrightnessPercent() const { return savedBrightnessPercent_; }

  uint8_t effectiveBrightnessPercent() const {
    if (requestedState_ == State::Off) {
      return 0;
    }
    if (requestedState_ == State::Dimmed &&
        savedBrightnessPercent_ > kDefaultDimmedBrightnessPercent) {
      return kDefaultDimmedBrightnessPercent;
    }
    return savedBrightnessPercent_;
  }

  uint8_t effectivePanelCommand() const {
    const uint8_t percent = effectiveBrightnessPercent();
    return percent == 0 ? 0 : panelCommandForPercent(percent);
  }

  void markPanelInitialized() {
    panelInitialized_ = true;
    appliedState_ = requestedState_;
    appliedBrightnessCommand_ = effectivePanelCommand();
    pendingPanelChange_ = false;
    fullRefreshRequired_ = false;
  }

  bool takePendingPanelUpdate(PanelUpdate &update) {
    if (!panelInitialized_ || !pendingPanelChange_) {
      return false;
    }

    const uint8_t command = effectivePanelCommand();
    update.state = requestedState_;
    update.brightnessCommand = command;
    update.turnDisplayOn =
        appliedState_ == State::Off && requestedState_ != State::Off;
    update.turnDisplayOff =
        appliedState_ != State::Off && requestedState_ == State::Off;
    update.setBrightness =
        requestedState_ != State::Off &&
        (update.turnDisplayOn || command != appliedBrightnessCommand_);

    if (update.turnDisplayOn) {
      fullRefreshRequired_ = true;
    }

    appliedState_ = requestedState_;
    appliedBrightnessCommand_ = command;
    pendingPanelChange_ = false;
    return update.turnDisplayOn || update.turnDisplayOff ||
           update.setBrightness;
  }

  bool takeFullRefreshRequired() {
    const bool required = fullRefreshRequired_;
    fullRefreshRequired_ = false;
    return required;
  }

private:
  void recomputePending() {
    if (!panelInitialized_) {
      pendingPanelChange_ = true;
      return;
    }
    pendingPanelChange_ =
        requestedState_ != appliedState_ ||
        (requestedState_ != State::Off &&
         effectivePanelCommand() != appliedBrightnessCommand_);
  }

  uint8_t savedBrightnessPercent_ = kDefaultBrightnessPercent;
  State requestedState_ = State::Active;
  State appliedState_ = State::Off;
  uint8_t appliedBrightnessCommand_ = 0;
  bool panelInitialized_ = false;
  bool pendingPanelChange_ = true;
  bool fullRefreshRequired_ = false;
};

} // namespace display_power
