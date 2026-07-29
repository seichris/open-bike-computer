/**
 * @file notifyBar.cpp
 * @brief Change-driven LVGL notification bar.
 */

#include "notifyBar.hpp"
#include "uiUpdatePolicy.hpp"

#include <WiFi.h>
#include <cstring>

lv_obj_t *mainScreen;
lv_obj_t *notifyBarIcons;
lv_obj_t *notifyBarHour;

Storage storage;
Battery battery;
extern Gps gps;

namespace {

lv_obj_t *gpsTime = nullptr;
lv_obj_t *gpsCount = nullptr;
lv_obj_t *gpsFix = nullptr;
lv_obj_t *gpsFixMode = nullptr;
lv_obj_t *battIcon = nullptr;
lv_obj_t *sdCard = nullptr;
lv_obj_t *temp = nullptr;
lv_obj_t *wifi = nullptr;
lv_timer_t *clockTimer = nullptr;
lv_timer_t *statusTimer = nullptr;
ui_update_policy::StatusSnapshot displayedStatus{};
bool statusInitialized = false;

#ifdef ENABLE_TEMP
uint8_t displayedTemperature = UINT8_MAX;
#endif

void setLabelTextIfChanged(lv_obj_t *label, const char *text) {
  if (label != nullptr && text != nullptr &&
      strcmp(lv_label_get_text(label), text) != 0) {
    lv_label_set_text(label, text);
  }
}

const char *batterySymbol(const ui_update_policy::StatusSnapshot &status) {
  if (!status.batteryAvailable) {
    return LV_SYMBOL_BATTERY_EMPTY;
  }
  if (status.batteryCharging) {
    return LV_SYMBOL_CHARGE;
  }
  if (status.batteryLevel >= 80) {
    return LV_SYMBOL_BATTERY_FULL;
  }
  if (status.batteryLevel >= 60) {
    return LV_SYMBOL_BATTERY_3;
  }
  if (status.batteryLevel >= 40) {
    return LV_SYMBOL_BATTERY_2;
  }
  if (status.batteryLevel >= 20) {
    return LV_SYMBOL_BATTERY_1;
  }
  return LV_SYMBOL_BATTERY_EMPTY;
}

const char *fixModeText(uint8_t fixMode) {
  switch (fixMode) {
  case gps_fix::STATUS_STD:
    return " 3D ";
  case gps_fix::STATUS_DGPS:
    return "DGPS";
  case gps_fix::STATUS_PPS:
    return "PPS";
  case gps_fix::STATUS_RTK_FLOAT:
  case gps_fix::STATUS_RTK_FIXED:
    return "RTK";
  case gps_fix::STATUS_TIME_ONLY:
    return "TIME";
  case gps_fix::STATUS_EST:
    return "EST";
  case gps_fix::STATUS_NONE:
  default:
    return "----";
  }
}

void refreshClock(lv_timer_t *) {
  const time_t localTime = time(nullptr);
  struct tm localTm{};
  if (localtime_r(&localTime, &localTm) == nullptr) {
    setLabelTextIfChanged(gpsTime, "--:--");
  } else {
    char text[8];
    snprintf(text, sizeof(text), "%02d:%02d", localTm.tm_hour,
             localTm.tm_min);
    setLabelTextIfChanged(gpsTime, text);
    if (clockTimer != nullptr) {
      lv_timer_set_period(
          clockTimer,
          ui_update_policy::nextMinuteDelayMs(localTm.tm_sec));
      lv_timer_reset(clockTimer);
    }
  }
}

ui_update_policy::StatusSnapshot captureStatus(uint32_t nowMs) {
  static bool batterySampled = false;
  static uint32_t lastBatterySampleMs = 0;
  static bool batteryAvailable = false;
  static int16_t batteryLevel = -1;
  static bool batteryCharging = false;

  ui_update_policy::StatusSnapshot status;
  status.satellites = gps.gpsData.satellites;
  status.fixMode = gps.gpsData.fixMode;
  status.fixed = isGpsFixed;
  status.wifiConnected = WiFi.status() == WL_CONNECTED;
  status.sdLoaded = storage.getSdLoaded();
  if (!batterySampled ||
      static_cast<uint32_t>(nowMs - lastBatterySampleMs) >=
          ui_update_policy::kDeviceBatteryPeriodMs) {
    uint8_t percentage = 0;
    bool charging = false;
    batteryAvailable = battery.readBatteryStatus(percentage, charging);
    batteryLevel =
        batteryAvailable ? static_cast<int16_t>(percentage) : -1;
    batteryCharging = batteryAvailable && charging;
    batterySampled = true;
    lastBatterySampleMs = nowMs;
  }
  status.batteryAvailable = batteryAvailable;
  status.batteryLevel = batteryLevel;
  status.batteryCharging = batteryCharging;
  return status;
}

void refreshStatus(lv_timer_t *) {
  const ui_update_policy::StatusSnapshot current = captureStatus(millis());
  const uint8_t mutations =
      statusInitialized
          ? ui_update_policy::statusMutations(displayedStatus, current)
          : static_cast<uint8_t>(ui_update_policy::StatusGpsCount |
                                 ui_update_policy::StatusGpsFix |
                                 ui_update_policy::StatusWifi |
                                 ui_update_policy::StatusSd |
                                 ui_update_policy::StatusBattery);

  if ((mutations & ui_update_policy::StatusGpsCount) != 0) {
    char text[16];
    snprintf(text, sizeof(text), LV_SYMBOL_GPS "%2u", current.satellites);
    setLabelTextIfChanged(gpsCount, text);
  }
  if ((mutations & ui_update_policy::StatusGpsFix) != 0) {
    setLabelTextIfChanged(gpsFixMode, fixModeText(current.fixMode));
    if (current.fixed) {
      lv_led_on(gpsFix);
    } else {
      lv_led_off(gpsFix);
    }
  }
  if ((mutations & ui_update_policy::StatusWifi) != 0) {
    setLabelTextIfChanged(wifi,
                          current.wifiConnected ? LV_SYMBOL_WIFI : " ");
  }
  if ((mutations & ui_update_policy::StatusSd) != 0) {
    setLabelTextIfChanged(sdCard,
                          current.sdLoaded ? LV_SYMBOL_SD_CARD : " ");
  }
  if ((mutations & ui_update_policy::StatusBattery) != 0) {
    setLabelTextIfChanged(battIcon, batterySymbol(current));
  }

#ifdef ENABLE_TEMP
  const uint8_t temperature =
      static_cast<uint8_t>(bme.readTemperature() + tempOffset);
  if (temperature != displayedTemperature) {
    char text[12];
    snprintf(text, sizeof(text), "%02u\xC2\xB0", temperature);
    setLabelTextIfChanged(temp, text);
    displayedTemperature = temperature;
  }
#endif

  displayedStatus = current;
  statusInitialized = true;
}

void mainScreenTimerEvent(lv_event_t *event) {
  if (clockTimer == nullptr || statusTimer == nullptr) {
    return;
  }
  const lv_event_code_t code = lv_event_get_code(event);
  if (code == LV_EVENT_SCREEN_LOADED) {
    refreshClock(nullptr);
    refreshStatus(nullptr);
    lv_timer_resume(clockTimer);
    lv_timer_resume(statusTimer);
    lv_timer_reset(statusTimer);
  } else if (code == LV_EVENT_SCREEN_UNLOADED) {
    lv_timer_pause(clockTimer);
    lv_timer_pause(statusTimer);
  }
}

} // namespace

void createNotifyBar() {
  notifyBarIcons = lv_obj_create(mainScreen);
  lv_obj_set_size(notifyBarIcons, (TFT_WIDTH / 3) * 2, 24);
  lv_obj_set_pos(notifyBarIcons, (TFT_WIDTH / 3) + 1, 0);
  lv_obj_set_flex_flow(notifyBarIcons, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(notifyBarIcons, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_CENTER,
                        LV_FLEX_ALIGN_CENTER);
  lv_obj_clear_flag(notifyBarIcons, LV_OBJ_FLAG_SCROLLABLE);

  notifyBarHour = lv_obj_create(mainScreen);
  lv_obj_set_size(notifyBarHour, TFT_WIDTH / 3, 24);
  lv_obj_set_pos(notifyBarHour, 0, 0);
  lv_obj_set_flex_flow(notifyBarHour, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(notifyBarHour, LV_FLEX_ALIGN_START,
                        LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_clear_flag(notifyBarHour, LV_OBJ_FLAG_SCROLLABLE);

  static lv_style_t styleBar;
  lv_style_init(&styleBar);
  lv_style_set_bg_opa(&styleBar, LV_OPA_0);
  lv_style_set_border_opa(&styleBar, LV_OPA_0);
  lv_style_set_text_font(&styleBar, fontDefault);
  lv_obj_add_style(notifyBarIcons, &styleBar, LV_PART_MAIN);
  lv_obj_add_style(notifyBarHour, &styleBar, LV_PART_MAIN);

  gpsTime = lv_label_create(notifyBarHour);
  lv_obj_set_style_text_font(gpsTime, fontLarge, 0);
  lv_label_set_text_static(gpsTime, "--:--");

  wifi = lv_label_create(notifyBarIcons);
  lv_label_set_text_static(wifi, " ");

#ifdef ENABLE_TEMP
  temp = lv_label_create(notifyBarIcons);
  lv_label_set_text_static(temp, "--\xC2\xB0");
#endif

  sdCard = lv_label_create(notifyBarIcons);
  lv_label_set_text_static(sdCard, " ");

  gpsCount = lv_label_create(notifyBarIcons);
  lv_label_set_text_static(gpsCount, LV_SYMBOL_GPS " 0");

  gpsFix = lv_led_create(notifyBarIcons);
  lv_led_set_color(gpsFix, lv_palette_main(LV_PALETTE_RED));
  lv_obj_set_size(gpsFix, 7, 7);
  lv_led_off(gpsFix);

  gpsFixMode = lv_label_create(notifyBarIcons);
  lv_obj_set_style_text_font(gpsFixMode, fontSmall, 0);
  lv_label_set_text_static(gpsFixMode, "----");

  battIcon = lv_label_create(notifyBarIcons);
  lv_label_set_text_static(battIcon, LV_SYMBOL_BATTERY_EMPTY);

  clockTimer = lv_timer_create(refreshClock, 60000, nullptr);
  statusTimer = lv_timer_create(refreshStatus,
                                ui_update_policy::kStatusPollPeriodMs, nullptr);
  lv_timer_pause(clockTimer);
  lv_timer_pause(statusTimer);
  lv_obj_add_event_cb(mainScreen, mainScreenTimerEvent, LV_EVENT_ALL, nullptr);
}
