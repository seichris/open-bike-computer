/**
 * @file settingsScr.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL - Settings Screen
 * @version 0.2.2
 * @date 2025-05
 */

#include "settingsScr.hpp"

bool needReboot = false;

/**
 * @brief Back button event
 *
 * @param event
 */
static void back(lv_event_t *event) {
  if (isSearchingSat) {
    lv_timer_pause(mainTimer);
    lv_screen_load(searchSatScreen);
  } else
    loadMainScreen();
}

/**
 * @brief Map Setting
 *
 * @param event
 */
static void mapSettings(lv_event_t *event) {
  lv_screen_load(mapSettingsScreen);
}

/**
 * @brief Device Settings
 *
 * @param event
 */
static void deviceSettings(lv_event_t *event) {
  lv_screen_load(deviceSettingsScreen);
}

/**
 * @brief Create Settings screen
 *
 */
void createSettingsScr() {
  // Settings Screen
  settingsScreen = lv_obj_create(NULL);
  settingsButtons = lv_obj_create(settingsScreen);
  lv_obj_set_size(settingsButtons, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_flex_align(settingsButtons, LV_FLEX_ALIGN_START,
                        LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_row(settingsButtons, 20, 0);
  lv_obj_set_flex_flow(settingsButtons, LV_FLEX_FLOW_COLUMN);
  static lv_style_t styleSettings;
  lv_style_init(&styleSettings);
  lv_style_set_bg_opa(&styleSettings, LV_OPA_0);
  lv_style_set_border_opa(&styleSettings, LV_OPA_0);
  lv_obj_add_style(settingsButtons, &styleSettings, LV_PART_MAIN);

  lv_obj_t *btnLabel;
  lv_obj_t *btn;



  // Map Settings
  btn = lv_btn_create(settingsButtons);
  lv_obj_set_size(btn, TFT_WIDTH - 30, 40 * scale);
  btnLabel = lv_label_create(btn);
  lv_obj_set_style_text_font(btnLabel, fontLarge, 0);
  lv_label_set_text_static(btnLabel, "Map Settings");
  lv_obj_center(btnLabel);
  lv_obj_add_event_cb(btn, mapSettings, LV_EVENT_CLICKED, NULL);

  // Device Settings
  btn = lv_btn_create(settingsButtons);
  lv_obj_set_size(btn, TFT_WIDTH - 30, 40 * scale);
  btnLabel = lv_label_create(btn);
  lv_obj_set_style_text_font(btnLabel, fontLarge, 0);
  lv_label_set_text_static(btnLabel, "Device Settings");
  lv_obj_center(btnLabel);
  lv_obj_add_event_cb(btn, deviceSettings, LV_EVENT_CLICKED, NULL);

  // Back button
  btn = lv_btn_create(settingsButtons);
  lv_obj_set_size(btn, TFT_WIDTH - 30, 40 * scale);
  btnLabel = lv_label_create(btn);
  lv_obj_set_style_text_font(btnLabel, fontLarge, 0);
  lv_label_set_text_static(btnLabel, "Back");
  lv_obj_center(btnLabel);
  lv_obj_add_event_cb(btn, back, LV_EVENT_CLICKED, NULL);
}
