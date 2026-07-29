/**
 * @file waitingScr.cpp
 * @brief  LVGL - Waiting for App screen
 * @version 0.2.2
 * @date 2025-05
 */

#include "waitingScr.hpp"
#include "battery.hpp"
#include "mainScr.hpp"
#include "uiUpdatePolicy.hpp"
#include "waitingScreenLayout.hpp"

#include <cstring>

lv_obj_t *waitingScreen = nullptr;
volatile bool gpsReceivedFromApp = false;
volatile bool pendingTransitionToMap = false;
static lv_obj_t *waitingTitle = nullptr;
static lv_obj_t *waitingMessage = nullptr;
static lv_obj_t *waitingBattery = nullptr;
static lv_obj_t *waitingState = nullptr;
static lv_timer_t *waitingBatteryTimer = nullptr;

extern Battery battery;

namespace {

const char *batterySymbol(uint8_t percentage) {
  if (percentage >= 80) {
    return LV_SYMBOL_BATTERY_FULL;
  }
  if (percentage >= 60) {
    return LV_SYMBOL_BATTERY_3;
  }
  if (percentage >= 40) {
    return LV_SYMBOL_BATTERY_2;
  }
  if (percentage >= 20) {
    return LV_SYMBOL_BATTERY_1;
  }
  return LV_SYMBOL_BATTERY_EMPTY;
}

void setLabelTextIfChanged(lv_obj_t *label, const char *text) {
  if (label != nullptr && text != nullptr &&
      strcmp(lv_label_get_text(label), text) != 0) {
    lv_label_set_text(label, text);
  }
}

void setStateColorIfChanged(uint32_t rgb) {
  static uint32_t displayedColor = UINT32_MAX;
  if (waitingState != nullptr && displayedColor != rgb) {
    const lv_color_t color = lv_color_hex(rgb);
    lv_obj_set_style_text_color(waitingState, color, 0);
    lv_obj_set_style_border_color(waitingState, color, 0);
    displayedColor = rgb;
  }
}

void refreshWaitingBatteryIndicator() {
  if (!waitingBattery) {
    return;
  }

  uint8_t percentage = 0;
  bool charging = false;
  char text[48];
  if (!battery.readBatteryStatus(percentage, charging)) {
    snprintf(text, sizeof(text), LV_SYMBOL_BATTERY_EMPTY " --%%");
    setLabelTextIfChanged(waitingBattery, text);
    return;
  }

  if (charging) {
    snprintf(text, sizeof(text), "%s %u%% %s", batterySymbol(percentage),
             percentage, LV_SYMBOL_CHARGE);
  } else {
    snprintf(text, sizeof(text), "%s %u%%", batterySymbol(percentage),
             percentage);
  }
  setLabelTextIfChanged(waitingBattery, text);
}

void updateWaitingBattery(lv_timer_t *) {
  if (waitingScreen && lv_scr_act() == waitingScreen) {
    refreshWaitingBatteryIndicator();
  }
}

void waitingScreenEvent(lv_event_t *event) {
  if (waitingBatteryTimer == nullptr) {
    return;
  }
  const lv_event_code_t code = lv_event_get_code(event);
  if (code == LV_EVENT_SCREEN_LOADED) {
    refreshWaitingBatteryIndicator();
    lv_timer_resume(waitingBatteryTimer);
    lv_timer_reset(waitingBatteryTimer);
  } else if (code == LV_EVENT_SCREEN_UNLOADED) {
    lv_timer_pause(waitingBatteryTimer);
  }
}

} // namespace

// Forward declaration
void loadMainScreen();

/**
 * @brief Check if we should transition to map (called from main loop)
 */
void checkPendingMapTransition() {
  if (pendingTransitionToMap) {
    const uint32_t startMs = millis();
    pendingTransitionToMap = false;
    Serial.printf("UI: pending map transition noticed at %lu ms\n",
                  (unsigned long)startMs);
    log_i("Transitioning from waiting screen to map...");
    loadMainScreen();
    Serial.printf("UI: loadMainScreen completed in %lu ms\n",
                  (unsigned long)(millis() - startMs));
  }
}

/**
 * @brief Create Waiting for App Screen
 */
void createWaitingScr() {
  log_i("createWaitingScr() called");

  waitingScreen = lv_obj_create(NULL);
  lv_obj_set_style_bg_color(waitingScreen, lv_color_black(), 0);
  lv_obj_add_event_cb(waitingScreen, waitingScreenEvent, LV_EVENT_ALL, nullptr);
  const auto layout =
      waiting_screen_layout::makeLayout(TFT_WIDTH, TFT_HEIGHT);

  waitingBattery = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(waitingBattery, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_color(waitingBattery, lv_color_white(), 0);
  lv_obj_set_style_text_align(waitingBattery, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_pos(waitingBattery, layout.battery.x, layout.battery.y);
  lv_obj_set_size(waitingBattery, layout.battery.width,
                  layout.battery.height);
  refreshWaitingBatteryIndicator();
  waitingBatteryTimer = lv_timer_create(
      updateWaitingBattery, ui_update_policy::kWaitingBatteryPeriodMs, NULL);
  lv_timer_pause(waitingBatteryTimer);

  // Title: "Bike Computer"
  waitingTitle = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(waitingTitle, &lv_font_montserrat_42, 0);
  lv_obj_set_style_text_color(waitingTitle, lv_color_white(), 0);
  lv_obj_set_style_text_align(waitingTitle, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(waitingTitle, LV_LABEL_LONG_DOT);
  lv_obj_set_pos(waitingTitle, layout.title.x, layout.title.y);
  lv_obj_set_size(waitingTitle, layout.title.width, layout.title.height);
  lv_label_set_text(waitingTitle, "Bike Computer");

  // A static state badge replaces the spinner. Animation on an AMOLED forces
  // a full-screen flush even when all useful content is unchanged.
  waitingState = lv_label_create(waitingScreen);
  lv_obj_set_pos(waitingState, layout.state.x, layout.state.y);
  lv_obj_set_size(waitingState, layout.state.width, layout.state.height);
  lv_obj_set_style_text_font(waitingState, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_align(waitingState, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_pad_top(waitingState, 17, 0);
  lv_obj_set_style_border_width(waitingState, 3, 0);
  lv_obj_set_style_radius(waitingState, 18, 0);
  lv_obj_set_style_bg_opa(waitingState, LV_OPA_TRANSP, 0);
  lv_label_set_text_static(waitingState, "BLE");
  setStateColorIfChanged(0x72A7FF);

  // Message: "Start the app to start navigation."
  waitingMessage = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(waitingMessage, &lv_font_montserrat_42, 0);
  lv_obj_set_style_text_color(waitingMessage, lv_color_hex(0xAAAAAA), 0);
  lv_obj_set_style_text_align(waitingMessage, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(waitingMessage, "Start the app\nto start navigation.");
  lv_obj_set_pos(waitingMessage, layout.message.x, layout.message.y);
  lv_obj_set_size(waitingMessage, layout.message.width,
                  layout.message.height);

  log_i("waitingScreen created at 0x%p", waitingScreen);
}

void updateWaitingOwnershipStatus(const char *deviceName, bool claimed,
                                  bool connected, bool authenticated,
                                  int32_t pairingCode) {
  if (waitingTitle == nullptr || waitingMessage == nullptr ||
      waitingState == nullptr) {
    return;
  }

  setLabelTextIfChanged(waitingTitle,
                        deviceName == nullptr || deviceName[0] == '\0'
                            ? "Bike Computer"
                            : deviceName);
  if (pairingCode >= 0) {
    char message[64];
    snprintf(message, sizeof(message), "Match %06ld\nthen press a button.",
             static_cast<long>(pairingCode));
    setLabelTextIfChanged(waitingState, "PAIR");
    setStateColorIfChanged(0xF6B73C);
    setLabelTextIfChanged(waitingMessage, message);
  } else if (authenticated) {
    setLabelTextIfChanged(waitingState, "LINK");
    setStateColorIfChanged(0x35D46F);
    setLabelTextIfChanged(waitingMessage, "Connected to\nyour iPhone.");
  } else if (connected) {
    setLabelTextIfChanged(waitingState, "AUTH");
    setStateColorIfChanged(0x72A7FF);
    setLabelTextIfChanged(waitingMessage, "Securing\nyour iPhone link.");
  } else if (claimed) {
    setLabelTextIfChanged(waitingState, "BLE");
    setStateColorIfChanged(0x8B93A1);
    setLabelTextIfChanged(waitingMessage, "Waiting for\nyour iPhone.");
  } else {
    setLabelTextIfChanged(waitingState, "ADD");
    setStateColorIfChanged(0x72A7FF);
    setLabelTextIfChanged(waitingMessage,
                          "Open the app\nand add this device.");
  }
}
