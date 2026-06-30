/**
 * @file waitingScr.cpp
 * @brief  LVGL - Waiting for App screen
 * @version 0.2.2
 * @date 2025-05
 */

#include "waitingScr.hpp"
#include "mainScr.hpp"

lv_obj_t *waitingScreen = nullptr;
volatile bool gpsReceivedFromApp = false;
volatile bool pendingTransitionToMap = false;

// Forward declaration
void loadMainScreen();

/**
 * @brief Check if we should transition to map (called from main loop)
 */
void checkPendingMapTransition() {
  if (pendingTransitionToMap) {
    pendingTransitionToMap = false;
    log_i("Transitioning from waiting screen to map...");
    loadMainScreen();
  }
}

/**
 * @brief Create Waiting for App Screen
 */
void createWaitingScr() {
  log_i("createWaitingScr() called");

  waitingScreen = lv_obj_create(NULL);
  lv_obj_set_style_bg_color(waitingScreen, lv_color_black(), 0);

  // Title: "Bike Computer"
  lv_obj_t *title = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(title, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_label_set_text(title, "Bike Computer");
  lv_obj_set_align(title, LV_ALIGN_CENTER);
  lv_obj_set_y(title, -80);

  // Spinner (animated loading indicator)
  lv_obj_t *spinner = lv_spinner_create(waitingScreen);
  lv_obj_set_size(spinner, 100, 100);
  lv_spinner_set_anim_params(spinner, 1500, 200);
  lv_obj_center(spinner);

  // Message: "Start the app to start navigation."
  lv_obj_t *message = lv_label_create(waitingScreen);
  lv_obj_set_style_text_font(message, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(message, lv_color_hex(0xAAAAAA), 0);
  lv_obj_set_style_text_align(message, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(message, "Start the app\nto start navigation.");
  lv_obj_set_width(message, TFT_WIDTH - 40);
  lv_obj_set_align(message, LV_ALIGN_CENTER);
  lv_obj_set_y(message, 100);

  log_i("waitingScreen created at 0x%p", waitingScreen);
}
