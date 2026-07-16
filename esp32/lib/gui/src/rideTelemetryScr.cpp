/**
 * @file rideTelemetryScr.cpp
 * @brief LVGL ride telemetry screen
 */

#include "rideTelemetryScr.hpp"
#include "gps.hpp"
#include <cstdio>

extern Gps gps;
LV_FONT_DECLARE(ride_value_font_56);

lv_obj_t *rideSpeedValue;
lv_obj_t *rideAltitudeValue;
lv_obj_t *rideDistanceValue;
lv_obj_t *rideElapsedValue;
lv_obj_t *rideRouteRemainingValue;

namespace {
constexpr lv_coord_t kFirstRowY = 46;
constexpr lv_coord_t kRowSpacing = 120;
constexpr lv_coord_t kSpeedUnitOffsetY = 64;
constexpr lv_coord_t kMetricValueOffsetY = 38;
} // namespace

static lv_obj_t *createMetricLabel(lv_obj_t *screen, const char *title,
                                   lv_coord_t x, lv_coord_t y,
                                   lv_coord_t width) {
  lv_obj_t *titleLabel = lv_label_create(screen);
  lv_obj_set_style_text_font(titleLabel, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_color(titleLabel, lv_color_hex(0xAAAAAA), 0);
  lv_obj_set_style_text_align(titleLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(titleLabel, title);
  lv_obj_set_width(titleLabel, width);
  lv_obj_set_pos(titleLabel, x, y);

  lv_obj_t *valueLabel = lv_label_create(screen);
  lv_obj_set_style_text_font(valueLabel, &ride_value_font_56, 0);
  lv_obj_set_style_text_color(valueLabel, lv_color_white(), 0);
  lv_obj_set_style_text_align(valueLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(valueLabel, "--");
  lv_obj_set_width(valueLabel, width);
  lv_obj_set_pos(valueLabel, x, y + kMetricValueOffsetY);
  return valueLabel;
}

static void formatElapsed(uint32_t elapsedSeconds, char *buffer,
                          size_t bufferSize) {
  const uint32_t hours = elapsedSeconds / 3600;
  const uint32_t minutes = (elapsedSeconds / 60) % 60;
  const uint32_t seconds = elapsedSeconds % 60;

  if (hours > 0) {
    snprintf(buffer, bufferSize, "%lu:%02lu:%02lu", (unsigned long)hours,
             (unsigned long)minutes, (unsigned long)seconds);
  } else {
    snprintf(buffer, bufferSize, "%02lu:%02lu", (unsigned long)minutes,
             (unsigned long)seconds);
  }
}

static void setDistanceLabel(lv_obj_t *label, uint32_t meters) {
  if (meters >= 10000) {
    lv_label_set_text_fmt(label, "%lu km", (unsigned long)(meters / 1000));
  } else if (meters >= 1000) {
    // LVGL's built-in formatter has float support disabled in lv_conf.h.
    // Format tenths using integers so 1-9.9 km does not render as a literal
    // "f" from the unsupported %.1f conversion.
    const uint32_t roundedDeciKilometers = (meters + 50U) / 100U;
    lv_label_set_text_fmt(label, "%lu.%lu km",
                          (unsigned long)(roundedDeciKilometers / 10U),
                          (unsigned long)(roundedDeciKilometers % 10U));
  } else {
    lv_label_set_text_fmt(label, "%lu m", (unsigned long)meters);
  }
}

void rideTelemetryScr(_lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  rideSpeedValue = lv_label_create(screen);
  lv_obj_set_style_text_font(rideSpeedValue, &ride_value_font_56, 0);
  lv_obj_set_style_text_color(rideSpeedValue, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideSpeedValue, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(rideSpeedValue, "0");
  lv_obj_set_width(rideSpeedValue, TFT_WIDTH);
  lv_obj_align(rideSpeedValue, LV_ALIGN_TOP_MID, 0, kFirstRowY);

  lv_obj_t *speedUnit = lv_label_create(screen);
  lv_obj_set_style_text_font(speedUnit, &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_color(speedUnit, lv_color_hex(0xAAAAAA), 0);
  lv_label_set_text_static(speedUnit, "km/h");
  lv_obj_align(speedUnit, LV_ALIGN_TOP_MID, 0,
               kFirstRowY + kSpeedUnitOffsetY);

  const lv_coord_t colWidth = TFT_WIDTH / 2 - 18;
  const lv_coord_t leftX = 8;
  const lv_coord_t rightX = TFT_WIDTH / 2 + 10;
  rideAltitudeValue =
      createMetricLabel(screen, "Altitude", leftX,
                        kFirstRowY + kRowSpacing, colWidth);
  rideDistanceValue =
      createMetricLabel(screen, "Distance", rightX,
                        kFirstRowY + kRowSpacing, colWidth);
  rideElapsedValue =
      createMetricLabel(screen, "Elapsed", leftX,
                        kFirstRowY + (2 * kRowSpacing), colWidth);
  rideRouteRemainingValue = createMetricLabel(
      screen, "Route left", rightX, kFirstRowY + (2 * kRowSpacing), colWidth);
}

void updateRideTelemetryEvent(lv_event_t *event) {
  if (rideSpeedValue) {
    lv_label_set_text_fmt(rideSpeedValue, "%u", gps.gpsData.speed);
  }

  if (rideAltitudeValue) {
    lv_label_set_text_fmt(rideAltitudeValue, "%d m", gps.gpsData.altitude);
  }

  if (rideDistanceValue) {
    setDistanceLabel(rideDistanceValue, gps.gpsData.distanceTraveled);
  }

  if (rideElapsedValue) {
    char elapsed[16];
    formatElapsed(gps.gpsData.elapsedSeconds, elapsed, sizeof(elapsed));
    lv_label_set_text(rideElapsedValue, elapsed);
  }

  if (rideRouteRemainingValue) {
    if (gps.gpsData.hasRouteRemaining) {
      setDistanceLabel(rideRouteRemainingValue, gps.gpsData.routeRemaining);
    } else {
      lv_label_set_text_static(rideRouteRemainingValue, "--");
    }
  }
}
