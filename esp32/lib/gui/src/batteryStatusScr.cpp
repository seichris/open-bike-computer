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
  uint32_t normalColor = DEVICE_COLOR;
  int16_t displayedPercentage = -2;
};

BatteryGauge deviceGauge;
BatteryGauge phoneGauge;

constexpr lv_point_precise_t BIKE_REAR_FRAME[] = {
    {18, 39}, {36, 18}, {44, 39}, {18, 39}};
constexpr lv_point_precise_t BIKE_FRONT_FRAME[] = {
    {36, 18}, {59, 18}, {70, 39}, {44, 39}, {36, 18}};
constexpr lv_point_precise_t BIKE_FORK_AND_HANDLEBAR[] = {
    {70, 39}, {61, 12}, {70, 12}};
constexpr lv_point_precise_t BIKE_SEAT[] = {{30, 14}, {40, 14}};

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

void createBikeLine(lv_obj_t *parent, const lv_point_precise_t *points,
                    uint32_t pointCount, uint32_t color) {
  lv_obj_t *line = lv_line_create(parent);
  lv_obj_remove_style_all(line);
  lv_line_set_points(line, points, pointCount);
  lv_obj_set_style_line_width(line, 3, 0);
  lv_obj_set_style_line_color(line, lv_color_hex(color), 0);
  lv_obj_set_style_line_rounded(line, true, 0);
  makePassive(line);
}

void createBikeWheel(lv_obj_t *parent, lv_coord_t x) {
  lv_obj_t *wheel = lv_obj_create(parent);
  lv_obj_remove_style_all(wheel);
  lv_obj_set_size(wheel, 28, 28);
  lv_obj_set_pos(wheel, x, 25);
  lv_obj_set_style_bg_opa(wheel, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(wheel, 3, 0);
  lv_obj_set_style_border_color(wheel, lv_color_white(), 0);
  lv_obj_set_style_radius(wheel, LV_RADIUS_CIRCLE, 0);
  makePassive(wheel);
}

void createBikeIcon(lv_obj_t *parent, lv_coord_t topOffset) {
  lv_obj_t *bike = lv_obj_create(parent);
  lv_obj_remove_style_all(bike);
  lv_obj_set_size(bike, 88, 56);
  lv_obj_align(bike, LV_ALIGN_TOP_MID, 0, topOffset);
  makePassive(bike);

  createBikeWheel(bike, 4);
  createBikeWheel(bike, 56);
  createBikeLine(bike, BIKE_REAR_FRAME,
                 sizeof(BIKE_REAR_FRAME) / sizeof(BIKE_REAR_FRAME[0]),
                 DEVICE_COLOR);
  createBikeLine(bike, BIKE_FRONT_FRAME,
                 sizeof(BIKE_FRONT_FRAME) / sizeof(BIKE_FRONT_FRAME[0]),
                 DEVICE_COLOR);
  createBikeLine(
      bike, BIKE_FORK_AND_HANDLEBAR,
      sizeof(BIKE_FORK_AND_HANDLEBAR) / sizeof(BIKE_FORK_AND_HANDLEBAR[0]),
      DEVICE_COLOR);
  createBikeLine(bike, BIKE_SEAT,
                 sizeof(BIKE_SEAT) / sizeof(BIKE_SEAT[0]), 0xFFFFFF);
}

void createPhoneIcon(lv_obj_t *parent, lv_coord_t topOffset) {
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

  const lv_coord_t iconTop = diameter >= 180 ? 35 : 25;
  if (phoneIcon) {
    createPhoneIcon(container, iconTop);
  } else {
    createBikeIcon(container, iconTop + 2);
  }

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

void updateGauge(BatteryGauge &gauge, int16_t percentage) {
  if (gauge.displayedPercentage == percentage || !gauge.arc || !gauge.value) {
    return;
  }

  gauge.displayedPercentage = percentage;
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
  updateGauge(deviceGauge,
              battery.readBatteryPercent(devicePercentage)
                  ? static_cast<int16_t>(devicePercentage)
                  : -1);
  updateGauge(phoneGauge, getPhoneBatteryLevelPercent());
}
