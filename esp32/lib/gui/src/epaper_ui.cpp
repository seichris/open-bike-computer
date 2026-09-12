#if defined(WAVESHARE_EPAPER_397)
#include "epaper_ui.hpp"
#include "mainScr.hpp"
#include "waitingScr.hpp"
#include "epaper_display.hpp"
#include "ble_navigation.hpp"
#include "gps.hpp"
#include "route_overlay.hpp"
#include "../../images/src/bicino_app_qr.h"
#include <cstring>

extern Maps mapView;
extern Gps gps;

namespace epaper_ui {
namespace {
lv_obj_t *menu = nullptr, *menuText = nullptr, *statusLabel = nullptr;
lv_group_t *controls = nullptr;
bool inControls = false;
unsigned selected = 0;
constexpr const char *actions[] = {
    "Zoom in", "Zoom out", "Recenter map", "Screen controls", "Back"};

void style(lv_obj_t *object) {
  if (!object) return;
  const lv_color_t black = lv_color_black(), white = lv_color_white();
  // Preserve object geometry, transparency, map canvas and QR pixels. Check
  // current values first: styling a static tree must not invalidate each tick.
  if (!lv_color_eq(lv_obj_get_style_text_color(object, LV_PART_MAIN), black))
    lv_obj_set_style_text_color(object, black, LV_PART_MAIN);
  if (!lv_color_eq(lv_obj_get_style_bg_color(object, LV_PART_MAIN), white))
    lv_obj_set_style_bg_color(object, white, LV_PART_MAIN);
  if (!lv_color_eq(lv_obj_get_style_border_color(object, LV_PART_MAIN), black))
    lv_obj_set_style_border_color(object, black, LV_PART_MAIN);
  if (lv_obj_get_style_shadow_width(object, LV_PART_MAIN))
    lv_obj_set_style_shadow_width(object, 0, LV_PART_MAIN);
  if (lv_obj_get_style_anim_duration(object, LV_PART_MAIN))
    lv_obj_set_style_anim_duration(object, 0, LV_PART_MAIN);
  if (lv_obj_check_type(object, &lv_label_class) &&
      (lv_label_get_long_mode(object) == LV_LABEL_LONG_SCROLL ||
       lv_label_get_long_mode(object) == LV_LABEL_LONG_SCROLL_CIRCULAR))
    lv_label_set_long_mode(object, LV_LABEL_LONG_WRAP);
  if (lv_obj_check_type(object, &lv_image_class) &&
      !lv_obj_check_type(object, &lv_canvas_class) &&
      lv_image_get_src(object) != &bicino_app_qr) {
    if (!lv_color_eq(lv_obj_get_style_image_recolor(object, LV_PART_MAIN), black))
      lv_obj_set_style_image_recolor(object, black, LV_PART_MAIN);
    if (lv_obj_get_style_image_recolor_opa(object, LV_PART_MAIN) != LV_OPA_COVER)
      lv_obj_set_style_image_recolor_opa(object, LV_OPA_COVER, LV_PART_MAIN);
  }
  if (lv_obj_check_type(object, &lv_bar_class)) {
    if (!lv_color_eq(lv_obj_get_style_bg_color(object, LV_PART_INDICATOR), black))
      lv_obj_set_style_bg_color(object, black, LV_PART_INDICATOR);
  }
  for (uint32_t i = 0; i < lv_obj_get_child_count(object); ++i)
    style(lv_obj_get_child(object, i));
}

void collectControls(lv_obj_t *object) {
  if (!object || lv_obj_has_flag(object, LV_OBJ_FLAG_HIDDEN)) return;
  if (lv_obj_has_flag(object, LV_OBJ_FLAG_CLICKABLE) &&
      (lv_obj_check_type(object, &lv_button_class) ||
       (lv_obj_get_event_count(object) > 0 &&
        lv_obj_get_height(object) < 160 && lv_obj_get_width(object) < 470))) {
    lv_group_add_obj(controls, object);
    lv_obj_set_style_outline_color(object, lv_color_black(), LV_STATE_FOCUSED);
    lv_obj_set_style_outline_width(object, 3, LV_STATE_FOCUSED);
  }
  for (uint32_t i = 0; i < lv_obj_get_child_count(object); ++i)
    collectControls(lv_obj_get_child(object, i));
}

void renderMenu() {
  char text[200] = "Actions\n\n";
  for (unsigned i = 0; i < 5; ++i) {
    std::strcat(text, i == selected ? "> " : "   ");
    std::strcat(text, actions[i]);
    std::strcat(text, "\n");
  }
  lv_label_set_text(menuText, text);
  epaper::invalidateContext();
}
} // namespace

bool contextOpen() { return inControls || (menu && !lv_obj_has_flag(menu, LV_OBJ_FLAG_HIDDEN)); }
void closeContext() {
  if (menu) lv_obj_add_flag(menu, LV_OBJ_FLAG_HIDDEN);
  if (controls) lv_group_remove_all_objs(controls);
  inControls = false;
}
void previousScreen() {
  closeContext();
  if (isMainScreen) showPreviousMainScreen();
  epaper::prioritize();
}
void nextScreen() {
  closeContext();
  if (isMainScreen) showNextMainScreen();
  epaper::prioritize();
}
void context() {
  if (inControls) { closeContext(); return; }
  if (!menu) {
    menu = lv_obj_create(lv_layer_top());
    lv_obj_set_size(menu, 440, 360);
    lv_obj_center(menu);
    lv_obj_clear_flag(menu, LV_OBJ_FLAG_SCROLLABLE);
    menuText = lv_label_create(menu);
    lv_obj_set_style_text_font(menuText, &lv_font_montserrat_24, 0);
    lv_obj_set_width(menuText, 400);
    lv_obj_center(menuText);
  }
  selected = isMapScreenActive() ? 0 : 3;
  lv_obj_clear_flag(menu, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(menu);
  renderMenu();
}
void moveFocus(int delta) {
  if (inControls) {
    if (delta < 0) lv_group_focus_prev(controls);
    else lv_group_focus_next(controls);
    epaper::prioritize();
    return;
  }
  selected = (selected + 5 + delta) % 5;
  renderMenu();
}
void activate() {
  if (inControls) {
    lv_obj_t *focused = lv_group_get_focused(controls);
    if (focused) lv_obj_send_event(focused, LV_EVENT_CLICKED, nullptr);
    epaper::prioritize();
    return;
  }
  if (!contextOpen()) { context(); return; }
  if (selected == 3) {
    closeContext();
    if (!controls) controls = lv_group_create();
    collectControls(lv_screen_active());
    inControls = true;
  } else {
    const unsigned action = selected;
    closeContext();
    if (isMapScreenActive() || isMapGuidanceScreenActive()) {
      if (action == 0) zoomInEvent(nullptr);
      if (action == 1) zoomOutEvent(nullptr);
      if (action == 2) {
        mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
        requestMapRender(map_render_policy::Reason::Screen);
      }
    }
  }
  epaper::prioritize();
}

void prepareFrame() {
  // LV_EVENT_REFR_START runs before drawing, after ordinary UI timers. A
  // freshly updated label must already be black in its first submitted frame.
  style(lv_screen_active());
  style(lv_layer_top());
}

void process() {
  static uint32_t lastStyleMs = 0;
  static lv_obj_t *lastScreen = nullptr;
  static uint8_t lastTile = UINT8_MAX;
  static String lastInstruction;
  static uint32_t lastRoute = 0;
  const uint32_t now = millis();
  lv_obj_t *screen = lv_screen_active();
  if (!screen) return;
  if (screen != lastScreen || activeTile != lastTile) {
    lastScreen = screen; lastTile = activeTile;
    closeContext(); epaper::invalidateContext();
    lastStyleMs = 0;
  }
  const NavigationData nav = getCurrentNavigationData();
  const uint32_t route = routeOverlay.revision();
  if (nav.instruction != lastInstruction || route != lastRoute) {
    lastInstruction = nav.instruction;
    lastRoute = route;
    epaper::invalidateContext();
  }
  if (!statusLabel) {
    statusLabel = lv_label_create(lv_layer_top());
    lv_obj_set_width(statusLabel, 460);
    lv_obj_set_style_text_align(statusLabel, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(statusLabel, &lv_font_montserrat_18, 0);
    lv_obj_set_style_bg_opa(statusLabel, LV_OPA_COVER, 0);
    lv_obj_align(statusLabel, LV_ALIGN_BOTTOM_MID, 0, -6);
  }
  const BLEDebugStats ble = bleNavServer.getDebugStats();
  const epaper::Status panel = epaper::status();
  const bool stale = !ble.lastGpsPacketMs || now - ble.lastGpsPacketMs > 10000;
  const char *message = panel.fault ? "Display fault - reconnect power" :
      bleNavServer.hasOwnershipPairingCode() ? "Center: confirm   Hold up/down: cancel" :
      !ble.connected ? "Disconnected - image may be old" :
      !ble.authenticated ? "Waiting for phone registration" :
      inControls ? "Up/down: focus   Center: select   Hold: back" :
      stale ? "GPS stale - waiting for current position" :
      "Up/down: screen   Center: actions";
  if (std::strcmp(lv_label_get_text(statusLabel), message) != 0) {
    lv_label_set_text(statusLabel, message); epaper::prioritize();
  }
  if (!lastStyleMs || now - lastStyleMs >= 100) {
    style(screen); style(lv_layer_top()); lastStyleMs = now;
  }
}
} // namespace epaper_ui
#endif
