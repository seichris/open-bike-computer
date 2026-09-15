#pragma once

#include "display_power_policy.hpp"

#include <cstdint>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

class DisplayPowerManager {
public:
  bool begin();
  bool requestUserBrightness(int32_t requestedPercent);
  bool requestAutomaticDisplayOff(bool enabled);
  bool requestDisplayInactivityTimeouts(uint16_t dimAfterSeconds,
                                        uint16_t displayOffAfterSeconds);
  void requestState(display_power::State state);

  display_power::State state() const;
  uint8_t savedBrightnessPercent() const;
  uint8_t effectiveBrightnessPercent() const;
  bool automaticDisplayOffEnabled() const;
  display_power::InactivityTimeouts displayInactivityTimeouts() const;

  bool initializePanel();
  bool applyPendingPanelChange();
  bool takeFullRefreshRequired();

private:
  bool lock() const;
  void unlock() const;

  mutable StaticSemaphore_t mutexStorage_{};
  mutable SemaphoreHandle_t mutex_ = nullptr;
  display_power::Policy policy_;
  bool savedBrightnessPersisted_ = false;
  bool automaticDisplayOffEnabled_ =
      display_power::kDefaultAutomaticDisplayOffEnabled;
  bool automaticDisplayOffPersisted_ = false;
  uint16_t dimAfterSeconds_ = display_power::kDefaultDimAfterSeconds;
  uint16_t displayOffAfterSeconds_ =
      display_power::kDefaultDisplayOffAfterSeconds;
  bool displayInactivityTimeoutsPersisted_ = false;
  bool initialized_ = false;
};

extern DisplayPowerManager displayPowerManager;
