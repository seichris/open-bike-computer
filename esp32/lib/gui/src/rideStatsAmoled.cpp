#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
/**
 * @file rideStatsAmoled.cpp
 * @brief The AMOLED family's Ride Stats slots: the shared widget set, fonts
 *        paired across the metric columns, heart and scalar value cells.
 */

#include "rideStatsFamily.hpp"

#include "rideMetricTypography.hpp"
#include "rideTelemetryText.hpp"

namespace ride_stats_family {

Presentation make(Widget widget, const Model &model) {
  return ride_stats_widget::make(widget, model);
}

bool unitInTitle(std::size_t index) { return index == 0; }

lv_obj_t *createSign(lv_obj_t *) { return nullptr; }

ValueFonts valueFonts(const Presentations &widgets,
                      const ride_telemetry_layout::Layout &rideLayout) {
  ValueFonts sharedFonts{};
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
  return sharedFonts;
}

void presentValue(const SlotObjects &slot, std::size_t index,
                  const Presentation &widget, Widget layoutSlot,
                  const Model &model,
                  const ride_telemetry_layout::Layout &rideLayout,
                  const ride_telemetry_layout::Rect &rect,
                  const lv_font_t *sharedFont) {
  (void)layoutSlot;
  (void)model;
  if (widget.kind == ride_stats_widget::PresentationKind::HeartWithValue) {
    setHeartValue(slot.value, slot.heart, widget.value.data(), rect,
                   widget.available, sharedFont);
  } else {
    setMetricValueIfChanged(
        slot.value, widget.value.data(),
        ride_telemetry_layout::configurableValueRect(rideLayout, index),
        index == 0 ? ride_metric_typography::Role::Hero : metricFontRole(),
        sharedFont);
  }
}

}  // namespace ride_stats_family
#endif
