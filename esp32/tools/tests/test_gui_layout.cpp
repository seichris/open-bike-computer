#include "../../lib/gui/src/batteryStatusLayout.hpp"
#include "../../lib/gui/src/destinationPickerLayout.hpp"
#include "../../lib/gui/src/guiLayout.hpp"
#include "../../lib/gui/src/rideMetricFontSelection.hpp"
#include "../../lib/gui/src/rideTelemetryLayout.hpp"
#include "../../lib/maps/src/mapLineStyle.hpp"

#include <cassert>

int main() {
#if defined(WAVESHARE_AMOLED_206)
  // 2.06-inch viewport: 502px screen with 72px reserved UI space.
  assert(gui_layout::mapViewportHeight(502) == 430);
  assert(gui_layout::mapScreenAnchorX(410, 410) == 205);
  assert(gui_layout::mapScreenAnchorY(502, 430) == 251);
  assert(gui_layout::mapScreenAnchorY(502, 502) == 251);
  constexpr auto rideLayout = ride_telemetry_layout::makeLayout(410, 502);
  constexpr auto batteryLayout = battery_status_layout::makeLayout(410, 502);
  static_assert(!ride_telemetry_layout::useLargeMetricValueFont(
      rideLayout.screenWidth));
#else
  // 1.75-inch viewport: 466px screen with 100px reserved UI space.
  assert(gui_layout::mapViewportHeight(466) == 366);
  assert(gui_layout::mapScreenAnchorX(466, 466) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 366) == 233);
  assert(gui_layout::mapScreenAnchorY(466, 466) == 233);
  constexpr auto rideLayout = ride_telemetry_layout::makeLayout(466, 466);
  constexpr auto batteryLayout = battery_status_layout::makeLayout(466, 466);
  static_assert(ride_telemetry_layout::useLargeMetricValueFont(
      rideLayout.screenWidth));
#endif
  static_assert(batteryLayout.topMargin == batteryLayout.bottomMargin);
  assert(batteryLayout.deviceY == batteryLayout.topMargin);
  assert(batteryLayout.phoneY + batteryLayout.diameter +
             batteryLayout.bottomMargin ==
         rideLayout.screenHeight);
  assert(batteryLayout.gap >= 16);
  assert(batteryLayout.gap <= 36);
  static_assert(destination_picker_layout::rowHeightForText(54) == 88);
  static_assert(destination_picker_layout::rowHeightForText(108) == 116);
  static_assert(destination_picker_layout::bottomPadding(466, 466, 3) ==
                186);
  static_assert(destination_picker_layout::bottomPadding(410, 502, 3) == 4);
  static_assert(!destination_picker_layout::needsScrolling(88 * 3, 3, 280));
  static_assert(destination_picker_layout::needsScrolling(116 * 3, 3, 280));
  static_assert(map_line_style::displayColor(1, 0xF567, 7, false) ==
                0xF567);
  static_assert(map_line_style::displayColor(1, 0xF567, 7, true) ==
                map_line_style::kWhiteRgb565);
  static_assert(map_line_style::displayColor(10, 0xFFF1, 3, true) ==
                map_line_style::kWhiteRgb565);
  static_assert(map_line_style::displayColor(51, 0xF567, 3, true) ==
                0xF567);
  static_assert(map_line_style::displayColor(0, 0xF567, 5, true) ==
                map_line_style::kWhiteRgb565);
  static_assert(map_line_style::displayColor(0, 0xA6DE, 2, true) ==
                0xA6DE);
  static_assert(ride_telemetry_layout::isValid(rideLayout));
  assert(rideLayout.metrics.size() == 6);
  assert(rideLayout.heroUnit.bottom() == rideLayout.metrics[0].y);
  assert(rideLayout.metrics[0].right() <= rideLayout.metrics[1].x);
  for (std::size_t row = 0; row + 1 < 3; ++row) {
    assert(rideLayout.metrics[(row + 1) * 2].y -
               rideLayout.metrics[row * 2].bottom() ==
           ride_telemetry_layout::kMetricRowGap);
  }
  for (const auto &metric : rideLayout.metrics) {
    assert(ride_telemetry_layout::fits(
        metric, rideLayout.screenWidth, rideLayout.screenHeight));
  }
  for (std::size_t activeIndex = 0;
       activeIndex < ride_telemetry_layout::kHeartRateZoneCount;
       ++activeIndex) {
    const auto zoneStrip = ride_telemetry_layout::makeZoneStripLayout(
        rideLayout.metrics[1], rideLayout.screenWidth, activeIndex);
    assert(zoneStrip.bounds.x == rideLayout.metrics[1].x);
    assert(zoneStrip.bounds.right() == rideLayout.metrics[1].right());
    assert(zoneStrip.bounds.y >= rideLayout.metrics[1].y +
                                     ride_telemetry_layout::kMetricValueOffsetY);
    assert(zoneStrip.bounds.bottom() <= rideLayout.metrics[1].bottom());
    assert(zoneStrip.segments.front().x == zoneStrip.bounds.x);
    assert(zoneStrip.segments.back().right() == zoneStrip.bounds.right());
    for (std::size_t index = 0; index < zoneStrip.segments.size(); ++index) {
      const auto &segment = zoneStrip.segments[index];
      assert(segment.y == zoneStrip.bounds.y);
      assert(segment.height == zoneStrip.bounds.height);
      assert(segment.width > 0);
      if (index == activeIndex) {
        assert(segment.width >
               zoneStrip.segments[(index + 1) %
                                  zoneStrip.segments.size()]
                   .width);
        assert(zoneStrip.heart.x >= segment.x);
        assert(zoneStrip.label.right() <= segment.right());
        assert(zoneStrip.label.width >= 58);
      }
      if (index + 1 < zoneStrip.segments.size()) {
        assert(segment.right() + ride_telemetry_layout::kZoneStripGap ==
               zoneStrip.segments[index + 1].x);
      }
    }
  }
  return 0;
}
