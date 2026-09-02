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

  for (const auto dimensions : {
           std::pair<int32_t, int32_t>{466, 466},
           std::pair<int32_t, int32_t>{410, 502}}) {
    const auto layout = ride_telemetry_layout::makeLayout(
        dimensions.first, dimensions.second);
    assert(ride_telemetry_layout::isValid(layout));
    assert(ride_telemetry_layout::fits(
        layout.hero, dimensions.first, dimensions.second));
    for (std::size_t index = 0;
         index < ride_telemetry_layout::kConfigurableSlotCount; ++index) {
      const auto slot =
          ride_telemetry_layout::configurableSlotRect(layout, index);
      assert(ride_telemetry_layout::fits(
          slot, dimensions.first, dimensions.second));
      assert(slot.width >=
             (index == 0 ? dimensions.first : (dimensions.first - 48) / 2));
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
    for (std::size_t active = 0;
         active < ride_telemetry_layout::kHeartRateZoneCount; ++active) {
      for (std::size_t index = 0;
           index < ride_telemetry_layout::kConfigurableSlotCount; ++index) {
        const auto slot =
            ride_telemetry_layout::configurableSlotRect(layout, index);
        const auto strip = ride_telemetry_layout::makeZoneStripLayout(
            slot, dimensions.first, active);
        assert(ride_telemetry_layout::fits(
            strip.bounds, dimensions.first, dimensions.second));
      }
    }
  }
  return 0;
}
