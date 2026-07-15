/**
 * @file batteryStatusScr.cpp
 * @brief Device and connected-phone battery status screen.
 */

#include "batteryStatusScr.hpp"

#include "battery.hpp"
#include "ble_navigation.hpp"
#include <algorithm>

namespace {

constexpr uint32_t TRACK_COLOR = 0x20242C;
constexpr uint32_t DEVICE_COLOR = 0x35D46F;
constexpr uint32_t PHONE_COLOR = 0x72A7FF;
constexpr uint32_t WARNING_COLOR = 0xF6B73C;
constexpr uint32_t CRITICAL_COLOR = 0xF05A67;
constexpr uint32_t UNKNOWN_COLOR = 0x6B7280;

struct BatteryGauge {
  lv_obj_t *arc = nullptr;
  lv_obj_t *value = nullptr;
  lv_obj_t *chargingBolt = nullptr;
  uint32_t normalColor = DEVICE_COLOR;
  int16_t displayedPercentage = -2;
  int8_t displayedCharging = -1;
};

BatteryGauge deviceGauge;
BatteryGauge phoneGauge;

// Lucide Bike's 24x24 geometry, scaled 3x. Source:
// https://lucide.dev/icons/bike
constexpr lv_point_precise_t LUCIDE_BIKE_PATH[] = {
    {36, 53}, {36, 42}, {27, 33}, {39, 24}, {45, 33}, {51, 33}};
constexpr lv_point_precise_t CHARGING_BOLT_PATH[] = {
    {14, 5}, {6, 16}, {13, 16}, {7, 31}};

lv_color_t gaugeColor(const BatteryGauge &gauge, int16_t percentage) {
  if (percentage < 0) {
    return lv_color_hex(UNKNOWN_COLOR);
  }
  if (percentage <= 15) {
    return lv_color_hex(CRITICAL_COLOR);
  }
  if (percentage <= 30) {
    return lv_color_hex(WARNING_COLOR);
  }
  return lv_color_hex(gauge.normalColor);
}

void makePassive(lv_obj_t *obj) {
  lv_obj_clear_flag(obj, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(obj, LV_OBJ_FLAG_SCROLLABLE);
}

lv_obj_t *createIconOutline(lv_obj_t *parent, lv_coord_t width,
                            lv_coord_t height, lv_coord_t radius,
                            lv_coord_t topOffset) {
  lv_obj_t *icon = lv_obj_create(parent);
  lv_obj_remove_style_all(icon);
  lv_obj_set_size(icon, width, height);
  lv_obj_align(icon, LV_ALIGN_TOP_MID, 0, topOffset);
  lv_obj_set_style_bg_opa(icon, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(icon, 4, 0);
  lv_obj_set_style_border_color(icon, lv_color_white(), 0);
  lv_obj_set_style_radius(icon, radius, 0);
  makePassive(icon);
  return icon;
}

void createIconLine(lv_obj_t *parent, const lv_point_precise_t *points,
                    uint32_t pointCount, lv_coord_t width, uint32_t color) {
  lv_obj_t *line = lv_line_create(parent);
  lv_obj_remove_style_all(line);
  lv_line_set_points(line, points, pointCount);
  lv_obj_set_style_line_width(line, width, 0);
  lv_obj_set_style_line_color(line, lv_color_hex(color), 0);
  lv_obj_set_style_line_rounded(line, true, 0);
  makePassive(line);
}

void createBikeWheel(lv_obj_t *parent, lv_coord_t x) {
  lv_obj_t *wheel = lv_obj_create(parent);
  lv_obj_remove_style_all(wheel);
  lv_obj_set_size(wheel, 27, 27);
  lv_obj_set_pos(wheel, x, 39);
  lv_obj_set_style_bg_opa(wheel, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(wheel, 6, 0);
  lv_obj_set_style_border_color(wheel, lv_color_white(), 0);
  lv_obj_set_style_radius(wheel, LV_RADIUS_CIRCLE, 0);
  makePassive(wheel);
}

lv_obj_t *createBikeIcon(lv_obj_t *parent, lv_coord_t topOffset) {
  lv_obj_t *bike = lv_obj_create(parent);
  lv_obj_remove_style_all(bike);
  lv_obj_set_size(bike, 72, 72);
  lv_obj_align(bike, LV_ALIGN_TOP_MID, 0, topOffset);
  makePassive(bike);

  // Lucide circles: rear wheel (5.5,17.5,r3.5), front wheel
  // (18.5,17.5,r3.5), and rider head (15,5,r1).
  createBikeWheel(bike, 3);
  createBikeWheel(bike, 42);
  lv_obj_t *head = lv_obj_create(bike);
  lv_obj_remove_style_all(head);
  lv_obj_set_size(head, 12, 12);
  lv_obj_set_pos(head, 39, 9);
  lv_obj_set_style_bg_color(head, lv_color_white(), 0);
  lv_obj_set_style_bg_opa(head, LV_OPA_COVER, 0);
  lv_obj_set_style_radius(head, LV_RADIUS_CIRCLE, 0);
  makePassive(head);
  createIconLine(bike, LUCIDE_BIKE_PATH,
                 sizeof(LUCIDE_BIKE_PATH) / sizeof(LUCIDE_BIKE_PATH[0]), 6,
                 0xFFFFFF);
  return bike;
}

lv_obj_t *createPhoneIcon(lv_obj_t *parent, lv_coord_t topOffset) {
  lv_obj_t *phone = createIconOutline(parent, 42, 60, 9, topOffset);

  lv_obj_t *speaker = lv_obj_create(phone);
  lv_obj_remove_style_all(speaker);
  lv_obj_set_size(speaker, 13, 3);
  lv_obj_align(speaker, LV_ALIGN_TOP_MID, 0, 6);
  lv_obj_set_style_bg_color(speaker, lv_color_white(), 0);
  lv_obj_set_style_bg_opa(speaker, LV_OPA_COVER, 0);
  lv_obj_set_style_radius(speaker, LV_RADIUS_CIRCLE, 0);
  makePassive(speaker);

  lv_obj_t *home = lv_obj_create(phone);
  lv_obj_remove_style_all(home);
  lv_obj_set_size(home, 6, 6);
  lv_obj_align(home, LV_ALIGN_BOTTOM_MID, 0, -5);
  lv_obj_set_style_bg_color(home, lv_color_hex(PHONE_COLOR), 0);
  lv_obj_set_style_bg_opa(home, LV_OPA_COVER, 0);
  lv_obj_set_style_radius(home, LV_RADIUS_CIRCLE, 0);
  makePassive(home);
  return phone;
}

lv_obj_t *createChargingBolt(lv_obj_t *parent, lv_coord_t yOffset) {
  lv_obj_t *overlay = lv_obj_create(parent);
  lv_obj_remove_style_all(overlay);
  lv_obj_set_size(overlay, 22, 36);
  lv_obj_align(overlay, LV_ALIGN_CENTER, 0, yOffset);
  makePassive(overlay);

  // A black under-stroke keeps the green bolt distinct over either icon.
  createIconLine(overlay, CHARGING_BOLT_PATH,
                 sizeof(CHARGING_BOLT_PATH) /
                     sizeof(CHARGING_BOLT_PATH[0]),
                 8, 0x000000);
  createIconLine(overlay, CHARGING_BOLT_PATH,
                 sizeof(CHARGING_BOLT_PATH) /
                     sizeof(CHARGING_BOLT_PATH[0]),
                 5, DEVICE_COLOR);
  lv_obj_add_flag(overlay, LV_OBJ_FLAG_HIDDEN);
  return overlay;
}

BatteryGauge createGauge(lv_obj_t *parent, lv_coord_t diameter, lv_coord_t y,
                         uint32_t normalColor, bool phoneIcon) {
  BatteryGauge gauge;
  gauge.normalColor = normalColor;

  lv_obj_t *container = lv_obj_create(parent);
  lv_obj_remove_style_all(container);
  lv_obj_set_size(container, diameter, diameter);
  lv_obj_align(container, LV_ALIGN_TOP_MID, 0, y);
  makePassive(container);

  gauge.arc = lv_arc_create(container);
  lv_obj_set_size(gauge.arc, diameter, diameter);
  lv_obj_center(gauge.arc);
  lv_arc_set_rotation(gauge.arc, 135);
  lv_arc_set_bg_angles(gauge.arc, 0, 270);
  lv_arc_set_range(gauge.arc, 0, 100);
  lv_arc_set_value(gauge.arc, 0);
  lv_obj_remove_style(gauge.arc, nullptr, LV_PART_KNOB);
  lv_obj_set_style_arc_width(gauge.arc, diameter >= 180 ? 13 : 11,
                             LV_PART_MAIN);
  lv_obj_set_style_arc_width(gauge.arc, diameter >= 180 ? 13 : 11,
                             LV_PART_INDICATOR);
  lv_obj_set_style_arc_color(gauge.arc, lv_color_hex(TRACK_COLOR),
                             LV_PART_MAIN);
  lv_obj_set_style_arc_color(gauge.arc, lv_color_hex(UNKNOWN_COLOR),
                             LV_PART_INDICATOR);
  lv_obj_set_style_arc_rounded(gauge.arc, true, LV_PART_MAIN);
  lv_obj_set_style_arc_rounded(gauge.arc, true, LV_PART_INDICATOR);
  makePassive(gauge.arc);

  // Keep both icon centers on the same visual axis, a little above the ring's
  // midpoint to leave room for the percentage below.
  const lv_coord_t iconCenterY = (diameter * 40) / 100;
  lv_obj_t *icon = nullptr;
  if (phoneIcon) {
    icon = createPhoneIcon(container, iconCenterY - 30);
  } else {
    icon = createBikeIcon(container, iconCenterY - 36);
  }
  gauge.chargingBolt = createChargingBolt(icon, phoneIcon ? 0 : 3);

  gauge.value = lv_label_create(container);
  lv_label_set_text_static(gauge.value, "--%");
  lv_obj_set_style_text_font(gauge.value, &lv_font_montserrat_38, 0);
  lv_obj_set_style_text_color(gauge.value, lv_color_white(), 0);
  lv_obj_set_style_text_align(gauge.value, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(gauge.value, diameter - 36);
  lv_obj_align(gauge.value, LV_ALIGN_BOTTOM_MID, 0,
               diameter >= 180 ? -15 : -8);

  return gauge;
}

void updateGauge(BatteryGauge &gauge, int16_t percentage, bool charging) {
  const bool showCharging = charging && percentage >= 0;
  if ((gauge.displayedPercentage == percentage &&
       gauge.displayedCharging == static_cast<int8_t>(showCharging)) ||
      !gauge.arc || !gauge.value) {
    return;
  }

  gauge.displayedPercentage = percentage;
  gauge.displayedCharging = static_cast<int8_t>(showCharging);
  if (gauge.chargingBolt) {
    if (showCharging) {
      lv_obj_clear_flag(gauge.chargingBolt, LV_OBJ_FLAG_HIDDEN);
    } else {
      lv_obj_add_flag(gauge.chargingBolt, LV_OBJ_FLAG_HIDDEN);
    }
  }
  const lv_color_t color = gaugeColor(gauge, percentage);
  lv_obj_set_style_arc_color(gauge.arc, color, LV_PART_INDICATOR);

  if (percentage < 0) {
    lv_arc_set_value(gauge.arc, 0);
    lv_label_set_text_static(gauge.value, "--%");
    lv_obj_set_style_text_color(gauge.value, lv_color_hex(UNKNOWN_COLOR), 0);
    return;
  }

  lv_arc_set_value(gauge.arc, percentage);
  lv_label_set_text_fmt(gauge.value, "%d%%", percentage);
  lv_obj_set_style_text_color(gauge.value, lv_color_white(), 0);
}

} // namespace

extern Battery battery;

void batteryStatusScr(lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  const uint16_t shortestSide = std::min(TFT_WIDTH, TFT_HEIGHT);
  const bool squareDisplay =
      TFT_WIDTH > TFT_HEIGHT ? TFT_WIDTH - TFT_HEIGHT < 24
                             : TFT_HEIGHT - TFT_WIDTH < 24;
  lv_coord_t diameter = squareDisplay ? (shortestSide * 36) / 100
                                      : (shortestSide * 46) / 100;
  const bool hasLargeDeviceChrome = TFT_HEIGHT >= 400;
  const lv_coord_t topInset = hasLargeDeviceChrome ? 32 : 6;
  const lv_coord_t bottomInset = hasLargeDeviceChrome ? 66 : 6;
  const lv_coord_t minimumGap = hasLargeDeviceChrome ? 16 : 6;
  diameter = std::min<lv_coord_t>(
      diameter,
      (TFT_HEIGHT - topInset - bottomInset - minimumGap) / 2);
  const lv_coord_t gap =
      TFT_HEIGHT - topInset - bottomInset - (diameter * 2);

  deviceGauge = createGauge(screen, diameter, topInset, DEVICE_COLOR, false);
  phoneGauge = createGauge(screen, diameter, topInset + diameter + gap,
                           PHONE_COLOR, true);
}

void updateBatteryStatusEvent(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_VALUE_CHANGED) {
    return;
  }

  uint8_t devicePercentage = 0;
  bool deviceCharging = false;
  const bool deviceStatusAvailable =
      battery.readBatteryStatus(devicePercentage, deviceCharging);
  updateGauge(deviceGauge,
              deviceStatusAvailable ? static_cast<int16_t>(devicePercentage)
                                    : -1,
              deviceStatusAvailable && deviceCharging);
  updateGauge(phoneGauge, getPhoneBatteryLevelPercent(),
              isPhoneBatteryCharging());
}
