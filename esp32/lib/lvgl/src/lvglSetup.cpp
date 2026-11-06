/**
 * @file lvglSetup.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL Screen implementation
 * @version 0.2.2
 * @date 2025-05
 */

#include "lvglSetup.hpp"
#include "../../power/power.hpp"
#include "../../gui/src/mainScreenEntryPolicy.hpp"

#include <esp_timer.h>

lv_display_t *display;

lv_obj_t *searchSatScreen; // Search Satellite Screen
lv_style_t styleThemeBkg;  // New Main Background Style
lv_style_t styleObjectBkg; // New Objects Background Color
lv_style_t styleObjectSel; // New Objects Selected Color

lv_group_t *keyGroup; // GPIO group
lv_obj_t *powerMsg;   // Power Message

#include "../../settings/settings.hpp"

Power power;

// External UI objects needed for direct map loading
extern Maps mapView;
extern lv_obj_t *buttonBar;
extern lv_obj_t *menuBtn;
extern lv_obj_t *notifyBarHour;
extern lv_obj_t *notifyBarIcons;
extern bool isBarOpen;
extern uint8_t activeTile;
extern bool isReady;
extern MapSettings mapSet;
extern uint8_t zoom;
extern Gps gps;




/**
 * @brief Apply Custom Dark theme
 *
 * @param th
 * @param obj
 */
void applyModifyTheme(lv_theme_t *th, lv_obj_t *obj) {
  LV_UNUSED(th);
  if (!lv_obj_check_type(obj, &lv_led_class)) {
    if (!lv_obj_check_type(obj, &lv_button_class))
      lv_obj_add_style(obj, &styleThemeBkg, 0);
    if (lv_obj_check_type(obj, &lv_button_class))
      lv_obj_add_style(obj, &styleObjectBkg, 0);
    if (lv_obj_check_type(obj, &lv_switch_class)) {
      lv_obj_add_style(obj, &styleObjectBkg, 0);
      lv_obj_add_style(obj, &styleObjectBkg,
                       LV_PART_INDICATOR | LV_STATE_CHECKED);
    }
    if (lv_obj_check_type(obj, &lv_checkbox_class)) {
      lv_obj_add_style(obj, &styleThemeBkg,
                       LV_PART_INDICATOR | LV_STATE_DEFAULT);
      lv_obj_add_style(obj, &styleObjectBkg,
                       LV_PART_INDICATOR | LV_STATE_CHECKED);
    }
  }
}

/**
 * @brief Custom Dark theme
 *
 */
void modifyTheme() {
  /*Initialize the styles*/
  lv_style_init(&styleThemeBkg);
  lv_style_set_bg_color(&styleThemeBkg, lv_color_black());
  lv_style_set_border_color(&styleThemeBkg, lv_color_hex(objectColor));
  lv_style_init(&styleObjectBkg);
  lv_style_set_bg_color(&styleObjectBkg, lv_color_hex(objectColor));
  lv_style_set_border_color(&styleObjectBkg, lv_color_hex(objectColor));
  lv_style_init(&styleObjectSel);
  lv_style_set_bg_color(&styleObjectSel, lv_color_hex(0x757575));

  /*Initialize the new theme from the current theme*/
  lv_theme_t *th_act = lv_disp_get_theme(NULL);
  static lv_theme_t th_new;
  th_new = *th_act;

  /*Set the parent theme and the style apply callback for the new theme*/
  lv_theme_set_parent(&th_new, th_act);
  lv_theme_set_apply_cb(&th_new, applyModifyTheme);

  /*Assign the new theme to the current display*/
  lv_disp_set_theme(NULL, &th_new);
}

static uint32_t lvMonotonicTickMs() {
  return static_cast<uint32_t>(esp_timer_get_time() / 1000);
}

/**
 * @brief Init LVGL
 *
 */
void initLVGL() {
  // Use Arduino_GFX setup for CO5300 AMOLED
  setupLVGLforArduinoGFX();
  log_i("LVGL setup done via Arduino_GFX");

  // LVGL reads the monotonic ESP timer on demand. This removes the 5 ms
  // periodic esp_timer wakeup previously used only to call lv_tick_inc().
  lv_tick_set_cb(lvMonotonicTickMs);

  //  Create Main Timer
  mainTimer = lv_timer_create(updateMainScreen, UPDATE_MAINSCR_PERIOD, NULL);
  lv_timer_ready(mainTimer);

  modifyTheme();

  //  Create Screens
  log_i("Creating Screens...");
  createWaitingScr();
  createSearchSatScr();
  createMainScr();
  createNotifyBar();
  createSettingsScr();
  createMapSettingsScr();
  createDeviceSettingsScr();
  createButtonBarScr();
  createGpxDetailScreen();
  createGpxListScreen();

}

/**
 * @brief Load GPS Main Screen - SIMPLIFIED: Map Only
 *
 */
void loadMainScreen() {
  isMainScreen = true;
  isScrolled = true;
  isSearchingSat = false;
  gpxAction = WPT_NONE;
  lv_screen_load(mainScreen);

  isReady = true;
  mapView.redrawMap = true;
  lv_timer_resume(mainTimer); // MISTAKE FIXED: Timer was paused in
                              // createSearchSatScr and never resumed!
  mapView.createMapScrSprites();

  // The configured screen owns profile, zoom, projection, and the one initial
  // render. This avoids flashing a hard-coded flat Map frame before the saved
  // Map + Navigation bird's-eye screen is applied.
  mapSet.vectorMap = true;
  main_screen_entry_policy::enter(
      [&]() {
        mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
      },
      []() { showConfiguredDefaultMainScreen(); });
}
