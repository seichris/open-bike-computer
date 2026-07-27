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
lv_obj_t *rideHeartRateHeart = nullptr;
lv_obj_t *rideDistanceValue = nullptr;
lv_obj_t *rideElapsedValue = nullptr;
std::array<lv_obj_t *, ride_telemetry_layout::kHeartRateZoneCount>
    rideZoneSegments{};
lv_obj_t *rideZoneHeart = nullptr;
lv_obj_t *rideZoneLabel = nullptr;
int8_t displayedZoneIndex = -2;
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

const lv_font_t *preferredMetricValueFont() {
  if (ride_telemetry_layout::useLargeMetricValueFont(
          rideLayout.screenWidth)) {
    return &ride_value_font_64;
  }
  return &lv_font_montserrat_42;
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

lv_obj_t *createMetricTitle(lv_obj_t *page, const char *title,
                            const ride_telemetry_layout::Rect &rect) {
  lv_obj_t *label = lv_label_create(page);
  lv_obj_set_width(label, rect.width);
  lv_obj_set_pos(label, rect.x, rect.y);
  lv_obj_set_style_text_font(label, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_text(label, title);
  return label;
}

MetricLabels createMetric(lv_obj_t *page, const char *title,
                          const ride_telemetry_layout::Rect &rect) {
  MetricLabels labels{};
  labels.title = createMetricTitle(page, title, rect);

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

lv_color_t zoneColor(std::size_t index, bool active) {
  // Matches HeartRateZonePalette in the iPhone app. Inactive values are the
  // same colors composited at 62% opacity over the black screen background.
  constexpr std::array<uint32_t,
                       ride_telemetry_layout::kHeartRateZoneCount>
      activeColors = {0x145C99, 0x0D7A70, 0xADF208, 0xE0730F, 0xB80852};
  constexpr std::array<uint32_t,
                       ride_telemetry_layout::kHeartRateZoneCount>
      inactiveColors = {0x0C395F, 0x084C45, 0x6B9605, 0x8B4709, 0x720533};
  return lv_color_hex(active ? activeColors[index] : inactiveColors[index]);
}

lv_color_t zoneForegroundColor(std::size_t index) {
  return index == 2 || index == 3 ? lv_color_black() : lv_color_white();
}

void drawHeartIcon(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_DRAW_POST_END) {
    return;
  }

  lv_obj_t *heart = static_cast<lv_obj_t *>(lv_event_get_target(event));
  lv_layer_t *layer = lv_event_get_layer(event);
  lv_area_t coordinates{};
  lv_obj_get_coords(heart, &coordinates);
  const int32_t width = lv_area_get_width(&coordinates);
  const int32_t height = lv_area_get_height(&coordinates);
  const int32_t lobeEnd = width / 2;
  const int32_t rightLobeStart = lobeEnd - 1;
  const int32_t triangleTop = height * 2 / 7;

  lv_draw_rect_dsc_t circle{};
  lv_draw_rect_dsc_init(&circle);
  circle.bg_color = lv_obj_get_style_text_color(heart, LV_PART_MAIN);
  circle.bg_opa = LV_OPA_COVER;
  circle.radius = LV_RADIUS_CIRCLE;

  lv_area_t leftCircle = {coordinates.x1, coordinates.y1,
                          coordinates.x1 + lobeEnd,
                          coordinates.y1 + lobeEnd};
  lv_area_t rightCircle = {coordinates.x1 + rightLobeStart, coordinates.y1,
                           coordinates.x2, coordinates.y1 + lobeEnd};
  lv_draw_rect(layer, &circle, &leftCircle);
  lv_draw_rect(layer, &circle, &rightCircle);

  lv_draw_triangle_dsc_t triangle{};
  lv_draw_triangle_dsc_init(&triangle);
  triangle.bg_color = circle.bg_color;
  triangle.bg_opa = LV_OPA_COVER;
  triangle.p[0] = {coordinates.x1, coordinates.y1 + triangleTop};
  triangle.p[1] = {coordinates.x2, coordinates.y1 + triangleTop};
  triangle.p[2] = {coordinates.x1 + width / 2, coordinates.y2};
  lv_draw_triangle(layer, &triangle);
}

lv_obj_t *createHeartIcon(lv_obj_t *page) {
  lv_obj_t *heart = lv_obj_create(page);
  lv_obj_remove_style_all(heart);
  lv_obj_add_event_cb(heart, drawHeartIcon, LV_EVENT_DRAW_POST_END, nullptr);
  lv_obj_clear_flag(
      heart, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                        LV_OBJ_FLAG_CLICKABLE));
  lv_obj_add_flag(heart, LV_OBJ_FLAG_HIDDEN);
  return heart;
}

void createZoneMetric(lv_obj_t *page,
                      const ride_telemetry_layout::Rect &rect) {
  displayedZoneIndex = -2;
  createMetricTitle(page, "HR zone", rect);

  for (lv_obj_t *&segment : rideZoneSegments) {
    segment = lv_obj_create(page);
    lv_obj_remove_style_all(segment);
    lv_obj_set_style_radius(segment, 10, 0);
    lv_obj_set_style_bg_opa(segment, LV_OPA_COVER, 0);
    lv_obj_clear_flag(
        segment, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                            LV_OBJ_FLAG_CLICKABLE));
    lv_obj_add_flag(segment, LV_OBJ_FLAG_HIDDEN);
  }

  rideZoneHeart = createHeartIcon(page);

  rideZoneLabel = lv_label_create(page);
  lv_obj_set_style_text_font(rideZoneLabel, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_align(rideZoneLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(rideZoneLabel, LV_LABEL_LONG_CLIP);
  lv_obj_add_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
}

void updateZoneMetric(const ride_telemetry_presenter::ViewModel &model) {
  const int8_t zoneIndex = ride_telemetry_presenter::fiveZoneIndex(model);
  if (zoneIndex == displayedZoneIndex) {
    return;
  }
  displayedZoneIndex = zoneIndex;

  if (zoneIndex < 0) {
    for (lv_obj_t *segment : rideZoneSegments) {
      lv_obj_add_flag(segment, LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_add_flag(rideZoneHeart, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  const std::size_t activeIndex = static_cast<std::size_t>(zoneIndex);
  const ride_telemetry_layout::ZoneStripLayout layout =
      ride_telemetry_layout::makeZoneStripLayout(rideLayout.metrics[1],
                                                 rideLayout.screenWidth,
                                                 activeIndex);
  for (std::size_t index = 0; index < rideZoneSegments.size(); ++index) {
    const ride_telemetry_layout::Rect &segmentRect = layout.segments[index];
    lv_obj_set_pos(rideZoneSegments[index], segmentRect.x, segmentRect.y);
    lv_obj_set_size(rideZoneSegments[index], segmentRect.width,
                    segmentRect.height);
    lv_obj_set_style_bg_color(rideZoneSegments[index],
                              zoneColor(index, index == activeIndex), 0);
    lv_obj_clear_flag(rideZoneSegments[index], LV_OBJ_FLAG_HIDDEN);
  }

  const lv_color_t foreground = zoneForegroundColor(activeIndex);
  lv_obj_set_pos(rideZoneHeart, layout.heart.x, layout.heart.y);
  lv_obj_set_size(rideZoneHeart, layout.heart.width, layout.heart.height);
  lv_obj_set_style_text_color(rideZoneHeart, foreground, 0);
  lv_obj_clear_flag(rideZoneHeart, LV_OBJ_FLAG_HIDDEN);

  lv_obj_set_pos(rideZoneLabel, layout.label.x, layout.label.y);
  lv_obj_set_size(rideZoneLabel, layout.label.width, layout.label.height);
  lv_obj_set_style_text_color(rideZoneLabel, foreground, 0);
  char label[8];
  std::snprintf(label, sizeof(label), "ZONE %u",
                static_cast<unsigned>(activeIndex + 1));
  setLabelIfChanged(rideZoneLabel, label);
  lv_obj_clear_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
}

void updateHeartRateMetric(
    const ride_telemetry_presenter::ViewModel &model) {
  const ride_telemetry_layout::Rect &metric = rideLayout.metrics[0];
  char value[24];
  ride_telemetry_presenter::formatInteger(model.currentHeartRateBpm, value,
                                          sizeof(value));

  if (!model.currentHeartRateBpm.available) {
    lv_obj_set_pos(rideHeartRateValue, metric.x,
                   metric.y + ride_telemetry_layout::kMetricValueOffsetY);
    lv_obj_set_width(rideHeartRateValue, metric.width);
    lv_obj_set_style_text_align(rideHeartRateValue, LV_TEXT_ALIGN_CENTER, 0);
    setMetricValueIfChanged(rideHeartRateValue, value);
    lv_obj_add_flag(rideHeartRateHeart, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  const int32_t maximumValueWidth =
      metric.width -
      ride_telemetry_layout::heartRateHeartSize(rideLayout.screenWidth) -
      ride_telemetry_layout::heartRateHeartGap(rideLayout.screenWidth);
  lv_obj_set_width(rideHeartRateValue, maximumValueWidth);
  // A heart rate is at most three digits here, so it fits beside the heart at
  // the regular tile size. Do not re-run adaptive sizing against the tightly
  // measured label width on each refresh or the font progressively shrinks.
  const lv_font_t *font = preferredMetricValueFont();
  if (lv_obj_get_style_text_font(rideHeartRateValue, LV_PART_MAIN) != font) {
    lv_obj_set_style_text_font(rideHeartRateValue, font, 0);
  }
  setLabelIfChanged(rideHeartRateValue, value);
  const int32_t textWidth = lv_text_get_width(
      value, static_cast<uint32_t>(std::strlen(value)), font, 0);
  const ride_telemetry_layout::ValueWithHeartLayout layout =
      ride_telemetry_layout::makeHeartRateValueLayout(
          metric, rideLayout.screenWidth, textWidth);

  lv_obj_set_pos(rideHeartRateValue, layout.value.x, layout.value.y);
  lv_obj_set_width(rideHeartRateValue, layout.value.width);
  lv_obj_set_style_text_align(rideHeartRateValue, LV_TEXT_ALIGN_LEFT, 0);

  lv_obj_set_pos(rideHeartRateHeart, layout.heart.x, layout.heart.y);
  lv_obj_set_size(rideHeartRateHeart, layout.heart.width,
                  layout.heart.height);
  lv_obj_set_style_text_color(rideHeartRateHeart, lv_color_hex(0xFF3B30), 0);
  lv_obj_clear_flag(rideHeartRateHeart, LV_OBJ_FLAG_HIDDEN);
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
      createMetric(ridePage, "Heart rate", rideLayout.metrics[0]).value;
  rideHeartRateHeart = createHeartIcon(ridePage);
  createZoneMetric(ridePage, rideLayout.metrics[1]);
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
  updateHeartRateMetric(model);
  updateZoneMetric(model);
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
