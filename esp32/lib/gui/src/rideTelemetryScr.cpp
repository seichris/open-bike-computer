/**
 * @file rideTelemetryScr.cpp
 * @brief Adaptive Watch workout and legacy GPS ride telemetry screen.
 */

#include "rideTelemetryScr.hpp"
#include "../../ble_navigation/workout_telemetry_runtime.hpp"
#include "gps.hpp"
#include "rideMetricFontSelection.hpp"
#include "rideTelemetryLayout.hpp"
#include "rideTelemetryPresenter.hpp"

#include <array>
#include <cstdio>
#include <cstring>

extern Gps gps;
LV_FONT_DECLARE(ride_value_font_56);
LV_FONT_DECLARE(ride_value_font_64);
LV_FONT_DECLARE(ride_speed_font_84);

namespace {

struct MetricLabels {
  lv_obj_t *title = nullptr;
  lv_obj_t *value = nullptr;
};

lv_obj_t *ridePage = nullptr;
lv_obj_t *rideStatus = nullptr;
lv_obj_t *rideSpeedValue = nullptr;
lv_obj_t *rideHeartRateValue = nullptr;
lv_obj_t *rideZoneValue = nullptr;
lv_obj_t *rideDistanceValue = nullptr;
lv_obj_t *rideElapsedValue = nullptr;
MetricLabels rideBottomLeft{};
MetricLabels rideBottomRight{};
ride_telemetry_layout::Layout rideLayout{};

bool fontSupportsText(const lv_font_t *font, const char *text) {
  for (std::size_t index = 0; text[index] != '\0'; ++index) {
    // Ride telemetry formatters emit only ASCII digits, punctuation and units.
    const uint32_t letter = static_cast<uint8_t>(text[index]);
    const uint32_t nextLetter = static_cast<uint8_t>(text[index + 1]);
    lv_font_glyph_dsc_t glyph{};
    if (!lv_font_get_glyph_dsc(font, &glyph, letter, nextLetter) ||
        glyph.is_placeholder) {
      return false;
    }
  }
  return true;
}

template <std::size_t N>
const lv_font_t *firstFittingFont(
    const std::array<const lv_font_t *, N> &fonts, const char *text,
    uint32_t textLength, int32_t availableWidth) {
  std::array<ride_metric_font_selection::Candidate, N> candidates{};
  for (std::size_t index = 0; index < N; ++index) {
    candidates[index] = {
        lv_text_get_width(text, textLength, fonts[index], 0),
        fontSupportsText(fonts[index], text),
    };
  }
  const std::size_t selected =
      ride_metric_font_selection::firstFittingIndex(candidates,
                                                    availableWidth);
  return selected < N ? fonts[selected] : fonts[N - 1];
}

const lv_font_t *metricValueFont(lv_obj_t *label, const char *text) {
  const int32_t availableWidth = lv_obj_get_width(label) - 4;
  const uint32_t textLength = static_cast<uint32_t>(std::strlen(text));

  if (ride_telemetry_layout::useLargeMetricValueFont(
          rideLayout.screenWidth)) {
    constexpr std::size_t fontCount = 7;
    const std::array<const lv_font_t *, fontCount> fonts = {
        &ride_value_font_64,     &ride_value_font_56,
        &lv_font_montserrat_48,  &lv_font_montserrat_42,
        &lv_font_montserrat_38,  &lv_font_montserrat_24,
        &lv_font_montserrat_18,
    };
    return firstFittingFont(fonts, text, textLength, availableWidth);
  }

  constexpr std::size_t fontCount = 4;
  const std::array<const lv_font_t *, fontCount> fonts = {
      &lv_font_montserrat_42,
      &lv_font_montserrat_38,
      &lv_font_montserrat_24,
      &lv_font_montserrat_18,
  };
  return firstFittingFont(fonts, text, textLength, availableWidth);
}

void setLabelIfChanged(lv_obj_t *label, const char *text) {
  if (label == nullptr || text == nullptr) {
    return;
  }
  const char *current = lv_label_get_text(label);
  if (current == nullptr || std::strcmp(current, text) != 0) {
    lv_label_set_text(label, text);
  }
}

void setMetricValueIfChanged(lv_obj_t *label, const char *text) {
  if (label == nullptr || text == nullptr) {
    return;
  }
  const lv_font_t *font = metricValueFont(label, text);
  if (lv_obj_get_style_text_font(label, LV_PART_MAIN) != font) {
    lv_obj_set_style_text_font(label, font, 0);
  }
  setLabelIfChanged(label, text);
}

lv_obj_t *createPage(lv_obj_t *screen) {
  lv_obj_t *page = lv_obj_create(screen);
  lv_obj_remove_style_all(page);
  lv_obj_set_size(page, rideLayout.page.width, rideLayout.page.height);
  lv_obj_set_pos(page, rideLayout.page.x, rideLayout.page.y);
  lv_obj_clear_flag(
      page, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                       LV_OBJ_FLAG_CLICKABLE));
  return page;
}

lv_obj_t *createHeader(lv_obj_t *page) {
  lv_obj_t *status = lv_label_create(page);
  lv_obj_set_width(status, rideLayout.status.width);
  lv_obj_set_pos(status, rideLayout.status.x, rideLayout.status.y);
  lv_obj_set_style_text_font(status, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(status, lv_color_hex(0x66DD88), 0);
  lv_obj_set_style_text_align(status, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_add_flag(status, LV_OBJ_FLAG_HIDDEN);
  lv_label_set_text_static(status, "LEGACY RIDE");
  return status;
}

MetricLabels createMetric(lv_obj_t *page, const char *title,
                          const ride_telemetry_layout::Rect &rect) {
  MetricLabels labels{};
  labels.title = lv_label_create(page);
  lv_obj_set_width(labels.title, rect.width);
  lv_obj_set_pos(labels.title, rect.x, rect.y);
  lv_obj_set_style_text_font(labels.title, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(labels.title, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(labels.title, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(labels.title, title);

  labels.value = lv_label_create(page);
  lv_obj_set_width(labels.value, rect.width);
  lv_obj_set_pos(labels.value, rect.x,
                 rect.y + ride_telemetry_layout::kMetricValueOffsetY);
  lv_obj_set_style_text_font(labels.value, &ride_value_font_64, 0);
  lv_obj_set_style_text_color(labels.value, lv_color_white(), 0);
  lv_obj_set_style_text_align(labels.value, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(labels.value, LV_LABEL_LONG_CLIP);
  setMetricValueIfChanged(labels.value, "--");
  return labels;
}

ride_telemetry_presenter::ViewModel currentViewModel() {
  const workout_telemetry::Snapshot workout =
      workout_telemetry_runtime::snapshot(millis());
  const ride_telemetry_presenter::LegacyRideTelemetry legacy{
      gps.gpsData.speed,
      gps.gpsData.altitude,
      gps.gpsData.distanceTraveled,
      gps.gpsData.elapsedSeconds,
      gps.gpsData.hasRouteRemaining,
      gps.gpsData.routeRemaining,
  };
  return ride_telemetry_presenter::makeViewModel(workout, legacy);
}

void updateStatusLabel(lv_obj_t *label,
                       const ride_telemetry_presenter::ViewModel &model) {
  const char *statusText = ride_telemetry_presenter::statusLabel(model);
  setLabelIfChanged(label, statusText);
  if (!ride_telemetry_presenter::shouldShowStatus(model)) {
    lv_obj_add_flag(label, LV_OBJ_FLAG_HIDDEN);
    return;
  }
  lv_obj_clear_flag(label, LV_OBJ_FLAG_HIDDEN);
  lv_color_t color = lv_color_hex(0x66DD88);
  if (model.stale || model.sessionState ==
                         workout_telemetry_protocol::SessionState::Failed) {
    color = lv_color_hex(0xFF6666);
  } else if (model.sessionState ==
                 workout_telemetry_protocol::SessionState::Paused ||
             model.sessionState ==
                 workout_telemetry_protocol::SessionState::Ending) {
    color = lv_color_hex(0xFFCC55);
  } else if (model.sessionState ==
             workout_telemetry_protocol::SessionState::Ended) {
    color = lv_color_hex(0x66CCFF);
  }
  lv_obj_set_style_text_color(label, color, 0);
}

void updateBottomMetric(
    MetricLabels labels, ride_telemetry_presenter::BottomMetric metric,
    const ride_telemetry_presenter::ViewModel &model) {
  setLabelIfChanged(labels.title,
                    ride_telemetry_presenter::bottomMetricTitle(metric));
  char value[24];
  ride_telemetry_presenter::formatBottomMetric(metric, model, value,
                                                sizeof(value));
  setMetricValueIfChanged(labels.value, value);
}

} // namespace

void rideTelemetryScr(_lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  rideLayout = ride_telemetry_layout::makeLayout(TFT_WIDTH, TFT_HEIGHT);

  ridePage = createPage(screen);
  rideStatus = createHeader(ridePage);

  rideSpeedValue = lv_label_create(ridePage);
  lv_obj_set_width(rideSpeedValue, rideLayout.hero.width);
  lv_obj_set_pos(rideSpeedValue, rideLayout.hero.x, rideLayout.hero.y);
  lv_obj_set_style_text_font(rideSpeedValue, &ride_speed_font_84, 0);
  lv_obj_set_style_text_color(rideSpeedValue, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideSpeedValue, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(rideSpeedValue, "0.0");

  lv_obj_t *speedUnit = lv_label_create(ridePage);
  lv_obj_set_width(speedUnit, rideLayout.heroUnit.width);
  lv_obj_set_pos(speedUnit, rideLayout.heroUnit.x, rideLayout.heroUnit.y);
  lv_obj_set_style_text_font(speedUnit, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(speedUnit, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(speedUnit, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text_static(speedUnit, "km/h");

  rideHeartRateValue =
      createMetric(ridePage, "Heart bpm", rideLayout.metrics[0]).value;
  rideZoneValue =
      createMetric(ridePage, "HR zone", rideLayout.metrics[1]).value;
  rideDistanceValue =
      createMetric(ridePage, "Distance", rideLayout.metrics[2]).value;
  rideElapsedValue =
      createMetric(ridePage, "Elapsed", rideLayout.metrics[3]).value;
  rideBottomLeft =
      createMetric(ridePage, "Altitude m", rideLayout.metrics[4]);
  rideBottomRight =
      createMetric(ridePage, "Route left", rideLayout.metrics[5]);

  updateRideTelemetryEvent(nullptr);
}

void updateRideTelemetryEvent(lv_event_t *) {
  const ride_telemetry_presenter::ViewModel model = currentViewModel();
  updateStatusLabel(rideStatus, model);

  char value[24];
  ride_telemetry_presenter::formatSpeed(model, value, sizeof(value));
  setLabelIfChanged(rideSpeedValue, value);
  ride_telemetry_presenter::formatInteger(model.currentHeartRateBpm, value,
                                          sizeof(value));
  setMetricValueIfChanged(rideHeartRateValue, value);
  ride_telemetry_presenter::formatZone(model, value, sizeof(value));
  setMetricValueIfChanged(rideZoneValue, value);
  ride_telemetry_presenter::formatDistance(model.distanceMeters, value,
                                           sizeof(value));
  setMetricValueIfChanged(rideDistanceValue, value);
  ride_telemetry_presenter::formatElapsed(model.elapsedSeconds, value,
                                          sizeof(value));
  setMetricValueIfChanged(rideElapsedValue, value);

  const ride_telemetry_presenter::BottomMetricSelection bottomMetrics =
      ride_telemetry_presenter::selectBottomMetrics(model);
  updateBottomMetric(rideBottomLeft, bottomMetrics.left, model);
  updateBottomMetric(rideBottomRight, bottomMetrics.right, model);
}
