#include "display_power.hpp"
#include "display_power_preferences.hpp"

#include "../panel/WAVESHARE_AMOLED_175.hpp"
#include "../power_management/power_management.hpp"
#include "../power_metrics/power_metrics.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"

#include <Arduino.h>
#include <Arduino_GFX_Library.h>
#include <Preferences.h>

namespace {

constexpr char kBrightnessKey[] = "brightnessPct";

} // namespace

DisplayPowerManager displayPowerManager;

bool DisplayPowerManager::lock() const {
  return mutex_ != nullptr &&
         xSemaphoreTake(mutex_, pdMS_TO_TICKS(250)) == pdTRUE;
}

void DisplayPowerManager::unlock() const { xSemaphoreGive(mutex_); }

bool DisplayPowerManager::begin() {
  if (initialized_) {
    return true;
  }

  mutex_ = xSemaphoreCreateMutexStatic(&mutexStorage_);
  if (mutex_ == nullptr) {
    Serial.println("DisplayPower: failed to create state mutex");
    return false;
  }

  Preferences preferences;
  bool hasSavedValue = false;
  uint8_t savedValue = display_power::kDefaultBrightnessPercent;
  bool hasSavedAutomaticDisplayOff = false;
  bool automaticDisplayOff =
      display_power::kDefaultAutomaticDisplayOffEnabled;
  if (display_power::beginDeviceSettingsPreferences(preferences)) {
    hasSavedValue = preferences.isKey(kBrightnessKey);
    if (hasSavedValue) {
      savedValue = preferences.getUChar(
          kBrightnessKey, display_power::kDefaultBrightnessPercent);
    }
    automaticDisplayOff = display_power::loadAutomaticDisplayOff(
        preferences, hasSavedAutomaticDisplayOff);
    preferences.end();
  } else {
    Serial.println("DisplayPower: failed to open device settings NVS");
  }

  policy_.restoreSavedBrightness(hasSavedValue, savedValue);
  savedBrightnessPersisted_ =
      hasSavedValue && display_power::isBrightnessPercentInRange(savedValue);
  automaticDisplayOffEnabled_ = automaticDisplayOff;
  automaticDisplayOffPersisted_ = hasSavedAutomaticDisplayOff;
  initialized_ = true;
  return true;
}

bool DisplayPowerManager::requestUserBrightness(int32_t requestedPercent) {
  const uint8_t normalized =
      display_power::clampBrightnessPercent(requestedPercent);
  if (!initialized_ && !begin()) {
    return false;
  }
  if (!lock()) {
    return false;
  }

  if (savedBrightnessPersisted_ &&
      policy_.savedBrightnessPercent() == normalized) {
    unlock();
    return true;
  }

  Preferences preferences;
  const bool opened =
      display_power::beginDeviceSettingsPreferences(preferences);
  const bool persisted =
      opened && preferences.putUChar(kBrightnessKey, normalized) == 1;
  if (opened) {
    preferences.end();
  }
  if (persisted) {
    policy_.requestUserBrightness(normalized);
    savedBrightnessPersisted_ = true;
  }
  unlock();

  if (!persisted) {
    Serial.println("DisplayPower: failed to persist brightness");
  } else {
    ui_scheduler::notify(ui_scheduler::WakeReason::Display);
  }
  return persisted;
}

bool DisplayPowerManager::requestAutomaticDisplayOff(bool enabled) {
  if (!initialized_ && !begin()) {
    return false;
  }
  if (!lock()) {
    return false;
  }

  if (automaticDisplayOffPersisted_ &&
      automaticDisplayOffEnabled_ == enabled) {
    unlock();
    return true;
  }

  Preferences preferences;
  const bool opened =
      display_power::beginDeviceSettingsPreferences(preferences);
  const bool persisted =
      opened && display_power::persistAutomaticDisplayOff(preferences, enabled);
  if (opened) {
    preferences.end();
  }
  if (persisted) {
    automaticDisplayOffEnabled_ = enabled;
    automaticDisplayOffPersisted_ = true;
  }
  unlock();

  if (!persisted) {
    Serial.println("DisplayPower: failed to persist automatic display-off setting");
  } else {
    ui_scheduler::notify(ui_scheduler::WakeReason::Display);
  }
  return persisted;
}

void DisplayPowerManager::requestState(display_power::State state) {
  if (!initialized_ && !begin()) {
    return;
  }
  if (!lock()) {
    return;
  }
  const bool changed = policy_.state() != state;
  policy_.requestState(state);
  unlock();
  if (changed) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Display);
  }
}

display_power::State DisplayPowerManager::state() const {
  if (!lock()) {
    return display_power::State::Active;
  }
  const display_power::State value = policy_.state();
  unlock();
  return value;
}

uint8_t DisplayPowerManager::savedBrightnessPercent() const {
  if (!lock()) {
    return display_power::kDefaultBrightnessPercent;
  }
  const uint8_t value = policy_.savedBrightnessPercent();
  unlock();
  return value;
}

uint8_t DisplayPowerManager::effectiveBrightnessPercent() const {
  if (!lock()) {
    return display_power::kDefaultBrightnessPercent;
  }
  const uint8_t value = policy_.effectiveBrightnessPercent();
  unlock();
  return value;
}

bool DisplayPowerManager::automaticDisplayOffEnabled() const {
  if (!lock()) {
    return display_power::kDefaultAutomaticDisplayOffEnabled;
  }
  const bool value = automaticDisplayOffEnabled_;
  unlock();
  return value;
}

bool DisplayPowerManager::initializePanel() {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Display);
  if (gfx == nullptr) {
    return false;
  }

  uint8_t requested = display_power::panelCommandForPercent(
      display_power::kDefaultBrightnessPercent);
  uint8_t effective = requested;
  if (lock()) {
    requested = display_power::panelCommandForPercent(
        policy_.savedBrightnessPercent());
    effective = policy_.effectivePanelCommand();
    gfx->displayOn();
    delay(50);
    gfx->setBrightness(effective);
    policy_.markPanelInitialized();
    unlock();
    power_metrics::noteDisplayState(power_metrics::DisplayState::On, requested,
                                    effective);
    return true;
  }

  // Keep the panel usable even if state tracking could not be initialized.
  gfx->displayOn();
  delay(50);
  gfx->setBrightness(effective);
  power_metrics::noteDisplayState(power_metrics::DisplayState::On, requested,
                                  effective);
  return false;
}

bool DisplayPowerManager::applyPendingPanelChange() {
  if (gfx == nullptr || !lock()) {
    return false;
  }

  display_power::PanelUpdate update;
  const bool hasUpdate = policy_.takePendingPanelUpdate(update);
  const uint8_t requested = display_power::panelCommandForPercent(
      policy_.savedBrightnessPercent());
  unlock();
  if (!hasUpdate) {
    return false;
  }

  power_management::ScopedLock powerLock(
      power_management::LockDomain::Display);

  if (update.turnDisplayOff) {
    gfx->setBrightness(0);
    gfx->displayOff();
  } else {
    if (update.turnDisplayOn) {
      gfx->displayOn();
      delay(50);
    }
    if (update.setBrightness) {
      gfx->setBrightness(update.brightnessCommand);
    }
  }

  power_metrics::noteDisplayState(
      update.state == display_power::State::Off
          ? power_metrics::DisplayState::Off
          : power_metrics::DisplayState::On,
      requested, update.brightnessCommand);
  return true;
}

bool DisplayPowerManager::takeFullRefreshRequired() {
  if (!lock()) {
    return false;
  }
  const bool required = policy_.takeFullRefreshRequired();
  unlock();
  return required;
}
