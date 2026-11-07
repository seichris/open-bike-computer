#if defined(WAVESHARE_EPAPER_397)
/**
 * @file rideStatsEpaper.cpp
 * @brief The 3.97-inch e-paper's Ride Stats slots: the e-paper widget set
 *        (zone ranges, fixed captions), one font box per cell and a sign
 *        column, so no glyph moves between waveforms.
 */

#include "rideStatsFamily.hpp"

#include "epaperRideStats.hpp"
#include "rideMetricTypography.hpp"
#include "rideTelemetryText.hpp"

#include <algorithm>
#include <cstring>

namespace ride_stats_family {

Presentation make(Widget widget, const Model &model) {
  return epaper_ride_stats::make(widget, model);
}

bool unitInTitle(std::size_t) { return true; }

lv_obj_t *createSign(lv_obj_t *page) {
  lv_obj_t *sign = lv_label_create(page);
  lv_obj_set_style_text_color(sign, lv_color_white(), 0);
  return sign;
}

ValueFonts valueFonts(const Presentations &,
                      const ride_telemetry_layout::Layout &) {
  return {};
}

void presentValue(const SlotObjects &slot, std::size_t index,
                  const Presentation &widget, Widget layoutSlot,
                  const Model &model,
                  const ride_telemetry_layout::Layout &rideLayout,
                  const ride_telemetry_layout::Rect &rect,
                  const lv_font_t *sharedFont) {
  (void)rect;
  (void)sharedFont;
  const auto cell = ride_telemetry_layout::configurableValueRect(rideLayout, index);
  const bool heart = widget.kind == ride_stats_widget::PresentationKind::HeartWithValue;
  const auto heartSize = ride_telemetry_layout::heartRateHeartSize(rideLayout.screenWidth);
  const auto heartGap = ride_telemetry_layout::heartRateHeartGap(rideLayout.screenWidth);
  const int32_t heartBlock = heart ? heartSize + heartGap : 0;
  const auto role = epaper_ride_stats::isZoneRange(layoutSlot)
      ? ride_metric_typography::Role::Zone
      : index == 0 ? ride_metric_typography::Role::Hero : metricFontRole();
  const char *format = epaper_ride_stats::maximumFormat(layoutSlot, model);
  const auto *font = ride_metric_typography::fontForText(
      format, cell.width - heartBlock - 4 - (widget.isAltitude ? 8 : 0),
      cell.height, role);
  // One box fits the widest supported format. Centre it, with the altitude
  // sign column and heart icon, under the centred title. Every position
  // depends only on the widget and its font, never on the live value.
  const int32_t signWidth =
      widget.isAltitude && font ? lv_text_get_width("-", 1, font, 0) : 0;
  const int32_t signBlock = signWidth ? signWidth + 8 : 0;
  const char *digits = widget.isAltitude && format[0] == '-' ? format + 1 : format;
  int32_t valueWidth = cell.width - heartBlock - signBlock;
  if (font)
    valueWidth = std::min<int32_t>(
        valueWidth, lv_text_get_width(digits, std::strlen(digits), font, 0) + 4);
  const int32_t left =
      cell.x + std::max<int32_t>(0, (cell.width - signBlock - valueWidth - heartBlock) / 2);
  const ride_telemetry_layout::Rect value{left + signBlock, cell.y, valueWidth, cell.height};
  if (heart) {
    lv_obj_set_pos(slot.heart, value.right() + heartGap,
                    value.y + (value.height - heartSize) / 2);
    lv_obj_set_size(slot.heart, heartSize, heartSize);
    if (widget.available) lv_obj_clear_flag(slot.heart, LV_OBJ_FLAG_HIDDEN);
  }
  const char *text = widget.value.data();
  if (signBlock) {
    // Reserve a sign column even when the value is positive or unavailable.
    // Neither the sign nor the digits move when crossing zero.
    const ride_telemetry_layout::Rect signRect{left, cell.y, signWidth, cell.height};
    const bool negative = widget.available && text[0] == '-' && text[1] != '-';
    applyMetricText(slot.sign, negative ? "-" : "", signRect, font,
                    LV_TEXT_ALIGN_LEFT);
    lv_obj_clear_flag(slot.sign, LV_OBJ_FLAG_HIDDEN);
    if (negative) ++text;
  }
  // Unexpected/unsupported values fail closed; never silently clip or
  // resize a live cell. Availability does not change its font or anchor.
  if (font && (!ride_metric_typography::supportsText(font, text) ||
      lv_text_get_width(text, std::strlen(text), font, 0) > value.width - 4))
    text = "--";
  applyMetricText(slot.value, text, value, font, LV_TEXT_ALIGN_RIGHT);
}

}  // namespace ride_stats_family
#endif
