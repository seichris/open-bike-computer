#include "../../lib/display_power/display_power_policy.hpp"
#include "../../lib/display_power/display_power_preferences.hpp"
#include "../../lib/ble_navigation/map_setting_packet.hpp"
#include "../../lib/ble_navigation/map_setting_redraw_policy.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <initializer_list>

struct FakePreferences {
  bool hasValue = false;
  bool value = false;
  bool opened = false;
  bool readOnly = true;
  const char *lastKey = nullptr;

  bool begin(const char *name, bool nextReadOnly) {
    assert(std::strcmp(name,
                       display_power::kDeviceSettingsPreferencesNamespace) ==
           0);
    opened = true;
    readOnly = nextReadOnly;
    return true;
  }

  bool isKey(const char *key) {
    lastKey = key;
    assert(std::strcmp(key,
                       display_power::kAutomaticDisplayOffPreferencesKey) ==
           0);
    return hasValue;
  }
  bool getBool(const char *key, bool fallback) {
    lastKey = key;
    assert(std::strcmp(key,
                       display_power::kAutomaticDisplayOffPreferencesKey) ==
           0);
    return hasValue ? value : fallback;
  }
  size_t putBool(const char *key, bool nextValue) {
    lastKey = key;
    assert(std::strcmp(key,
                       display_power::kAutomaticDisplayOffPreferencesKey) ==
           0);
    hasValue = true;
    value = nextValue;
    return 1;
  }
};

struct FakeDisplayPowerManager {
  int requestCount = 0;
  bool enabled = true;

  bool requestAutomaticDisplayOff(bool nextEnabled) {
    ++requestCount;
    enabled = nextEnabled;
    return true;
  }
};

int main() {
  using display_power::PanelUpdate;
  using display_power::Policy;
  using display_power::State;

  static_assert(display_power::kAutomaticDisplayOffSettingID == 36);
  static_assert(display_power::kDefaultAutomaticDisplayOffEnabled);
  static_assert(sizeof(display_power::kAutomaticDisplayOffPreferencesKey) - 1 <=
                15);
  static_assert(sizeof(display_power::kDeviceSettingsPreferencesNamespace) - 1 <=
                15);
  static_assert(display_power::isBooleanSettingValue(0));
  static_assert(display_power::isBooleanSettingValue(1));
  static_assert(!display_power::isBooleanSettingValue(-1));
  static_assert(!display_power::isBooleanSettingValue(2));

  FakePreferences preferences;
  assert(display_power::beginDeviceSettingsPreferences(preferences));
  assert(preferences.opened);
  assert(!preferences.readOnly);
  bool hasSavedAutomaticDisplayOff = false;
  assert(display_power::loadAutomaticDisplayOff(
             preferences, hasSavedAutomaticDisplayOff) ==
         display_power::kDefaultAutomaticDisplayOffEnabled);
  assert(!hasSavedAutomaticDisplayOff);
  assert(display_power::persistAutomaticDisplayOff(preferences, false));
  assert(!display_power::loadAutomaticDisplayOff(
      preferences, hasSavedAutomaticDisplayOff));
  assert(hasSavedAutomaticDisplayOff);

  FakeDisplayPowerManager manager;
  assert(!display_power::applyAutomaticDisplayOffSetting(manager, 2));
  assert(manager.requestCount == 0);
  assert(display_power::applyAutomaticDisplayOffSetting(manager, 0));
  assert(manager.requestCount == 1);
  assert(!manager.enabled);

  static_assert(!display_power::isBrightnessPercentInRange(4));
  static_assert(display_power::isBrightnessPercentInRange(5));
  static_assert(display_power::isBrightnessPercentInRange(100));
  static_assert(!display_power::isBrightnessPercentInRange(101));
  static_assert(display_power::clampBrightnessPercent(-1) == 5);
  static_assert(display_power::clampBrightnessPercent(5) == 5);
  static_assert(display_power::clampBrightnessPercent(75) == 75);
  static_assert(display_power::clampBrightnessPercent(101) == 100);
  static_assert(display_power::clampBrightnessPercent(INT32_MIN) == 5);
  static_assert(display_power::clampBrightnessPercent(INT32_MAX) == 100);
  static_assert(display_power::panelCommandForPercent(5) == 13);
  static_assert(display_power::panelCommandForPercent(25) == 64);
  static_assert(display_power::panelCommandForPercent(50) == 128);
  static_assert(display_power::panelCommandForPercent(75) == 191);
  static_assert(display_power::panelCommandForPercent(100) == 255);

  Policy firstBoot;
  firstBoot.restoreSavedBrightness(false, 0);
  assert(firstBoot.savedBrightnessPercent() == 100);
  assert(firstBoot.effectivePanelCommand() == 255);

  Policy restored;
  restored.restoreSavedBrightness(true, 75);
  assert(restored.savedBrightnessPercent() == 75);
  assert(restored.effectivePanelCommand() == 191);
  restored.markPanelInitialized();

  restored.requestUserBrightness(50);
  PanelUpdate update;
  assert(restored.takePendingPanelUpdate(update));
  assert(!update.turnDisplayOn);
  assert(!update.turnDisplayOff);
  assert(update.setBrightness);
  assert(update.brightnessCommand == 128);

  restored.requestState(State::Dimmed);
  assert(restored.takePendingPanelUpdate(update));
  assert(update.brightnessCommand == 51);

  restored.requestUserBrightness(5);
  assert(restored.takePendingPanelUpdate(update));
  assert(update.brightnessCommand == 13);

  restored.requestState(State::Off);
  assert(restored.takePendingPanelUpdate(update));
  assert(update.turnDisplayOff);
  assert(update.brightnessCommand == 0);
  restored.requestUserBrightness(90);
  assert(!restored.takePendingPanelUpdate(update));

  restored.requestState(State::Active);
  assert(restored.takePendingPanelUpdate(update));
  assert(update.turnDisplayOn);
  assert(update.setBrightness);
  assert(update.brightnessCommand == 230);
  assert(restored.takeFullRefreshRequired());
  assert(!restored.takeFullRefreshRequired());

  for (int cycle = 0; cycle < 10'000; ++cycle) {
    restored.requestState(State::Off);
    assert(restored.takePendingPanelUpdate(update));
    assert(update.turnDisplayOff);
    restored.requestState(State::Active);
    assert(restored.takePendingPanelUpdate(update));
    assert(update.turnDisplayOn);
    assert(restored.takeFullRefreshRequired());
    assert(!restored.takeFullRefreshRequired());
  }

  for (uint8_t id : {uint8_t{1}, uint8_t{2}, uint8_t{3}, uint8_t{6},
                     uint8_t{7}, uint8_t{8}, uint8_t{9}, uint8_t{10},
                     uint8_t{16}, uint8_t{17}, uint8_t{18}, uint8_t{19},
                     uint8_t{20}, uint8_t{21}, uint8_t{22}, uint8_t{25},
                     uint8_t{26}, uint8_t{27}, uint8_t{28}, uint8_t{29},
                     uint8_t{30}, uint8_t{31}, uint8_t{32}, uint8_t{33},
                     uint8_t{34}}) {
    assert(map_setting_redraw_policy::invalidatesMap(id));
  }
  for (uint8_t id : {uint8_t{4}, uint8_t{5}, uint8_t{11}, uint8_t{12},
                     uint8_t{13}, uint8_t{14}, uint8_t{15}, uint8_t{23},
                     uint8_t{24}, uint8_t{255}}) {
    assert(!map_setting_redraw_policy::invalidatesMap(id));
  }
  assert(map_setting_redraw_policy::changesZoom(7));
  assert(map_setting_redraw_policy::changesZoom(19));
  assert(!map_setting_redraw_policy::changesZoom(3));
  assert(!map_setting_redraw_policy::changesZoom(20));

  map_setting_packet::Packet packet;
  const uint8_t positivePacket[] = {12, 75, 0, 0, 0};
  assert(map_setting_packet::decode(positivePacket, sizeof(positivePacket),
                                    packet));
  assert(packet.settingId == 12);
  assert(packet.value == 75);

  const uint8_t negativePacket[] = {9, 0xFD, 0xFF, 0xFF, 0xFF};
  assert(map_setting_packet::decode(negativePacket, sizeof(negativePacket),
                                    packet));
  assert(packet.settingId == 9);
  assert(packet.value == -3);
  assert(!map_setting_packet::decode(nullptr, 5, packet));
  assert(!map_setting_packet::decode(positivePacket, 4, packet));
  assert(!map_setting_packet::decode(positivePacket, 6, packet));

  return 0;
}
