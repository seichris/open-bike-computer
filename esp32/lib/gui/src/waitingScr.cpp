/**
 * @file waitingScr.cpp
 * @brief  LVGL - Waiting for App screen
 * @version 0.2.2
 * @date 2025-05
 */

#include "waitingScr.hpp"
#include "battery.hpp"
#include "mainScr.hpp"

lv_obj_t *waitingScreen = nullptr;
volatile bool gpsReceivedFromApp = false;
volatile bool pendingTransitionToMap = false;
static lv_obj_t *waitingTitle = nullptr;
static lv_obj_t *waitingMessage = nullptr;
static lv_obj_t *waitingBattery = nullptr;

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

void refreshWaitingBatteryIndicator() {
  if (!waitingBattery) {
    return;
  }

  uint8_t percentage = 0;
  bool charging = false;
  if (!battery.readBatteryStatus(percentage, charging)) {
    lv_label_set_text_static(waitingBattery,
                             LV_SYMBOL_BATTERY_EMPTY " --%");
    return;
  }

  if (charging) {
    lv_label_set_text_fmt(waitingBattery, "%s %u%% %s",
                          batterySymbol(percentage), percentage,
                          LV_SYMBOL_CHARGE);
  } else {
    lv_label_set_text_fmt(waitingBattery, "%s %u%%", batterySymbol(percentage),
                          percentage);
  }
}

void updateWaitingBattery(lv_timer_t *) {
  if (waitingScreen && lv_scr_act() == waitingScreen) {
    refreshWaitingBatteryIndicator();
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

  waitingBattery = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(waitingBattery, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_color(waitingBattery, lv_color_white(), 0);
  lv_obj_set_style_text_align(waitingBattery, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(waitingBattery, 210);
  lv_obj_align(waitingBattery, LV_ALIGN_TOP_MID, 0, 45);
  refreshWaitingBatteryIndicator();
  lv_timer_t *batteryTimer = lv_timer_create(updateWaitingBattery, 1000, NULL);
  lv_timer_ready(batteryTimer);

  // Title: "Bike Computer"
  waitingTitle = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(waitingTitle, &lv_font_montserrat_42, 0);
  lv_obj_set_style_text_color(waitingTitle, lv_color_white(), 0);
  lv_obj_set_style_text_align(waitingTitle, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(waitingTitle, LV_LABEL_LONG_DOT);
  lv_obj_set_width(waitingTitle, TFT_WIDTH - 24);
  lv_label_set_text(waitingTitle, "Bike Computer");
  lv_obj_set_align(waitingTitle, LV_ALIGN_CENTER);
  lv_obj_set_y(waitingTitle, -105);

  // Spinner (animated loading indicator)
  lv_obj_t *spinner = lv_spinner_create(waitingScreen);
  lv_obj_set_size(spinner, 100, 100);
  lv_spinner_set_anim_params(spinner, 1500, 200);
  lv_obj_center(spinner);

  // Message: "Start the app to start navigation."
  waitingMessage = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(waitingMessage, &lv_font_montserrat_42, 0);
  lv_obj_set_style_text_color(waitingMessage, lv_color_hex(0xAAAAAA), 0);
  lv_obj_set_style_text_align(waitingMessage, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(waitingMessage, "Start the app\nto start navigation.");
  lv_obj_set_width(waitingMessage, TFT_WIDTH - 24);
  lv_obj_set_align(waitingMessage, LV_ALIGN_CENTER);
  lv_obj_set_y(waitingMessage, 125);

  log_i("waitingScreen created at 0x%p", waitingScreen);
}

void updateWaitingOwnershipStatus(const char *deviceName, bool claimed,
                                  int32_t pairingCode) {
  if (waitingTitle == nullptr || waitingMessage == nullptr) {
    return;
  }

  lv_label_set_text(waitingTitle,
                    deviceName == nullptr || deviceName[0] == '\0'
                        ? "Bike Computer"
                        : deviceName);
  if (pairingCode >= 0) {
    lv_label_set_text_fmt(waitingMessage, "Match %06ld\nthen press a button.",
                          static_cast<long>(pairingCode));
  } else if (claimed) {
    lv_label_set_text(waitingMessage, "Waiting for\nyour iPhone.");
  } else {
    lv_label_set_text(waitingMessage, "Open the app\nand add this device.");
  }
}
