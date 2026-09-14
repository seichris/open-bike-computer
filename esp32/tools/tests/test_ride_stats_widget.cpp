#include "../../lib/gui/src/ride_stats_widget.hpp"
#include "../../lib/gui/src/rideTelemetryLayout.hpp"

#include <cassert>
#include <cstring>

using screen_configuration_protocol::RideStatsWidget;

int main() {
  ride_telemetry_presenter::ViewModel model{};
  model.usesWorkout = true;
  model.sessionState = workout_telemetry_protocol::SessionState::Running;
  model.speedTenthsKmh = {true, 321};
  model.averageSpeedTenthsKmh = {true, 245};
  model.maximumSpeedTenthsKmh = {true, 499};
  model.currentHeartRateBpm = {true, 151};
  model.averageHeartRateBpm = {true, 142};
  model.currentHeartRateZone = {true, 4};
  model.heartRateZoneCount = {true, 5};
  model.distanceMeters = {true, 12345};
  model.elapsedSeconds = {true, 3723};
  model.wallElapsedSeconds = {true, 3900};
  model.altitudeMeters = {true, 88};
  model.routeRemainingMeters = {true, 9876};
  model.cyclingPowerWatts = {true, 0};
  model.cyclingCadenceTenthsRpm = {true, 875};
  model.activeEnergyTenthsKilocalorie = {true, 1234};

  for (RideStatsWidget widget : {
           RideStatsWidget::Speed, RideStatsWidget::HeartRate,
           RideStatsWidget::HeartRateZone, RideStatsWidget::Distance,
           RideStatsWidget::MovingTime, RideStatsWidget::ElapsedTime,
           RideStatsWidget::Altitude, RideStatsWidget::RouteRemaining,
           RideStatsWidget::Power, RideStatsWidget::Cadence,
           RideStatsWidget::AverageSpeed, RideStatsWidget::MaximumSpeed,
           RideStatsWidget::Calories, RideStatsWidget::AverageHeartRate,
           RideStatsWidget::SmartMetric1, RideStatsWidget::SmartMetric2}) {
    const auto presentation = ride_stats_widget::make(widget, model);
    assert(presentation.kind != ride_stats_widget::PresentationKind::Empty);
    assert(presentation.title[0] != '\0');
    assert(presentation.value[0] != '\0');
    assert(ride_stats_widget::maximumFormattedValueBytes(widget) <
           presentation.value.size());
  }
  const auto zeroPower =
      ride_stats_widget::make(RideStatsWidget::Power, model);
  assert(zeroPower.available);
  assert(std::strcmp(zeroPower.value.data(), "0") == 0);
  model.cyclingPowerWatts.available = false;
  const auto unavailablePower =
      ride_stats_widget::make(RideStatsWidget::Power, model);
  assert(!unavailablePower.available);
  assert(std::strcmp(unavailablePower.value.data(), "--") == 0);

  model.sessionState = workout_telemetry_protocol::SessionState::Ended;
  const auto endedSpeed =
      ride_stats_widget::make(RideStatsWidget::Speed, model);
  const auto endedHeart =
      ride_stats_widget::make(RideStatsWidget::HeartRate, model);
  assert(std::strcmp(endedSpeed.value.data(), "24.5") == 0);
  assert(std::strcmp(endedHeart.value.data(), "142") == 0);

  for (const auto &dimensions : {
           std::pair<int32_t, int32_t>{466, 466},
           std::pair<int32_t, int32_t>{410, 502}}) {
    const auto layout = ride_telemetry_layout::makeLayout(
        dimensions.first, dimensions.second);
    const bool round = ride_telemetry_layout::usesRoundScreenSafeArea(
        dimensions.first, dimensions.second);
    assert(ride_telemetry_layout::isValid(layout));
    assert(ride_telemetry_layout::fits(
        layout.hero, dimensions.first, dimensions.second));
    for (std::size_t index = 0;
         index < ride_telemetry_layout::kConfigurableSlotCount; ++index) {
      const auto slot =
          ride_telemetry_layout::configurableSlotRect(layout, index);
      const auto value =
          ride_telemetry_layout::configurableValueRect(layout, index);
      // Slot zero has a logical origin above the hero for heart/zone
      // adapters; its visible caption is below the value, not at slot.y.
      const ride_telemetry_layout::Rect title = index == 0
          ? layout.heroUnit
          : ride_telemetry_layout::Rect{
                slot.x, slot.y, slot.width,
                ride_telemetry_layout::kMetricTitleLineHeight};
      assert(ride_telemetry_layout::fits(
          slot, dimensions.first, dimensions.second));
      assert(ride_telemetry_layout::fits(
          value, dimensions.first, dimensions.second));
      assert(ride_telemetry_layout::fits(
          title, dimensions.first, dimensions.second));
      assert(value.width == slot.width);
      assert(value.height >= ride_telemetry_layout::metricValueLineHeight(
                                 dimensions.first));
      if (round) {
        // Full-square columns are deliberately not the round-board contract.
        assert(ride_telemetry_layout::cornersFitCircle(value, dimensions.first));
        assert(ride_telemetry_layout::cornersFitCircle(title, dimensions.first));
        assert(slot.width >= (index == 0 ? 230 : 150));
        if (index != 0)
          assert(ride_telemetry_layout::cornersFitCircle(slot, dimensions.first));
      } else {
        // Preserve the rectangular board's full-width hero and columns.
        assert(slot.width ==
               (index == 0 ? dimensions.first : (dimensions.first - 48) / 2));
      }
      const auto heart = ride_telemetry_layout::makeHeartRatePresentation(
          slot, dimensions.first, true);
      const auto heartLayout = ride_telemetry_layout::makeHeartRateValueLayout(
          slot, dimensions.first, heart.fontSelectionWidth);
      for (const auto &rect : {heartLayout.value, heartLayout.heart}) {
        assert(ride_telemetry_layout::fits(
            rect, dimensions.first, dimensions.second));
        if (round)
          assert(ride_telemetry_layout::cornersFitCircle(rect, dimensions.first));
      }
      for (RideStatsWidget widget : {
               RideStatsWidget::Speed, RideStatsWidget::HeartRate,
               RideStatsWidget::HeartRateZone, RideStatsWidget::Distance,
               RideStatsWidget::MovingTime, RideStatsWidget::ElapsedTime,
               RideStatsWidget::Altitude, RideStatsWidget::RouteRemaining,
               RideStatsWidget::Power, RideStatsWidget::Cadence,
               RideStatsWidget::AverageSpeed, RideStatsWidget::MaximumSpeed,
               RideStatsWidget::Calories, RideStatsWidget::AverageHeartRate,
               RideStatsWidget::SmartMetric1, RideStatsWidget::SmartMetric2}) {
        assert(ride_stats_widget::maximumFormattedValueBytes(widget) <= 15);
      }
    }
    if (round) {
      assert(layout.metrics[4].width < layout.metrics[2].width);
      assert(layout.metrics[4].x > layout.metrics[2].x);
      // This old lower-left cell fits the framebuffer but not the circle.
      const ride_telemetry_layout::Rect oldBottomLeft{12, 316, 209, 82};
      assert(ride_telemetry_layout::fits(
          oldBottomLeft, dimensions.first, dimensions.second));
      assert(!ride_telemetry_layout::cornersFitCircle(
          oldBottomLeft, dimensions.first));
    }
    for (std::size_t active = 0;
         active < ride_telemetry_layout::kHeartRateZoneCount; ++active) {
      for (std::size_t index = 0;
           index < ride_telemetry_layout::kConfigurableSlotCount; ++index) {
        const auto slot =
            ride_telemetry_layout::configurableSlotRect(layout, index);
        const auto strip = ride_telemetry_layout::makeZoneStripLayout(
            slot, dimensions.first, active);
        for (const auto &rect : {strip.bounds, strip.heart, strip.label}) {
          assert(ride_telemetry_layout::fits(
              rect, dimensions.first, dimensions.second));
          if (round)
            assert(ride_telemetry_layout::cornersFitCircle(rect, dimensions.first));
        }
        for (const auto &segment : strip.segments) {
          assert(segment.x >= strip.bounds.x &&
                 segment.right() <= strip.bounds.right());
          assert(segment.y == strip.bounds.y &&
                 segment.bottom() == strip.bounds.bottom());
        }
      }
    }
  }
  return 0;
}
