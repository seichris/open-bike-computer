#pragma once

#include "../../ble_navigation/screen_configuration_protocol.hpp"
#include "rideTelemetryPresenter.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace ride_stats_widget {

using Widget = screen_configuration_protocol::RideStatsWidget;

enum class PresentationKind : uint8_t {
  Empty,
  Scalar,
  HeartWithValue,
  ZoneStrip,
};

struct Presentation {
  const char *title = "";
  const char *unit = "";
  PresentationKind kind = PresentationKind::Empty;
  bool available = false;
  int8_t zoneIndex = -1;
  std::array<char, 24> value{};
};

inline Presentation bottomMetric(
    ride_telemetry_presenter::BottomMetric metric,
    const ride_telemetry_presenter::ViewModel &model) {
  Presentation presentation{};
  presentation.kind = PresentationKind::Scalar;
  presentation.title = ride_telemetry_presenter::bottomMetricTitle(metric);
  ride_telemetry_presenter::formatBottomMetric(
      metric, model, presentation.value.data(), presentation.value.size());
  presentation.available = presentation.value[0] != '-' ||
                           presentation.value[1] != '-';
  return presentation;
}

inline Presentation make(Widget widget,
                         const ride_telemetry_presenter::ViewModel &model) {
  Presentation presentation{};
  const bool ended = model.usesWorkout &&
                     model.sessionState ==
                         workout_telemetry_protocol::SessionState::Ended;
  switch (widget) {
  case Widget::Empty:
    return presentation;
  case Widget::Speed:
    presentation.title = ended ? "Average speed" : "Speed";
    presentation.unit = "km/h";
    presentation.kind = PresentationKind::Scalar;
    if (ended) {
      ride_telemetry_presenter::formatAverageSpeed(
          model, presentation.value.data(), presentation.value.size());
      presentation.available = model.averageSpeedTenthsKmh.available;
    } else {
      ride_telemetry_presenter::formatSpeed(
          model, presentation.value.data(), presentation.value.size());
      presentation.available = model.speedTenthsKmh.available;
    }
    return presentation;
  case Widget::HeartRate: {
    presentation.title = ended ? "Average HR" : "Heart rate";
    presentation.unit = "bpm";
    presentation.kind = PresentationKind::HeartWithValue;
    const auto metric =
        ended ? model.averageHeartRateBpm : model.currentHeartRateBpm;
    ride_telemetry_presenter::formatInteger(
        metric, presentation.value.data(), presentation.value.size());
    presentation.available = metric.available;
    return presentation;
  }
  case Widget::HeartRateZone:
    presentation.title = "HR zone";
    presentation.kind = PresentationKind::ZoneStrip;
    presentation.zoneIndex = ride_telemetry_presenter::fiveZoneIndex(model);
    presentation.available = presentation.zoneIndex >= 0;
    std::snprintf(presentation.value.data(), presentation.value.size(), "%s",
                  presentation.available ? "ZONE" : "--");
    return presentation;
  case Widget::Distance:
    presentation.title = "Distance";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatDistance(
        model.distanceMeters, presentation.value.data(), presentation.value.size());
    presentation.available = model.distanceMeters.available;
    return presentation;
  case Widget::MovingTime:
    presentation.title = "Moving";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatElapsed(
        model.elapsedSeconds, presentation.value.data(), presentation.value.size());
    presentation.available = model.elapsedSeconds.available;
    return presentation;
  case Widget::ElapsedTime:
    presentation.title = "Elapsed";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatElapsed(
        model.wallElapsedSeconds, presentation.value.data(), presentation.value.size());
    presentation.available = model.wallElapsedSeconds.available;
    return presentation;
  case Widget::Altitude:
    presentation.title = "Altitude m";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatInteger(
        model.altitudeMeters, presentation.value.data(), presentation.value.size());
    presentation.available = model.altitudeMeters.available;
    return presentation;
  case Widget::RouteRemaining:
    presentation.title = "Route left";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatDistance(
        model.routeRemainingMeters, presentation.value.data(), presentation.value.size());
    presentation.available = model.routeRemainingMeters.available;
    return presentation;
  case Widget::Power:
    presentation.title = "Power W";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatInteger(
        model.cyclingPowerWatts, presentation.value.data(), presentation.value.size());
    presentation.available = model.cyclingPowerWatts.available;
    return presentation;
  case Widget::Cadence:
    presentation.title = "Cadence rpm";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatCadence(
        model, presentation.value.data(), presentation.value.size());
    presentation.available = model.cyclingCadenceTenthsRpm.available;
    return presentation;
  case Widget::AverageSpeed:
    presentation.title = "Average speed";
    presentation.unit = "km/h";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatAverageSpeed(
        model, presentation.value.data(), presentation.value.size());
    presentation.available = model.averageSpeedTenthsKmh.available;
    return presentation;
  case Widget::MaximumSpeed:
    presentation.title = "Max speed";
    presentation.unit = "km/h";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatMaximumSpeed(
        model, presentation.value.data(), presentation.value.size());
    presentation.available = model.maximumSpeedTenthsKmh.available;
    return presentation;
  case Widget::Calories:
    presentation.title = "Calories";
    presentation.unit = "kcal";
    presentation.kind = PresentationKind::Scalar;
    ride_telemetry_presenter::formatEnergy(
        model, presentation.value.data(), presentation.value.size());
    presentation.available = model.activeEnergyTenthsKilocalorie.available;
    return presentation;
  case Widget::AverageHeartRate:
    presentation.title = "Average HR";
    presentation.unit = "bpm";
    presentation.kind = PresentationKind::HeartWithValue;
    ride_telemetry_presenter::formatInteger(
        model.averageHeartRateBpm, presentation.value.data(), presentation.value.size());
    presentation.available = model.averageHeartRateBpm.available;
    return presentation;
  case Widget::SmartMetric1:
  case Widget::SmartMetric2: {
    const auto selection = ride_telemetry_presenter::selectBottomMetrics(model);
    return bottomMetric(widget == Widget::SmartMetric1 ? selection.left
                                                       : selection.right,
                        model);
  }
  }
  return presentation;
}

inline std::size_t maximumFormattedValueBytes(Widget widget) {
  switch (widget) {
  case Widget::MovingTime:
  case Widget::ElapsedTime:
    return 10;
  case Widget::Distance:
  case Widget::RouteRemaining:
    return 13;
  case Widget::Cadence:
    return 7;
  case Widget::Empty:
    return 0;
  default:
    return 11;
  }
}

} // namespace ride_stats_widget
