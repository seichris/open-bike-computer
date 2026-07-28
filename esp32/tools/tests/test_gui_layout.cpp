#include "../../lib/gui/src/batteryStatusLayout.hpp"
#include "../../lib/gui/src/destinationPickerLayout.hpp"
#include "../../lib/gui/src/guiLayout.hpp"
#include "../../lib/gui/src/mapTileTransition.hpp"
#include "../../lib/gui/src/rideMetricFontSelection.hpp"
#include "../../lib/gui/src/rideTelemetryLayout.hpp"
#include "../../lib/maps/src/mapLineStyle.hpp"

#include <cassert>

int main() {
  map_tile_transition::State mapTransition;
  assert(!mapTransition.canReveal(false, false));
  mapTransition.begin();
  assert(!mapTransition.canReveal(true, true));
  assert(!mapTransition.canReveal(true, false));
  assert(!mapTransition.canReveal(false, true));
  assert(mapTransition.canReveal(false, false));
  mapTransition.complete();
  assert(!mapTransition.canReveal(false, false));
  mapTransition.begin();
  mapTransition.cancel();
  assert(!mapTransition.canReveal(false, false));

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
  constexpr auto workoutMetrics =
      ride_telemetry_layout::makeMetricPlacement(
          rideLayout,
          ride_telemetry_layout::MetricLayoutMode::Workout);
  static_assert(workoutMetrics.showWorkoutOnlyMetrics);
  static_assert(workoutMetrics.showBottomMetrics);
  static_assert(!workoutMetrics.showStartWorkoutButton);
  static_assert(workoutMetrics.heartRate.x == rideLayout.metrics[0].x);
  static_assert(workoutMetrics.heartRateZone.x == rideLayout.metrics[1].x);
  static_assert(workoutMetrics.distance.y == rideLayout.metrics[2].y);
  static_assert(workoutMetrics.elapsed.y == rideLayout.metrics[3].y);
  constexpr auto navigationMetrics =
      ride_telemetry_layout::makeMetricPlacement(
          rideLayout,
          ride_telemetry_layout::MetricLayoutMode::NavigationOnly);
  static_assert(!navigationMetrics.showWorkoutOnlyMetrics);
  static_assert(navigationMetrics.showBottomMetrics);
  static_assert(navigationMetrics.showStartWorkoutButton);
  static_assert(navigationMetrics.distance.x == rideLayout.metrics[0].x);
  static_assert(navigationMetrics.distance.y == rideLayout.metrics[0].y);
  static_assert(navigationMetrics.elapsed.x == rideLayout.metrics[1].x);
  static_assert(navigationMetrics.elapsed.y == rideLayout.metrics[1].y);
  static_assert(navigationMetrics.bottomLeft.y == rideLayout.metrics[2].y);
  static_assert(navigationMetrics.bottomRight.y == rideLayout.metrics[3].y);
  static_assert(navigationMetrics.bottomLeft.y -
                    navigationMetrics.distance.bottom() ==
                ride_telemetry_layout::kMetricRowGap);
  static_assert(navigationMetrics.startWorkoutButton.y -
                    navigationMetrics.bottomLeft.bottom() ==
                ride_telemetry_layout::kStartWorkoutButtonGap);
  constexpr auto idleMetrics =
      ride_telemetry_layout::makeMetricPlacement(
          rideLayout, ride_telemetry_layout::MetricLayoutMode::Idle);
  static_assert(!idleMetrics.showWorkoutOnlyMetrics);
  static_assert(!idleMetrics.showBottomMetrics);
  static_assert(idleMetrics.showStartWorkoutButton);
  static_assert(idleMetrics.distance.y == rideLayout.metrics[0].y);
  static_assert(idleMetrics.elapsed.y == rideLayout.metrics[1].y);
  static_assert(idleMetrics.startWorkoutButton.y -
                    idleMetrics.distance.bottom() ==
                ride_telemetry_layout::kStartWorkoutButtonGap);
  static_assert(ride_telemetry_layout::fits(
      navigationMetrics.startWorkoutButton, rideLayout.screenWidth,
      rideLayout.screenHeight));
  static_assert(ride_telemetry_layout::fits(
      idleMetrics.startWorkoutButton, rideLayout.screenWidth,
      rideLayout.screenHeight));
  constexpr int32_t representativeHeartRateTextWidth = 100;
  const auto unavailableHeartRate =
      ride_telemetry_layout::makeHeartRatePresentation(
          rideLayout.metrics[0], rideLayout.screenWidth, false);
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
            rideLayout.metrics[0], rideLayout.screenWidth, available);
    assert(presentation.showHeart == available);
    assert(presentation.fontTier == unavailableHeartRate.fontTier);
    assert(presentation.maximumValueWidth ==
           unavailableHeartRate.maximumValueWidth);
    assert(presentation.fontSelectionWidth ==
           unavailableHeartRate.fontSelectionWidth);
    assert(presentation.unavailableValue.x == rideLayout.metrics[0].x);
    assert(presentation.unavailableValue.width ==
           rideLayout.metrics[0].width);
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
  const std::array<ride_metric_font_selection::Candidate, 3>
      ordinaryHeartRateCandidates = {{{100, true}, {90, true}, {80, true}}};
  for (int heartRateBpm : {157, 158, 158, 159}) {
    (void)heartRateBpm;
    assert(ride_metric_font_selection::firstFittingIndex(
               ordinaryHeartRateCandidates,
               unavailableHeartRate.fontSelectionWidth) == 0);
  }
#if defined(WAVESHARE_AMOLED_206)
  const std::array<ride_metric_font_selection::Candidate, 4>
      maximumAcceptedHeartRateCandidates =
          {{{126, true}, {114, true}, {72, true}, {54, true}}};
#else
  const std::array<ride_metric_font_selection::Candidate, 7>
      maximumAcceptedHeartRateCandidates = {{{198, true}, {168, true},
                                              {145, true}, {126, true},
                                              {114, true}, {72, true},
                                              {54, true}}};
#endif
  const std::size_t maximumAcceptedHeartRateFont =
      ride_metric_font_selection::firstFittingIndex(
          maximumAcceptedHeartRateCandidates,
          unavailableHeartRate.fontSelectionWidth);
#if defined(WAVESHARE_AMOLED_206)
  assert(maximumAcceptedHeartRateFont == 0);
#else
  assert(maximumAcceptedHeartRateFont == 2);
#endif
  assert(maximumAcceptedHeartRateCandidates[maximumAcceptedHeartRateFont]
             .width <= unavailableHeartRate.fontSelectionWidth);
  const auto maximumHeartRateLayout =
      ride_telemetry_layout::makeHeartRateValueLayout(
          rideLayout.metrics[0], rideLayout.screenWidth,
          maximumAcceptedHeartRateCandidates[maximumAcceptedHeartRateFont]
              .width);
  assert(maximumHeartRateLayout.value.right() +
             maximumHeartRateLayout.gap ==
         maximumHeartRateLayout.heart.x);
  assert(maximumHeartRateLayout.heart.right() <=
         rideLayout.metrics[0].right());
  using ride_telemetry_layout::ZoneUpdateAction;
  int8_t displayedZone = -2;
  auto zonePresentation = ride_telemetry_layout::makeZonePresentation(
      rideLayout.metrics[1], rideLayout.screenWidth, displayedZone, -1);
  assert(zonePresentation.update.action == ZoneUpdateAction::Hide);
  assert(!zonePresentation.heartVisible);
  assert(!zonePresentation.labelVisible);
  for (bool visible : zonePresentation.segmentVisible) {
    assert(!visible);
  }
  displayedZone = zonePresentation.update.zoneIndex;
  for (int8_t nextZone : {int8_t{0}, int8_t{0}, int8_t{4}, int8_t{-1}}) {
    zonePresentation = ride_telemetry_layout::makeZonePresentation(
        rideLayout.metrics[1], rideLayout.screenWidth, displayedZone,
        nextZone);
    if (nextZone == displayedZone) {
      assert(zonePresentation.update.action == ZoneUpdateAction::None);
      continue;
    }
    if (nextZone < 0) {
      assert(zonePresentation.update.action == ZoneUpdateAction::Hide);
      assert(!zonePresentation.heartVisible);
      assert(!zonePresentation.labelVisible);
      for (bool visible : zonePresentation.segmentVisible) {
        assert(!visible);
      }
    } else {
      assert(zonePresentation.update.action == ZoneUpdateAction::Show);
      assert(zonePresentation.heartVisible);
      assert(zonePresentation.labelVisible);
      assert(zonePresentation.labelZoneNumber == nextZone + 1);
      assert(zonePresentation.labelText[0] == 'Z');
      assert(zonePresentation.labelText[5] == '1' + nextZone);
      assert(zonePresentation.labelText[6] == '\0');
      assert(zonePresentation.foregroundColor ==
             ride_telemetry_layout::zoneForegroundColorHex(nextZone));
      for (std::size_t index = 0;
           index < ride_telemetry_layout::kHeartRateZoneCount; ++index) {
        assert(zonePresentation.segmentVisible[index]);
        assert(zonePresentation.segmentColors[index] ==
               ride_telemetry_layout::zoneColorHex(
                   index, index == static_cast<std::size_t>(nextZone)));
      }
      assert(zonePresentation.segments[nextZone].width >
             zonePresentation.segments[(nextZone + 1) % 5].width);
      assert(zonePresentation.heart.x >=
             zonePresentation.segments[nextZone].x);
      assert(zonePresentation.label.right() <=
             zonePresentation.segments[nextZone].right());
    }
    displayedZone = zonePresentation.update.zoneIndex;
  }
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
