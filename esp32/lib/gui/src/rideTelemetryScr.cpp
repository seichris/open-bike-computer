/**
 * @file rideTelemetryScr.cpp
 * @brief Adaptive Watch workout and legacy GPS ride telemetry screen.
 */

#include "rideTelemetryScr.hpp"
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../ble_navigation/screen_configuration.hpp"
#include "../../ble_navigation/workout_telemetry_runtime.hpp"
#include "bikeIcon.hpp"
#include "gps.hpp"
#include "rideMetricTypography.hpp"
#include "rideTelemetryLayout.hpp"
#include "rideTelemetryPresenter.hpp"
#include "ride_stats_widget.hpp"
#include "mainScr.hpp"
#include "../../ride_automation/ride_automation_runtime.hpp"

#include <array>
#include <cstdio>
#include <cstring>

extern Gps gps;

namespace {

struct MetricLabels {
  lv_obj_t *title = nullptr;
  lv_obj_t *value = nullptr;
};

struct ConfigurableSlotView {
  MetricLabels labels{};
  lv_obj_t *heart = nullptr;
  std::array<lv_obj_t *, ride_telemetry_layout::kMaximumZoneCount>
      zoneSegments{};
  lv_obj_t *zoneHeart = nullptr;
  lv_obj_t *zoneLabel = nullptr;
  int8_t displayedZone = -2;
};

lv_obj_t *ridePage = nullptr;
lv_obj_t *rideStatus = nullptr;
lv_obj_t *rideSpeedValue = nullptr;
lv_obj_t *rideSpeedUnit = nullptr;
MetricLabels rideHeartRate{};
lv_obj_t *rideHeartRateHeart = nullptr;
lv_obj_t *rideZoneTitle = nullptr;
MetricLabels rideDistance{};
MetricLabels rideMoving{};
std::array<lv_obj_t *, ride_telemetry_layout::kMaximumZoneCount>
    rideZoneSegments{};
lv_obj_t *rideZoneHeart = nullptr;
lv_obj_t *rideZoneLabel = nullptr;
int8_t displayedZoneIndex = -2;
uint8_t displayedZoneCount = 0;
MetricLabels rideBottomLeft{};
MetricLabels rideBottomRight{};
lv_obj_t *rideStartWorkoutHitTarget = nullptr;
lv_obj_t *rideStartWorkoutButton = nullptr;
lv_obj_t *rideStartWorkoutIcon = nullptr;
lv_obj_t *rideStartWorkoutSpinner = nullptr;
lv_obj_t *rideStartWorkoutLabel = nullptr;
lv_obj_t *rideAutomationPanel = nullptr;
lv_obj_t *rideAutomationTitle = nullptr;
lv_obj_t *rideAutomationDetail = nullptr;
lv_obj_t *rideAutomationProgress = nullptr;
lv_obj_t *rideAutomationActions = nullptr;
ride_telemetry_layout::Layout rideLayout{};
ride_telemetry_layout::MetricPlacement rideMetricPlacement{};
int8_t displayedMetricLayout = -1;
bool rideStartWorkoutRequestPending = false;
uint32_t rideStartWorkoutRequestStartedAtMs = 0;
constexpr uint32_t START_WORKOUT_REQUEST_TIMEOUT_MS = 20000;
std::array<ConfigurableSlotView,
           screen_configuration_protocol::RIDE_STATS_SLOT_COUNT>
    configurableSlots{};

ride_metric_typography::Role metricFontRole() {
  return ride_telemetry_layout::useLargeMetricValueFont(rideLayout.screenWidth)
             ? ride_metric_typography::Role::MetricLarge
             : ride_metric_typography::Role::MetricCompact;
}

ride_telemetry_layout::Rect metricValueRect(
    const ride_telemetry_layout::Rect &metric) {
  return {metric.x, metric.y + ride_telemetry_layout::kMetricValueOffsetY,
          metric.width,
          metric.height - ride_telemetry_layout::kMetricValueOffsetY};
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

void setMetricTitleIfChanged(lv_obj_t *label, const char *text,
                             const ride_telemetry_layout::Rect &rect) {
  lv_obj_set_pos(label, rect.x, rect.y);
  lv_obj_set_size(label, rect.width,
                  ride_telemetry_layout::kMetricTitleLineHeight);
  const std::array<const lv_font_t *, 3> fonts = {
      &lv_font_montserrat_18, &lv_font_montserrat_14, &lv_font_montserrat_12};
  const lv_font_t *selected = fonts.back();
  for (const auto *font : fonts) {
    if (lv_text_get_width(text, std::strlen(text), font, 0) <= rect.width - 4) {
      selected = font;
      break;
    }
  }
  lv_obj_set_style_text_font(label, selected, 0);
  // Captions may elide as a last resort; numeric values never do.
  lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);
  setLabelIfChanged(label, text);
}

void applyMetricText(lv_obj_t *label, const char *text,
                     const ride_telemetry_layout::Rect &rect,
                     const lv_font_t *font, lv_text_align_t align) {
  lv_obj_set_pos(label, rect.x, rect.y);
  lv_obj_set_size(label, rect.width, rect.height);
  lv_obj_set_style_text_align(label, align, 0);
  lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
  if (font != nullptr &&
      lv_obj_get_style_text_font(label, LV_PART_MAIN) != font) {
    lv_obj_set_style_text_font(label, font, 0);
  }
  setLabelIfChanged(label, font != nullptr ? text : "");
}

void setMetricValueIfChanged(lv_obj_t *label, const char *text,
                             const ride_telemetry_layout::Rect &rect,
                             ride_metric_typography::Role role,
                             const lv_font_t *sharedFont = nullptr) {
  if (label == nullptr || text == nullptr)
    return;
  // Use the authoritative slot, not LVGL's previous/tightly measured label
  // width. Geometry changes and heart -> value transitions take effect now.
  const lv_font_t *font = sharedFont != nullptr ? sharedFont :
      ride_metric_typography::fontForText(
          text, rect.width - 4, rect.height, role);
  if (font == nullptr) {
    text = "--";
    font = ride_metric_typography::fontForText(
        text, rect.width - 4, rect.height, role);
  }
  applyMetricText(label, text, rect, font, LV_TEXT_ALIGN_CENTER);
}

void setHeartValue(lv_obj_t *label, lv_obj_t *heart, const char *text,
                   const ride_telemetry_layout::Rect &metric,
                   bool available, const lv_font_t *sharedFont = nullptr) {
  const auto presentation = ride_telemetry_layout::makeHeartRatePresentation(
      metric, rideLayout.screenWidth, available);
  const auto *font = available ? (sharedFont != nullptr ? sharedFont :
      ride_metric_typography::fontForText(
          text, presentation.fontSelectionWidth,
          presentation.unavailableValue.height, metricFontRole())) : nullptr;
  if (font == nullptr) {
    setMetricValueIfChanged(label, available ? "--" : text,
                             presentation.unavailableValue, metricFontRole());
    lv_obj_add_flag(heart, LV_OBJ_FLAG_HIDDEN);
    return;
  }
  const int32_t textWidth = lv_text_get_width(
      text, static_cast<uint32_t>(std::strlen(text)), font, 0);
  const auto placement = ride_telemetry_layout::makeHeartRateValueLayout(
      metric, rideLayout.screenWidth, textWidth);
  applyMetricText(label, text, placement.value, font, LV_TEXT_ALIGN_LEFT);
  lv_obj_set_pos(heart, placement.heart.x, placement.heart.y);
  lv_obj_set_size(heart, placement.heart.width, placement.heart.height);
  lv_obj_set_style_text_color(heart, lv_color_hex(0xFF3B30), 0);
  lv_obj_clear_flag(heart, LV_OBJ_FLAG_HIDDEN);
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
  lv_obj_set_size(status, rideLayout.status.width, rideLayout.status.height);
  lv_label_set_long_mode(status, LV_LABEL_LONG_CLIP);
  lv_obj_set_pos(status, rideLayout.status.x, rideLayout.status.y);
  lv_obj_set_style_text_font(status,
      ride_telemetry_layout::usesRoundScreenSafeArea(
          rideLayout.screenWidth, rideLayout.screenHeight)
          ? &lv_font_montserrat_14 : &lv_font_montserrat_18, 0);
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
  setMetricTitleIfChanged(label, title, rect);
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
  setMetricValueIfChanged(labels.value, "--", metricValueRect(rect),
                           metricFontRole());
  return labels;
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
  rideZoneTitle = createMetricTitle(page, "HR zone", rect);

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
  const uint8_t count = ride_telemetry_presenter::zoneCount(model);
  if (displayedZoneCount != count) displayedZoneIndex = -2;
  displayedZoneCount = count;
  setMetricTitleIfChanged(rideZoneTitle, ride_telemetry_presenter::zoneTitle(model),
                           rideMetricPlacement.heartRateZone);
  const ride_telemetry_layout::ZonePresentation presentation =
      ride_telemetry_layout::makeZonePresentation(
          rideMetricPlacement.heartRateZone, rideLayout.screenWidth,
          displayedZoneIndex,
          ride_telemetry_presenter::zoneIndex(model), count);
  if (presentation.update.action ==
      ride_telemetry_layout::ZoneUpdateAction::None) {
    return;
  }
  displayedZoneIndex = presentation.update.zoneIndex;

  if (presentation.update.action ==
      ride_telemetry_layout::ZoneUpdateAction::Hide) {
    for (lv_obj_t *segment : rideZoneSegments) {
      lv_obj_add_flag(segment, LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_add_flag(rideZoneHeart, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  for (std::size_t index = 0; index < rideZoneSegments.size(); ++index) {
    if (!presentation.segmentVisible[index]) {
      lv_obj_add_flag(rideZoneSegments[index], LV_OBJ_FLAG_HIDDEN);
      continue;
    }
    const ride_telemetry_layout::Rect &segmentRect =
        presentation.segments[index];
    lv_obj_set_pos(rideZoneSegments[index], segmentRect.x, segmentRect.y);
    lv_obj_set_size(rideZoneSegments[index], segmentRect.width,
                    segmentRect.height);
    lv_obj_set_style_bg_color(
        rideZoneSegments[index],
        lv_color_hex(presentation.segmentColors[index]), 0);
    if (presentation.segmentVisible[index]) {
      lv_obj_clear_flag(rideZoneSegments[index], LV_OBJ_FLAG_HIDDEN);
    }
  }

  const lv_color_t foreground =
      lv_color_hex(presentation.foregroundColor);
  lv_obj_set_pos(rideZoneHeart, presentation.heart.x,
                 presentation.heart.y);
  lv_obj_set_size(rideZoneHeart, presentation.heart.width,
                  presentation.heart.height);
  lv_obj_set_style_text_color(rideZoneHeart, foreground, 0);
  if (presentation.heartVisible) {
    lv_obj_clear_flag(rideZoneHeart, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(rideZoneHeart, LV_OBJ_FLAG_HIDDEN);
  }

  lv_obj_set_pos(rideZoneLabel, presentation.label.x,
                 presentation.label.y);
  lv_obj_set_size(rideZoneLabel, presentation.label.width,
                  presentation.label.height);
  lv_obj_set_style_text_color(rideZoneLabel, foreground, 0);
  setMetricValueIfChanged(rideZoneLabel, presentation.labelText.data(),
                           presentation.label,
                           ride_metric_typography::Role::Zone);
  if (presentation.labelVisible) {
    lv_obj_clear_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
  }
}

void updateHeartRateMetric(
    const ride_telemetry_presenter::ViewModel &model) {
  const ride_telemetry_layout::Rect &metric = rideMetricPlacement.heartRate;
  const bool ended = model.sessionState ==
                     workout_telemetry_protocol::SessionState::Ended;
  const auto heartRate = ended ? model.averageHeartRateBpm
                               : model.currentHeartRateBpm;
  char value[24];
  ride_telemetry_presenter::formatInteger(heartRate, value, sizeof(value));
  setHeartValue(rideHeartRate.value, rideHeartRateHeart, value, metric,
                 heartRate.available);
}

void positionMetric(MetricLabels labels,
                    const ride_telemetry_layout::Rect &rect) {
  if (labels.title != nullptr) {
    lv_obj_set_size(labels.title, rect.width,
                    ride_telemetry_layout::kMetricTitleLineHeight);
    lv_obj_set_pos(labels.title, rect.x, rect.y);
  }
  if (labels.value != nullptr) {
    lv_obj_set_size(labels.value, rect.width,
                    rect.height - ride_telemetry_layout::kMetricValueOffsetY);
    lv_obj_set_pos(labels.value, rect.x,
                   rect.y + ride_telemetry_layout::kMetricValueOffsetY);
  }
}

void hideZonePresentation() {
  for (lv_obj_t *segment : rideZoneSegments) {
    lv_obj_add_flag(segment, LV_OBJ_FLAG_HIDDEN);
  }
  lv_obj_add_flag(rideZoneHeart, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
  displayedZoneIndex = -2;
}

void setConfigurableSlotHidden(ConfigurableSlotView &slot, bool hidden) {
  auto set = [hidden](lv_obj_t *object) {
    if (object == nullptr)
      return;
    if (hidden)
      lv_obj_add_flag(object, LV_OBJ_FLAG_HIDDEN);
    else
      lv_obj_clear_flag(object, LV_OBJ_FLAG_HIDDEN);
  };
  set(slot.labels.title);
  set(slot.labels.value);
  set(slot.heart);
  for (lv_obj_t *segment : slot.zoneSegments)
    set(segment);
  set(slot.zoneHeart);
  set(slot.zoneLabel);
}

void createConfigurableSlot(std::size_t index) {
  ConfigurableSlotView &slot = configurableSlots[index];
  const auto rect =
      ride_telemetry_layout::configurableSlotRect(rideLayout, index);
  if (index == 0) {
    slot.labels.value = lv_label_create(ridePage);
    lv_obj_set_width(slot.labels.value, rideLayout.hero.width);
    lv_obj_set_pos(slot.labels.value, rideLayout.hero.x, rideLayout.hero.y);
    lv_obj_set_style_text_font(slot.labels.value, &ride_speed_font_84, 0);
    lv_obj_set_style_text_color(slot.labels.value, lv_color_white(), 0);
    lv_obj_set_style_text_align(slot.labels.value, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_long_mode(slot.labels.value, LV_LABEL_LONG_CLIP);
    slot.labels.title = createMetricTitle(ridePage, "", rideLayout.heroUnit);
  } else {
    slot.labels = createMetric(ridePage, "", rect);
  }
  slot.heart = createHeartIcon(ridePage);
  for (lv_obj_t *&segment : slot.zoneSegments) {
    segment = lv_obj_create(ridePage);
    lv_obj_remove_style_all(segment);
    lv_obj_set_style_radius(segment, 10, 0);
    lv_obj_set_style_bg_opa(segment, LV_OPA_COVER, 0);
    lv_obj_clear_flag(
        segment, static_cast<lv_obj_flag_t>(LV_OBJ_FLAG_SCROLLABLE |
                                            LV_OBJ_FLAG_CLICKABLE));
  }
  slot.zoneHeart = createHeartIcon(ridePage);
  slot.zoneLabel = lv_label_create(ridePage);
  lv_obj_set_style_text_font(slot.zoneLabel, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_align(slot.zoneLabel, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(slot.zoneLabel, LV_LABEL_LONG_CLIP);
  setConfigurableSlotHidden(slot, true);
}

void hideLegacyWorkoutMetrics() {
  lv_obj_add_flag(rideSpeedValue, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideSpeedUnit, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideHeartRate.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideHeartRate.value, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideHeartRateHeart, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideZoneTitle, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideDistance.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideDistance.value, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideMoving.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideMoving.value, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideBottomLeft.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideBottomLeft.value, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideBottomRight.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideBottomRight.value, LV_OBJ_FLAG_HIDDEN);
  hideZonePresentation();
}

void updateConfigurableZone(
    ConfigurableSlotView &slot, const ride_telemetry_layout::Rect &rect,
    const ride_stats_widget::Presentation &widget) {
  const auto presentation = ride_telemetry_layout::makeZonePresentation(
      rect, rideLayout.screenWidth, slot.displayedZone, widget.zoneIndex,
      widget.zoneCount, widget.zoneShowsHeart);
  slot.displayedZone = widget.zoneIndex;
  if (presentation.update.action ==
      ride_telemetry_layout::ZoneUpdateAction::Hide) {
    for (lv_obj_t *segment : slot.zoneSegments)
      lv_obj_add_flag(segment, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(slot.zoneHeart, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(slot.zoneLabel, LV_OBJ_FLAG_HIDDEN);
    return;
  }
  if (presentation.update.action ==
      ride_telemetry_layout::ZoneUpdateAction::None)
    return;
  for (std::size_t index = 0; index < slot.zoneSegments.size(); ++index) {
    if (!presentation.segmentVisible[index]) {
      lv_obj_add_flag(slot.zoneSegments[index], LV_OBJ_FLAG_HIDDEN);
      continue;
    }
    const auto &segment = presentation.segments[index];
    lv_obj_set_pos(slot.zoneSegments[index], segment.x, segment.y);
    lv_obj_set_size(slot.zoneSegments[index], segment.width, segment.height);
    lv_obj_set_style_bg_color(
        slot.zoneSegments[index],
        lv_color_hex(presentation.segmentColors[index]), 0);
    lv_obj_clear_flag(slot.zoneSegments[index], LV_OBJ_FLAG_HIDDEN);
  }
  const lv_color_t foreground = lv_color_hex(presentation.foregroundColor);
  lv_obj_set_pos(slot.zoneHeart, presentation.heart.x, presentation.heart.y);
  lv_obj_set_size(slot.zoneHeart, presentation.heart.width,
                  presentation.heart.height);
  lv_obj_set_style_text_color(slot.zoneHeart, foreground, 0);
  if (presentation.heartVisible)
    lv_obj_clear_flag(slot.zoneHeart, LV_OBJ_FLAG_HIDDEN);
  else
    lv_obj_add_flag(slot.zoneHeart, LV_OBJ_FLAG_HIDDEN);
  lv_obj_set_pos(slot.zoneLabel, presentation.label.x, presentation.label.y);
  lv_obj_set_size(slot.zoneLabel, presentation.label.width,
                  presentation.label.height);
  lv_obj_set_style_text_color(slot.zoneLabel, foreground, 0);
  setMetricValueIfChanged(slot.zoneLabel, presentation.labelText.data(),
                           presentation.label,
                           ride_metric_typography::Role::Zone);
  lv_obj_clear_flag(slot.zoneLabel, LV_OBJ_FLAG_HIDDEN);
}

void updateConfigurableSlots(
    const ride_telemetry_presenter::ViewModel &model) {
  hideLegacyWorkoutMetrics();
  const auto &layout = currentRideStatsLayout();
  std::array<ride_stats_widget::Presentation,
             ride_telemetry_layout::kConfigurableSlotCount> widgets{};
  std::array<const lv_font_t *, ride_telemetry_layout::kConfigurableSlotCount>
      sharedFonts{};
  for (std::size_t index = 0; index < widgets.size(); ++index)
    widgets[index] = ride_stats_widget::make(layout.slots[index], model);
  for (std::size_t right = 2; right < widgets.size(); right += 2) {
    const auto &leftWidget = widgets[right - 1];
    const auto &rightWidget = widgets[right];
    if (!rightWidget.isAltitude || !rightWidget.available ||
        !leftWidget.available ||
        (leftWidget.kind != ride_stats_widget::PresentationKind::Scalar &&
         leftWidget.kind != ride_stats_widget::PresentationKind::HeartWithValue))
      continue;
    const auto leftRect =
        ride_telemetry_layout::configurableValueRect(rideLayout, right - 1);
    const auto rightRect =
        ride_telemetry_layout::configurableValueRect(rideLayout, right);
    const int32_t heartInset =
        leftWidget.kind == ride_stats_widget::PresentationKind::HeartWithValue
            ? ride_telemetry_layout::heartRateHeartSize(rideLayout.screenWidth) +
                  ride_telemetry_layout::heartRateHeartGap(rideLayout.screenWidth)
            : 0;
    const auto *font = ride_metric_typography::fontForPair(
        {leftWidget.value.data(), leftRect.width - 4 - heartInset, leftRect.height},
        {rightWidget.value.data(), rightRect.width - 4, rightRect.height},
        metricFontRole());
    sharedFonts[right - 1] = sharedFonts[right] = font;
  }
  for (std::size_t index = 0; index < configurableSlots.size(); ++index) {
    ConfigurableSlotView &slot = configurableSlots[index];
    setConfigurableSlotHidden(slot, true);
    slot.displayedZone = -2;
    const auto &widget = widgets[index];
    if (widget.kind == ride_stats_widget::PresentationKind::Empty)
      continue;
    const auto rect =
        ride_telemetry_layout::configurableSlotRect(rideLayout, index);
    char title[40]{};
    if (index == 0 && widget.unit[0] != '\0')
      std::snprintf(title, sizeof(title), "%s %s", widget.title, widget.unit);
    else
      std::snprintf(title, sizeof(title), "%s", widget.title);
    setMetricTitleIfChanged(slot.labels.title, title,
                             index == 0 ? rideLayout.heroUnit : rect);
    lv_obj_clear_flag(slot.labels.title, LV_OBJ_FLAG_HIDDEN);
    if (widget.kind == ride_stats_widget::PresentationKind::ZoneStrip &&
        widget.available) {
      updateConfigurableZone(slot, rect, widget);
      continue;
    }
    lv_obj_clear_flag(slot.labels.value, LV_OBJ_FLAG_HIDDEN);
    if (widget.kind == ride_stats_widget::PresentationKind::HeartWithValue) {
      setHeartValue(slot.labels.value, slot.heart, widget.value.data(), rect,
                     widget.available, sharedFonts[index]);
    } else {
      setMetricValueIfChanged(
          slot.labels.value, widget.value.data(),
          ride_telemetry_layout::configurableValueRect(rideLayout, index),
          index == 0 ? ride_metric_typography::Role::Hero : metricFontRole(),
          sharedFonts[index]);
    }
  }
}

void startWorkoutEvent(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_CLICKED ||
      rideStartWorkoutRequestPending) {
    return;
  }
  if (!bleNavServer.requestWorkoutStart()) {
    return;
  }
  rideStartWorkoutRequestPending = true;
  rideStartWorkoutRequestStartedAtMs = millis();
  updateRideTelemetryEvent(nullptr);
}

void setStartWorkoutHidden(bool hidden) {
  if (hidden) {
    lv_obj_add_flag(rideStartWorkoutHitTarget, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_clear_flag(rideStartWorkoutHitTarget, LV_OBJ_FLAG_HIDDEN);
  }
}

void setStartWorkoutDisabled(bool disabled) {
  if (disabled) {
    lv_obj_add_state(rideStartWorkoutHitTarget, LV_STATE_DISABLED);
    lv_obj_add_state(rideStartWorkoutButton, LV_STATE_DISABLED);
  } else {
    lv_obj_clear_state(rideStartWorkoutHitTarget, LV_STATE_DISABLED);
    lv_obj_clear_state(rideStartWorkoutButton, LV_STATE_DISABLED);
  }
}

void setStartWorkoutLoading(bool loading) {
  if (loading) {
    lv_obj_add_flag(rideStartWorkoutIcon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideStartWorkoutSpinner, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_clear_flag(rideStartWorkoutIcon, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(rideStartWorkoutSpinner, LV_OBJ_FLAG_HIDDEN);
  }
}

void rideDetectedStartEvent(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_CLICKED)
    return;
  ride_automation_runtime::respondToStartPrompt(true, millis());
  updateRideTelemetryEvent(nullptr);
}

void rideDetectedDismissEvent(lv_event_t *event) {
  if (lv_event_get_code(event) != LV_EVENT_CLICKED)
    return;
  ride_automation_runtime::respondToStartPrompt(false, millis());
  updateRideTelemetryEvent(nullptr);
}

lv_obj_t *createAutomationAction(lv_obj_t *parent, const char *title,
                                 uint32_t color, lv_event_cb_t callback) {
  lv_obj_t *button = lv_btn_create(parent);
  lv_obj_set_size(button, (rideLayout.page.width - 52) / 2, 52);
  lv_obj_set_style_radius(button, 12, 0);
  lv_obj_set_style_bg_color(button, lv_color_hex(color), 0);
  lv_obj_set_style_shadow_width(button, 0, 0);
  lv_obj_add_event_cb(button, callback, LV_EVENT_CLICKED, nullptr);
  lv_obj_t *label = lv_label_create(button);
  lv_obj_set_style_text_font(label, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(label, lv_color_black(), 0);
  lv_label_set_text(label, title);
  lv_obj_center(label);
  return button;
}

void createAutomationPanel(lv_obj_t *page) {
  rideAutomationPanel = lv_obj_create(page);
  lv_obj_set_width(rideAutomationPanel, rideLayout.page.width - 28);
  lv_obj_set_height(rideAutomationPanel, 190);
  lv_obj_align(rideAutomationPanel, LV_ALIGN_CENTER, 0, 0);
  lv_obj_set_style_radius(rideAutomationPanel, 18, 0);
  lv_obj_set_style_bg_color(rideAutomationPanel, lv_color_hex(0x111815), 0);
  lv_obj_set_style_bg_opa(rideAutomationPanel, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(rideAutomationPanel, 2, 0);
  lv_obj_set_style_border_color(rideAutomationPanel,
                                lv_color_hex(0x66DD88), 0);
  lv_obj_set_style_pad_all(rideAutomationPanel, 12, 0);
  lv_obj_clear_flag(rideAutomationPanel, LV_OBJ_FLAG_SCROLLABLE);

  rideAutomationTitle = lv_label_create(rideAutomationPanel);
  lv_obj_set_width(rideAutomationTitle, rideLayout.page.width - 56);
  lv_obj_align(rideAutomationTitle, LV_ALIGN_TOP_MID, 0, 0);
  lv_obj_set_style_text_font(rideAutomationTitle,
                             &lv_font_montserrat_24, 0);
  lv_obj_set_style_text_color(rideAutomationTitle, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideAutomationTitle, LV_TEXT_ALIGN_CENTER, 0);

  rideAutomationDetail = lv_label_create(rideAutomationPanel);
  lv_obj_set_width(rideAutomationDetail, rideLayout.page.width - 60);
  lv_obj_align(rideAutomationDetail, LV_ALIGN_TOP_MID, 0, 42);
  lv_obj_set_style_text_font(rideAutomationDetail,
                             &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(rideAutomationDetail,
                              lv_color_hex(0xBBBBBB), 0);
  lv_obj_set_style_text_align(rideAutomationDetail, LV_TEXT_ALIGN_CENTER, 0);
  lv_label_set_long_mode(rideAutomationDetail, LV_LABEL_LONG_WRAP);

  rideAutomationProgress = lv_bar_create(rideAutomationPanel);
  lv_obj_set_size(rideAutomationProgress, rideLayout.page.width - 70, 12);
  lv_obj_align(rideAutomationProgress, LV_ALIGN_BOTTOM_MID, 0, -16);
  lv_obj_set_style_bg_color(rideAutomationProgress,
                            lv_color_hex(0x26322D), LV_PART_MAIN);
  lv_obj_set_style_bg_color(rideAutomationProgress,
                            lv_color_hex(0x66DD88), LV_PART_INDICATOR);

  rideAutomationActions = lv_obj_create(rideAutomationPanel);
  lv_obj_remove_style_all(rideAutomationActions);
  lv_obj_set_size(rideAutomationActions, rideLayout.page.width - 48, 58);
  lv_obj_align(rideAutomationActions, LV_ALIGN_BOTTOM_MID, 0, 0);
  lv_obj_set_flex_flow(rideAutomationActions, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(rideAutomationActions, LV_FLEX_ALIGN_SPACE_BETWEEN,
                        LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_clear_flag(rideAutomationActions, LV_OBJ_FLAG_SCROLLABLE);
  createAutomationAction(rideAutomationActions, "Not Now", 0x777777,
                         rideDetectedDismissEvent);
  createAutomationAction(rideAutomationActions, "Start Ride", 0x66DD88,
                         rideDetectedStartEvent);

  lv_obj_add_flag(rideAutomationPanel, LV_OBJ_FLAG_HIDDEN);
}

void updateAutomationPanel(uint32_t nowMs) {
  const ride_automation_runtime::UiSnapshot snapshot =
      ride_automation_runtime::uiSnapshot(nowMs);
  if (!ride_automation_runtime::shouldShowAutomationPanel(snapshot.phase)) {
    lv_obj_add_flag(rideAutomationPanel, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  const char *title = "Ride Detection";
  const char *detail = "";
  char detailBuffer[128]{};
  bool showActions = false;
  bool showProgress = false;
  uint32_t borderColor = 0x66DD88;
  switch (snapshot.phase) {
  case ride_automation_runtime::UiPhase::StartCandidate:
    title = "Detecting ride";
    detail = "Checking sustained cycling evidence";
    showProgress = true;
    break;
  case ride_automation_runtime::UiPhase::StartPrompt:
    title = "Start Ride?";
    snprintf(detailBuffer, sizeof(detailBuffer),
             "Cycling detected. Start on Apple Watch? %us remaining",
             static_cast<unsigned>(snapshot.remainingSeconds));
    detail = detailBuffer;
    showActions = true;
    break;
  case ride_automation_runtime::UiPhase::Starting:
    title = "Starting";
    detail = "Waiting for Apple Watch to confirm the workout";
    showProgress = true;
    break;
  case ride_automation_runtime::UiPhase::PauseCandidate:
    title = "Checking stop";
    detail = "The ride stays running until Apple Watch confirms";
    showProgress = true;
    break;
  case ride_automation_runtime::UiPhase::AwaitingPause:
    title = "Pausing";
    detail = "Waiting for Apple Watch confirmation";
    showProgress = true;
    break;
  case ride_automation_runtime::UiPhase::ResumeCandidate:
    title = "Checking motion";
    detail = "Confirming that the ride has resumed";
    showProgress = true;
    break;
  case ride_automation_runtime::UiPhase::AwaitingResume:
    title = "Resuming";
    detail = "Waiting for Apple Watch confirmation";
    showProgress = true;
    break;
  case ride_automation_runtime::UiPhase::RideResumed:
    title = "Ride resumed";
    detail = "Apple Watch confirmed moving time is running";
    break;
  case ride_automation_runtime::UiPhase::SensorDegraded:
    // Source health is diagnostic state, not a modal ride action. Keep the
    // stats page unobstructed until there is a candidate or decision to show.
    break;
  case ride_automation_runtime::UiPhase::Error:
    title = "Ride not started";
    borderColor = 0xFF6666;
    switch (snapshot.error) {
    case ride_automation_runtime::UiError::PhoneOrWatchUnavailable:
      detail = "Open Bicino on iPhone to start the Watch workout";
      break;
    case ride_automation_runtime::UiError::SessionMismatch:
      detail = "Reconnect Bicino to the current Watch workout";
      break;
    case ride_automation_runtime::UiError::Rejected:
      detail = "The ride request was not accepted";
      break;
    case ride_automation_runtime::UiError::None:
      detail = "Apple Watch did not confirm the request";
      break;
    }
    break;
  case ride_automation_runtime::UiPhase::Hidden:
    break;
  }

  lv_obj_set_style_border_color(rideAutomationPanel,
                                lv_color_hex(borderColor), 0);
  setLabelIfChanged(rideAutomationTitle, title);
  setLabelIfChanged(rideAutomationDetail, detail);
  lv_bar_set_value(rideAutomationProgress, snapshot.progressPercent,
                   LV_ANIM_OFF);
  if (showActions) {
    lv_obj_clear_flag(rideAutomationActions, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(rideAutomationActions, LV_OBJ_FLAG_HIDDEN);
  }
  if (showProgress) {
    lv_obj_clear_flag(rideAutomationProgress, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(rideAutomationProgress, LV_OBJ_FLAG_HIDDEN);
  }
  lv_obj_clear_flag(rideAutomationPanel, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(rideAutomationPanel);
}

ride_telemetry_layout::MetricLayoutMode metricLayoutMode(
    const ride_telemetry_presenter::ViewModel &model) {
  if (model.usesWorkout) {
    return ride_telemetry_layout::MetricLayoutMode::Workout;
  }
  return model.hasActiveNavigation
             ? ride_telemetry_layout::MetricLayoutMode::NavigationOnly
             : ride_telemetry_layout::MetricLayoutMode::Idle;
}

void updateMetricLayout(const ride_telemetry_presenter::ViewModel &model) {
  const bool usesConfigurableLayout =
      model.usesWorkout && screen_configuration::isReady();
  if (usesConfigurableLayout) {
    // Force legacy placement/visibility restoration if configuration becomes
    // unavailable without a workout-mode transition.
    displayedMetricLayout = -2;
    rideMetricPlacement = ride_telemetry_layout::makeMetricPlacement(
        rideLayout, ride_telemetry_layout::MetricLayoutMode::Workout);
    setStartWorkoutHidden(true);
    return;
  }
  for (ConfigurableSlotView &slot : configurableSlots)
    setConfigurableSlotHidden(slot, true);
  lv_obj_clear_flag(rideSpeedValue, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(rideSpeedUnit, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(rideDistance.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(rideDistance.value, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(rideMoving.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(rideMoving.value, LV_OBJ_FLAG_HIDDEN);
  const ride_telemetry_layout::MetricLayoutMode mode = metricLayoutMode(model);
  const int8_t nextLayout = static_cast<int8_t>(mode);
  if (displayedMetricLayout == nextLayout) {
    return;
  }
  displayedMetricLayout = nextLayout;
  rideMetricPlacement =
      ride_telemetry_layout::makeMetricPlacement(rideLayout, mode);
  setMetricTitleIfChanged(rideMoving.title,
                           model.usesWorkout ? "Moving" : "Elapsed",
                           rideMetricPlacement.elapsed);

  positionMetric(rideHeartRate, rideMetricPlacement.heartRate);
  positionMetric({rideZoneTitle, rideZoneLabel},
                 rideMetricPlacement.heartRateZone);
  positionMetric(rideDistance, rideMetricPlacement.distance);
  positionMetric(rideMoving, rideMetricPlacement.elapsed);
  positionMetric(rideBottomLeft, rideMetricPlacement.bottomLeft);
  positionMetric(rideBottomRight, rideMetricPlacement.bottomRight);
  lv_obj_set_pos(rideStartWorkoutHitTarget,
                 rideMetricPlacement.startWorkoutHitTarget.x,
                 rideMetricPlacement.startWorkoutHitTarget.y);
  lv_obj_set_size(rideStartWorkoutHitTarget,
                  rideMetricPlacement.startWorkoutHitTarget.width,
                  rideMetricPlacement.startWorkoutHitTarget.height);
  lv_obj_set_pos(rideStartWorkoutButton,
                 rideMetricPlacement.startWorkoutButton.x -
                     rideMetricPlacement.startWorkoutHitTarget.x,
                 rideMetricPlacement.startWorkoutButton.y -
                     rideMetricPlacement.startWorkoutHitTarget.y);
  lv_obj_set_size(rideStartWorkoutButton,
                  rideMetricPlacement.startWorkoutButton.width,
                  rideMetricPlacement.startWorkoutButton.height);

  if (rideMetricPlacement.showWorkoutOnlyMetrics) {
    lv_obj_clear_flag(rideHeartRate.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideHeartRate.value, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideZoneTitle, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomLeft.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomLeft.value, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomRight.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomRight.value, LV_OBJ_FLAG_HIDDEN);
    setStartWorkoutHidden(true);
    return;
  }

  lv_obj_add_flag(rideHeartRate.title, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideHeartRate.value, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideHeartRateHeart, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideZoneTitle, LV_OBJ_FLAG_HIDDEN);
  hideZonePresentation();
  if (rideMetricPlacement.showBottomMetrics) {
    lv_obj_clear_flag(rideBottomLeft.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomLeft.value, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomRight.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(rideBottomRight.value, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(rideBottomLeft.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(rideBottomLeft.value, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(rideBottomRight.title, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(rideBottomRight.value, LV_OBJ_FLAG_HIDDEN);
  }
  setStartWorkoutHidden(false);
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
    const ride_telemetry_presenter::ViewModel &model,
    const ride_telemetry_layout::Rect &rect,
    const lv_font_t *sharedFont = nullptr) {
  setMetricTitleIfChanged(labels.title,
                           ride_telemetry_presenter::bottomMetricTitle(metric),
                           rect);
  char value[24];
  ride_telemetry_presenter::formatBottomMetric(metric, model, value,
                                                sizeof(value));
  setMetricValueIfChanged(labels.value, value, metricValueRect(rect),
                           metricFontRole(), sharedFont);
}

} // namespace

void rideTelemetryScr(_lv_obj_t *screen) {
  lv_obj_set_style_bg_color(screen, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

  rideLayout = ride_telemetry_layout::makeLayout(TFT_WIDTH, TFT_HEIGHT);
  rideStartWorkoutRequestPending = false;
  rideStartWorkoutRequestStartedAtMs = 0;

  ridePage = createPage(screen);
  rideStatus = createHeader(ridePage);

  rideSpeedValue = lv_label_create(ridePage);
  lv_obj_set_width(rideSpeedValue, rideLayout.hero.width);
  lv_obj_set_pos(rideSpeedValue, rideLayout.hero.x, rideLayout.hero.y);
  lv_obj_set_style_text_font(rideSpeedValue, &ride_speed_font_84, 0);
  lv_obj_set_style_text_color(rideSpeedValue, lv_color_white(), 0);
  lv_obj_set_style_text_align(rideSpeedValue, LV_TEXT_ALIGN_CENTER, 0);
  setMetricValueIfChanged(rideSpeedValue, "0.0", rideLayout.hero,
                           ride_metric_typography::Role::Hero);

  rideSpeedUnit = lv_label_create(ridePage);
  lv_obj_set_width(rideSpeedUnit, rideLayout.heroUnit.width);
  lv_obj_set_pos(rideSpeedUnit, rideLayout.heroUnit.x, rideLayout.heroUnit.y);
  lv_obj_set_style_text_font(rideSpeedUnit, &lv_font_montserrat_18, 0);
  lv_obj_set_style_text_color(rideSpeedUnit, lv_color_hex(0x999999), 0);
  lv_obj_set_style_text_align(rideSpeedUnit, LV_TEXT_ALIGN_CENTER, 0);
  setMetricTitleIfChanged(rideSpeedUnit, "km/h", rideLayout.heroUnit);

  rideHeartRate =
      createMetric(ridePage, "Heart rate", rideLayout.metrics[0]);
  rideHeartRateHeart = createHeartIcon(ridePage);
  createZoneMetric(ridePage, rideLayout.metrics[1]);
  rideDistance =
      createMetric(ridePage, "Distance", rideLayout.metrics[2]);
  rideMoving = createMetric(ridePage, "Moving", rideLayout.metrics[3]);
  rideBottomLeft =
      createMetric(ridePage, "Altitude m", rideLayout.metrics[4]);
  rideBottomRight =
      createMetric(ridePage, "Route left", rideLayout.metrics[5]);

  rideStartWorkoutHitTarget = lv_obj_create(ridePage);
  lv_obj_remove_style_all(rideStartWorkoutHitTarget);
  // The visible button remains inset for the round display, while this
  // transparent parent accepts less precisely calibrated physical taps.
  lv_obj_add_flag(rideStartWorkoutHitTarget, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_clear_flag(rideStartWorkoutHitTarget, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_event_cb(rideStartWorkoutHitTarget, startWorkoutEvent,
                      LV_EVENT_CLICKED, nullptr);

  rideStartWorkoutButton = lv_btn_create(rideStartWorkoutHitTarget);
  lv_obj_set_style_radius(rideStartWorkoutButton, 16, 0);
  lv_obj_set_style_bg_color(rideStartWorkoutButton, lv_color_hex(0x66DD88), 0);
  lv_obj_set_style_bg_opa(rideStartWorkoutButton, LV_OPA_COVER, 0);
  lv_obj_set_style_shadow_width(rideStartWorkoutButton, 0, 0);
  lv_obj_set_style_pad_all(rideStartWorkoutButton, 0, 0);
  const bool useRoundStartWorkoutContent =
      ride_telemetry_layout::usesRoundScreenSafeArea(
          rideLayout.screenWidth, rideLayout.screenHeight);
  lv_obj_set_style_pad_column(rideStartWorkoutButton,
                              useRoundStartWorkoutContent ? 12 : 9, 0);
  lv_obj_set_flex_flow(rideStartWorkoutButton, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(rideStartWorkoutButton, LV_FLEX_ALIGN_CENTER,
                        LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_clear_flag(rideStartWorkoutButton, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_event_cb(rideStartWorkoutButton, startWorkoutEvent,
                      LV_EVENT_CLICKED, nullptr);
  const lv_coord_t startWorkoutIconSize =
      useRoundStartWorkoutContent
          ? ride_telemetry_layout::kRoundStartWorkoutIconSize
          : ride_telemetry_layout::kStartWorkoutIconSize;
  rideStartWorkoutIcon =
      bike_icon::create(rideStartWorkoutButton, startWorkoutIconSize, 0x000000);
  rideStartWorkoutSpinner = lv_spinner_create(rideStartWorkoutButton);
  lv_obj_set_size(rideStartWorkoutSpinner, startWorkoutIconSize,
                  startWorkoutIconSize);
  lv_spinner_set_anim_params(rideStartWorkoutSpinner, 900, 220);
  lv_obj_set_style_arc_width(rideStartWorkoutSpinner, 4, LV_PART_MAIN);
  lv_obj_set_style_arc_color(rideStartWorkoutSpinner, lv_color_hex(0x2D8A50),
                             LV_PART_MAIN);
  lv_obj_set_style_arc_width(rideStartWorkoutSpinner, 4, LV_PART_INDICATOR);
  lv_obj_set_style_arc_color(rideStartWorkoutSpinner, lv_color_black(),
                             LV_PART_INDICATOR);
  lv_obj_add_flag(rideStartWorkoutSpinner, LV_OBJ_FLAG_HIDDEN);
  rideStartWorkoutLabel = lv_label_create(rideStartWorkoutButton);
  lv_obj_set_style_text_font(
      rideStartWorkoutLabel,
      useRoundStartWorkoutContent ? &lv_font_montserrat_24
                                  : &lv_font_montserrat_18,
      0);
  lv_obj_set_style_text_color(rideStartWorkoutLabel, lv_color_black(), 0);
  lv_label_set_text_static(rideStartWorkoutLabel, "Start Workout");

  createAutomationPanel(ridePage);

  for (std::size_t index = 0; index < configurableSlots.size(); ++index)
    createConfigurableSlot(index);

  displayedMetricLayout = -1;
  updateRideTelemetryEvent(nullptr);
}

void updateRideTelemetryEvent(lv_event_t *) {
  const ride_telemetry_presenter::ViewModel model = currentViewModel();
  updateMetricLayout(model);
  const WorkoutStartRequestPresentation startWorkoutPresentation =
      bleNavServer.workoutStartRequestPresentation();
  const uint32_t nowMs = millis();
  if (rideStartWorkoutRequestPending &&
      (model.usesWorkout ||
       startWorkoutPresentation !=
           WorkoutStartRequestPresentation::StartOnIPhone ||
       static_cast<uint32_t>(nowMs - rideStartWorkoutRequestStartedAtMs) >=
           START_WORKOUT_REQUEST_TIMEOUT_MS)) {
    rideStartWorkoutRequestPending = false;
  }
  setStartWorkoutLoading(rideStartWorkoutRequestPending);
  if (rideMetricPlacement.showStartWorkoutButton) {
    switch (startWorkoutPresentation) {
    case WorkoutStartRequestPresentation::StartOnIPhone:
      setLabelIfChanged(rideStartWorkoutLabel, "Start Workout");
      setStartWorkoutDisabled(rideStartWorkoutRequestPending);
      break;
    case WorkoutStartRequestPresentation::StartOnAppleWatch:
      setLabelIfChanged(rideStartWorkoutLabel, "Start on Apple Watch");
      setStartWorkoutDisabled(true);
      break;
    case WorkoutStartRequestPresentation::Unavailable:
      setLabelIfChanged(rideStartWorkoutLabel, "Start Workout");
      setStartWorkoutDisabled(true);
      break;
    }
  }
  updateStatusLabel(rideStatus, model);

  if (model.usesWorkout && screen_configuration::isReady()) {
    updateConfigurableSlots(model);
    updateAutomationPanel(millis());
    return;
  }

  const bool ended = model.usesWorkout &&
                     model.sessionState ==
                         workout_telemetry_protocol::SessionState::Ended;
  setMetricTitleIfChanged(rideSpeedUnit, ended ? "average km/h" : "km/h",
                           rideLayout.heroUnit);
  if (model.usesWorkout) {
    setMetricTitleIfChanged(rideHeartRate.title,
                             ended ? "Average HR" : "Heart rate",
                             rideMetricPlacement.heartRate);
  }

  char value[24];
  if (ended) {
    ride_telemetry_presenter::formatAverageSpeed(model, value, sizeof(value));
  } else {
    ride_telemetry_presenter::formatSpeed(model, value, sizeof(value));
  }
  setMetricValueIfChanged(rideSpeedValue, value, rideLayout.hero,
                           ride_metric_typography::Role::Hero);
  if (model.usesWorkout) {
    updateHeartRateMetric(model);
    updateZoneMetric(model);
  }
  ride_telemetry_presenter::formatDistance(model.distanceMeters, value,
                                           sizeof(value));
  setMetricValueIfChanged(rideDistance.value, value,
                           metricValueRect(rideMetricPlacement.distance),
                           metricFontRole());
  ride_telemetry_presenter::formatElapsed(model.elapsedSeconds, value,
                                          sizeof(value));
  setMetricValueIfChanged(rideMoving.value, value,
                           metricValueRect(rideMetricPlacement.elapsed),
                           metricFontRole());

  const ride_telemetry_presenter::BottomMetricSelection bottomMetrics =
      ride_telemetry_presenter::selectBottomMetrics(model);
  const lv_font_t *bottomPairFont = nullptr;
  if (bottomMetrics.right == ride_telemetry_presenter::BottomMetric::Altitude &&
      model.altitudeMeters.available) {
    char leftText[24];
    char rightText[24];
    ride_telemetry_presenter::formatBottomMetric(
        bottomMetrics.left, model, leftText, sizeof(leftText));
    ride_telemetry_presenter::formatBottomMetric(
        bottomMetrics.right, model, rightText, sizeof(rightText));
    const auto leftRect = metricValueRect(rideMetricPlacement.bottomLeft);
    const auto rightRect = metricValueRect(rideMetricPlacement.bottomRight);
    if (std::strcmp(leftText, "--") != 0)
      bottomPairFont = ride_metric_typography::fontForPair(
          {leftText, leftRect.width - 4, leftRect.height},
          {rightText, rightRect.width - 4, rightRect.height}, metricFontRole());
  }
  updateBottomMetric(rideBottomLeft, bottomMetrics.left, model,
                       rideMetricPlacement.bottomLeft, bottomPairFont);
  updateBottomMetric(rideBottomRight, bottomMetrics.right, model,
                       rideMetricPlacement.bottomRight, bottomPairFont);
  updateAutomationPanel(millis());
}
