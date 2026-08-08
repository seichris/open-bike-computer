/**
 * @file rideTelemetryScr.cpp
 * @brief Adaptive Watch workout and legacy GPS ride telemetry screen.
 */

#include "rideTelemetryScr.hpp"
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../ble_navigation/workout_telemetry_runtime.hpp"
#include "bikeIcon.hpp"
#include "gps.hpp"
#include "rideMetricFontSelection.hpp"
#include "rideTelemetryLayout.hpp"
#include "rideTelemetryPresenter.hpp"
#include "ride_automation_runtime.hpp"

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
MetricLabels rideHeartRate{};
lv_obj_t *rideHeartRateHeart = nullptr;
lv_obj_t *rideZoneTitle = nullptr;
lv_obj_t *rideDistanceValue = nullptr;
MetricLabels rideMoving{};
std::array<lv_obj_t *, ride_telemetry_layout::kHeartRateZoneCount>
    rideZoneSegments{};
lv_obj_t *rideZoneHeart = nullptr;
lv_obj_t *rideZoneLabel = nullptr;
int8_t displayedZoneIndex = -2;
MetricLabels rideBottomLeft{};
MetricLabels rideBottomRight{};
lv_obj_t *rideStartWorkoutButton = nullptr;
lv_obj_t *rideAutomationPanel = nullptr;
lv_obj_t *rideAutomationTitle = nullptr;
lv_obj_t *rideAutomationDetail = nullptr;
lv_obj_t *rideAutomationProgress = nullptr;
lv_obj_t *rideAutomationActions = nullptr;
ride_telemetry_layout::Layout rideLayout{};
ride_telemetry_layout::MetricPlacement rideMetricPlacement{};
int8_t displayedMetricLayout = -1;

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

const lv_font_t *metricValueFontForWidth(const char *text,
                                         int32_t availableWidth,
                                         bool useLargeFont) {
  const uint32_t textLength = static_cast<uint32_t>(std::strlen(text));

  if (useLargeFont) {
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

const lv_font_t *metricValueFont(lv_obj_t *label, const char *text) {
  return metricValueFontForWidth(
      text, lv_obj_get_width(label) - 4,
      ride_telemetry_layout::useLargeMetricValueFont(
          rideLayout.screenWidth));
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
  const ride_telemetry_layout::ZonePresentation presentation =
      ride_telemetry_layout::makeZonePresentation(
          rideMetricPlacement.heartRateZone, rideLayout.screenWidth,
          displayedZoneIndex,
          ride_telemetry_presenter::fiveZoneIndex(model));
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
  }

  lv_obj_set_pos(rideZoneLabel, presentation.label.x,
                 presentation.label.y);
  lv_obj_set_size(rideZoneLabel, presentation.label.width,
                  presentation.label.height);
  lv_obj_set_style_text_color(rideZoneLabel, foreground, 0);
  setLabelIfChanged(rideZoneLabel, presentation.labelText.data());
  if (presentation.labelVisible) {
    lv_obj_clear_flag(rideZoneLabel, LV_OBJ_FLAG_HIDDEN);
  }
}

void updateHeartRateMetric(
    const ride_telemetry_presenter::ViewModel &model) {
  const ride_telemetry_layout::Rect &metric = rideMetricPlacement.heartRate;
  char value[24];
  ride_telemetry_presenter::formatInteger(model.currentHeartRateBpm, value,
                                          sizeof(value));
  const ride_telemetry_layout::HeartRatePresentation presentation =
      ride_telemetry_layout::makeHeartRatePresentation(
          metric, rideLayout.screenWidth,
          model.currentHeartRateBpm.available);

  if (!presentation.showHeart) {
    lv_obj_set_pos(rideHeartRate.value, presentation.unavailableValue.x,
                   presentation.unavailableValue.y);
    lv_obj_set_width(rideHeartRate.value,
                     presentation.unavailableValue.width);
    lv_obj_set_style_text_align(rideHeartRate.value, LV_TEXT_ALIGN_CENTER, 0);
    setMetricValueIfChanged(rideHeartRate.value, value);
    lv_obj_add_flag(rideHeartRateHeart, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  lv_obj_set_width(rideHeartRate.value, presentation.maximumValueWidth);
  // Select against the stable maximum width, not the tightly measured label
  // width from the previous refresh. Ordinary heart rates therefore keep the
  // normal metric size, while anomalous protocol-valid values still shrink
  // enough to remain fully visible beside the heart.
  const lv_font_t *font = metricValueFontForWidth(
      value, presentation.fontSelectionWidth,
      presentation.fontTier ==
          ride_telemetry_layout::MetricValueFontTier::RegularLarge);
  if (lv_obj_get_style_text_font(rideHeartRate.value, LV_PART_MAIN) != font) {
    lv_obj_set_style_text_font(rideHeartRate.value, font, 0);
  }
  setLabelIfChanged(rideHeartRate.value, value);
  const int32_t textWidth = lv_text_get_width(
      value, static_cast<uint32_t>(std::strlen(value)), font, 0);
  const ride_telemetry_layout::ValueWithHeartLayout layout =
      ride_telemetry_layout::makeHeartRateValueLayout(
          metric, rideLayout.screenWidth, textWidth);

  lv_obj_set_pos(rideHeartRate.value, layout.value.x, layout.value.y);
  lv_obj_set_width(rideHeartRate.value, layout.value.width);
  lv_obj_set_style_text_align(rideHeartRate.value, LV_TEXT_ALIGN_LEFT, 0);

  lv_obj_set_pos(rideHeartRateHeart, layout.heart.x, layout.heart.y);
  lv_obj_set_size(rideHeartRateHeart, layout.heart.width,
                  layout.heart.height);
  lv_obj_set_style_text_color(rideHeartRateHeart, lv_color_hex(0xFF3B30), 0);
  lv_obj_clear_flag(rideHeartRateHeart, LV_OBJ_FLAG_HIDDEN);
}

void positionMetric(MetricLabels labels,
                    const ride_telemetry_layout::Rect &rect) {
  if (labels.title != nullptr) {
    lv_obj_set_width(labels.title, rect.width);
    lv_obj_set_pos(labels.title, rect.x, rect.y);
  }
  if (labels.value != nullptr) {
    lv_obj_set_width(labels.value, rect.width);
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

void startWorkoutEvent(lv_event_t *event) {
  if (lv_event_get_code(event) == LV_EVENT_CLICKED) {
    bleNavServer.requestWorkoutStart();
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
  if (snapshot.phase == ride_automation_runtime::UiPhase::Hidden) {
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
    title = "Detection limited";
    detail = "Waiting for GPS + motion, or a direct cycling sensor.";
    borderColor = 0xFFCC55;
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
  const ride_telemetry_layout::MetricLayoutMode mode = metricLayoutMode(model);
  const int8_t nextLayout = static_cast<int8_t>(mode);
  if (displayedMetricLayout == nextLayout) {
    return;
  }
  displayedMetricLayout = nextLayout;
  rideMetricPlacement =
      ride_telemetry_layout::makeMetricPlacement(rideLayout, mode);
  setLabelIfChanged(rideMoving.title,
                    model.usesWorkout ? "Moving" : "Elapsed");

  positionMetric(rideHeartRate, rideMetricPlacement.heartRate);
  positionMetric({rideZoneTitle, rideZoneLabel},
                 rideMetricPlacement.heartRateZone);
  positionMetric({nullptr, rideDistanceValue}, rideMetricPlacement.distance);
  positionMetric(rideMoving, rideMetricPlacement.elapsed);
  positionMetric(rideBottomLeft, rideMetricPlacement.bottomLeft);
  positionMetric(rideBottomRight, rideMetricPlacement.bottomRight);
  lv_obj_set_pos(rideStartWorkoutButton,
                 rideMetricPlacement.startWorkoutButton.x,
                 rideMetricPlacement.startWorkoutButton.y);
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
    lv_obj_add_flag(rideStartWorkoutButton, LV_OBJ_FLAG_HIDDEN);
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
  lv_obj_clear_flag(rideStartWorkoutButton, LV_OBJ_FLAG_HIDDEN);
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

  rideHeartRate =
      createMetric(ridePage, "Heart rate", rideLayout.metrics[0]);
  rideHeartRateHeart = createHeartIcon(ridePage);
  createZoneMetric(ridePage, rideLayout.metrics[1]);
  rideDistanceValue =
      createMetric(ridePage, "Distance", rideLayout.metrics[2]).value;
  rideMoving = createMetric(ridePage, "Moving", rideLayout.metrics[3]);
  rideBottomLeft =
      createMetric(ridePage, "Altitude m", rideLayout.metrics[4]);
  rideBottomRight =
      createMetric(ridePage, "Route left", rideLayout.metrics[5]);

  rideStartWorkoutButton = lv_btn_create(ridePage);
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
  lv_obj_add_event_cb(rideStartWorkoutButton, startWorkoutEvent,
                      LV_EVENT_CLICKED, nullptr);
  bike_icon::create(
      rideStartWorkoutButton,
      useRoundStartWorkoutContent
          ? ride_telemetry_layout::kRoundStartWorkoutIconSize
          : ride_telemetry_layout::kStartWorkoutIconSize,
      0x000000);
  lv_obj_t *startWorkoutLabel = lv_label_create(rideStartWorkoutButton);
  lv_obj_set_style_text_font(
      startWorkoutLabel,
      useRoundStartWorkoutContent ? &lv_font_montserrat_24
                                  : &lv_font_montserrat_18,
      0);
  lv_obj_set_style_text_color(startWorkoutLabel, lv_color_black(), 0);
  lv_label_set_text_static(startWorkoutLabel, "Start Workout");

  createAutomationPanel(ridePage);

  displayedMetricLayout = -1;
  updateRideTelemetryEvent(nullptr);
}

void updateRideTelemetryEvent(lv_event_t *) {
  const ride_telemetry_presenter::ViewModel model = currentViewModel();
  updateMetricLayout(model);
  if (rideMetricPlacement.showStartWorkoutButton) {
    if (bleNavServer.canRequestWorkoutStart()) {
      lv_obj_clear_state(rideStartWorkoutButton, LV_STATE_DISABLED);
    } else {
      lv_obj_add_state(rideStartWorkoutButton, LV_STATE_DISABLED);
    }
  }
  updateStatusLabel(rideStatus, model);

  char value[24];
  ride_telemetry_presenter::formatSpeed(model, value, sizeof(value));
  setLabelIfChanged(rideSpeedValue, value);
  if (model.usesWorkout) {
    updateHeartRateMetric(model);
    updateZoneMetric(model);
  }
  ride_telemetry_presenter::formatDistance(model.distanceMeters, value,
                                           sizeof(value));
  setMetricValueIfChanged(rideDistanceValue, value);
  ride_telemetry_presenter::formatElapsed(model.elapsedSeconds, value,
                                          sizeof(value));
  setMetricValueIfChanged(rideMoving.value, value);

  const ride_telemetry_presenter::BottomMetricSelection bottomMetrics =
      ride_telemetry_presenter::selectBottomMetrics(model);
  updateBottomMetric(rideBottomLeft, bottomMetrics.left, model);
  updateBottomMetric(rideBottomRight, bottomMetrics.right, model);
  updateAutomationPanel(millis());
}
