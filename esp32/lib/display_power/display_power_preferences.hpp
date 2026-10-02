#pragma once

#include "display_power_policy.hpp"

namespace display_power {

constexpr char kDeviceSettingsPreferencesNamespace[] = "deviceSettings";

template <typename PreferencesType>
bool beginDeviceSettingsPreferences(PreferencesType &preferences) {
  return preferences.begin(kDeviceSettingsPreferencesNamespace, false);
}

template <typename PreferencesType>
bool loadAutomaticDisplayOff(PreferencesType &preferences,
                             bool &hasSavedValue) {
  hasSavedValue = preferences.isKey(kAutomaticDisplayOffPreferencesKey);
  return hasSavedValue
             ? preferences.getBool(kAutomaticDisplayOffPreferencesKey,
                                   kDefaultAutomaticDisplayOffEnabled)
             : kDefaultAutomaticDisplayOffEnabled;
}

template <typename PreferencesType>
bool persistAutomaticDisplayOff(PreferencesType &preferences, bool enabled) {
  return preferences.putBool(kAutomaticDisplayOffPreferencesKey, enabled) ==
         1;
}

template <typename PreferencesType>
InactivityTimeouts loadDisplayInactivityTimeouts(PreferencesType &preferences,
                                                 bool &hasSavedValue) {
  hasSavedValue =
      preferences.isKey(kDisplayInactivityTimeoutsPreferencesKey);
  if (!hasSavedValue) {
    return {};
  }
  InactivityTimeouts timeouts;
  const uint32_t packed = preferences.getUInt(
      kDisplayInactivityTimeoutsPreferencesKey,
      encodeInactivityTimeouts(kDefaultDimAfterSeconds,
                               kDefaultDisplayOffAfterSeconds));
  if (!decodeInactivityTimeouts(static_cast<int32_t>(packed), timeouts)) {
    hasSavedValue = false;
    return {};
  }
  return timeouts;
}

template <typename PreferencesType>
bool persistDisplayInactivityTimeouts(PreferencesType &preferences,
                                      uint16_t dimAfterSeconds,
                                      uint16_t displayOffAfterSeconds) {
  if (!areInactivityTimeoutsValid(dimAfterSeconds,
                                  displayOffAfterSeconds)) {
    return false;
  }
  return preferences.putUInt(
             kDisplayInactivityTimeoutsPreferencesKey,
             encodeInactivityTimeouts(dimAfterSeconds,
                                      displayOffAfterSeconds)) == 4;
}

} // namespace display_power
