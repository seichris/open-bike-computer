#pragma once

#include "display_power_policy.hpp"

#include <cstdint>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

class DisplayPowerManager {
public:
  bool begin();
  bool requestUserBrightness(int32_t requestedPercent);
  void requestState(display_power::State state);

  display_power::State state() const;
  uint8_t savedBrightnessPercent() const;
  uint8_t effectiveBrightnessPercent() const;

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
  bool initialized_ = false;
};

extern DisplayPowerManager displayPowerManager;
