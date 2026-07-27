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
  constexpr int32_t representativeHeartRateTextWidth = 100;
  const auto unavailableHeartRate =
      ride_telemetry_layout::makeHeartRatePresentation(
          rideLayout.screenWidth, false);
  assert(!unavailableHeartRate.showHeart);
#if defined(WAVESHARE_AMOLED_206)
  assert(unavailableHeartRate.fontTier ==
         ride_telemetry_layout::MetricValueFontTier::RegularCompact);
#else
  assert(unavailableHeartRate.fontTier ==
         ride_telemetry_layout::MetricValueFontTier::RegularLarge);
#endif
  for (bool available : {true, true, true, false, true}) {
    const auto presentation =
        ride_telemetry_layout::makeHeartRatePresentation(
            rideLayout.screenWidth, available);
    assert(presentation.showHeart == available);
    assert(presentation.fontTier == unavailableHeartRate.fontTier);
  }
  const auto heartRate = ride_telemetry_layout::makeHeartRateValueLayout(
      rideLayout.metrics[0], rideLayout.screenWidth,
      representativeHeartRateTextWidth);
  assert(heartRate.value.x >= rideLayout.metrics[0].x);
  assert(heartRate.value.y >= rideLayout.metrics[0].y +
                                  ride_telemetry_layout::kMetricValueOffsetY);
  assert(heartRate.value.right() + heartRate.gap == heartRate.heart.x);
  assert(heartRate.heart.right() <= rideLayout.metrics[0].right());
  assert(heartRate.heart.bottom() <= rideLayout.metrics[0].bottom());
  assert(heartRate.heart.width ==
         ride_telemetry_layout::heartRateHeartSize(rideLayout.screenWidth));
  assert(heartRate.value.width == representativeHeartRateTextWidth);
  const int32_t maximumHeartRateTextWidth =
      rideLayout.metrics[0].width -
      ride_telemetry_layout::heartRateHeartSize(rideLayout.screenWidth) -
      ride_telemetry_layout::heartRateHeartGap(rideLayout.screenWidth) - 4;
  const std::array<ride_metric_font_selection::Candidate, 3>
      maximumAcceptedHeartRateCandidates = {{
          {maximumHeartRateTextWidth + 1, true},
          {maximumHeartRateTextWidth, true},
          {1, true},
      }};
  const std::size_t maximumAcceptedHeartRateFont =
      ride_metric_font_selection::firstFittingIndex(
          maximumAcceptedHeartRateCandidates, maximumHeartRateTextWidth);
  assert(maximumAcceptedHeartRateFont == 1);
  assert(maximumAcceptedHeartRateCandidates[maximumAcceptedHeartRateFont]
             .width <= maximumHeartRateTextWidth);
  using ride_telemetry_layout::ZoneUpdateAction;
  int8_t displayedZone = -2;
  auto zoneUpdate =
      ride_telemetry_layout::makeZoneUpdate(displayedZone, -1);
  assert(zoneUpdate.action == ZoneUpdateAction::Hide);
  displayedZone = zoneUpdate.zoneIndex;
  zoneUpdate = ride_telemetry_layout::makeZoneUpdate(displayedZone, 0);
  assert(zoneUpdate.action == ZoneUpdateAction::Show);
  displayedZone = zoneUpdate.zoneIndex;
  zoneUpdate = ride_telemetry_layout::makeZoneUpdate(displayedZone, 0);
  assert(zoneUpdate.action == ZoneUpdateAction::None);
  zoneUpdate = ride_telemetry_layout::makeZoneUpdate(displayedZone, 4);
  assert(zoneUpdate.action == ZoneUpdateAction::Show);
  displayedZone = zoneUpdate.zoneIndex;
  zoneUpdate = ride_telemetry_layout::makeZoneUpdate(displayedZone, -1);
  assert(zoneUpdate.action == ZoneUpdateAction::Hide);
  for (std::size_t activeIndex = 0;
       activeIndex < ride_telemetry_layout::kHeartRateZoneCount;
       ++activeIndex) {
    const auto zoneStrip = ride_telemetry_layout::makeZoneStripLayout(
        rideLayout.metrics[1], rideLayout.screenWidth, activeIndex);
    assert(ride_telemetry_layout::zoneColorHex(activeIndex, true) !=
           ride_telemetry_layout::zoneColorHex(activeIndex, false));
    assert(ride_telemetry_layout::zoneForegroundColorHex(activeIndex) ==
           (activeIndex == 2 || activeIndex == 3 ? 0x000000U : 0xFFFFFFU));
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
