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

} // namespace display_power
