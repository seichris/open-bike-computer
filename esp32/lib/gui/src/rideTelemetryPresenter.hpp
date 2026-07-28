#pragma once

#include "../../ble_navigation/workout_telemetry_state.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace ride_telemetry_presenter {

using SessionState = workout_telemetry_protocol::SessionState;

struct LegacyRideTelemetry {
  uint16_t speedKilometersPerHour = 0;
  int16_t altitudeMeters = 0;
  uint32_t distanceMeters = 0;
  uint32_t elapsedSeconds = 0;
  bool hasRouteRemaining = false;
  uint32_t routeRemainingMeters = 0;
};

struct ViewModel {
  bool usesWorkout = false;
  bool hasActiveNavigation = false;
  bool stale = false;
  SessionState sessionState = SessionState::Idle;
  uint8_t sourceFlags = 0;

  workout_telemetry::OptionalMetric<uint32_t> speedTenthsKmh{};
  workout_telemetry::OptionalMetric<uint16_t> currentHeartRateBpm{};
  workout_telemetry::OptionalMetric<uint16_t> averageHeartRateBpm{};
  workout_telemetry::OptionalMetric<uint8_t> currentHeartRateZone{};
  workout_telemetry::OptionalMetric<uint8_t> heartRateZoneCount{};
  workout_telemetry::OptionalMetric<uint32_t> distanceMeters{};
  workout_telemetry::OptionalMetric<uint32_t> elapsedSeconds{};
  workout_telemetry::OptionalMetric<uint16_t>
      activeEnergyTenthsKilocalorie{};
  workout_telemetry::OptionalMetric<uint16_t> cyclingPowerWatts{};
  workout_telemetry::OptionalMetric<uint16_t> cyclingCadenceTenthsRpm{};
  workout_telemetry::OptionalMetric<int16_t> altitudeMeters{};
  workout_telemetry::OptionalMetric<uint32_t> routeRemainingMeters{};
};

enum class BottomMetric : uint8_t {
  Altitude,
  RouteRemaining,
  Power,
  Cadence,
};

struct BottomMetricSelection {
  BottomMetric left = BottomMetric::Altitude;
  BottomMetric right = BottomMetric::RouteRemaining;
};

inline ViewModel makeViewModel(
    const workout_telemetry::Snapshot &workout,
    const LegacyRideTelemetry &legacy) {
  ViewModel model{};
  model.hasActiveNavigation = legacy.hasRouteRemaining;
  model.routeRemainingMeters = legacy.hasRouteRemaining
                                   ? workout_telemetry::OptionalMetric<uint32_t>{
                                         true, legacy.routeRemainingMeters}
                                   : workout_telemetry::OptionalMetric<uint32_t>{};

  const workout_telemetry::State &state = workout.state;
  if (state.coreReceived && state.sessionState != SessionState::Idle) {
    model.usesWorkout = true;
    model.stale = workout.stale;
    model.sessionState = state.sessionState;
    model.sourceFlags = state.sourceFlags;
    if (state.speedCentimetersPerSecond.available && !workout.stale) {
      model.speedTenthsKmh = {
          true,
          (static_cast<uint32_t>(state.speedCentimetersPerSecond.value) * 36U +
           50U) /
              100U};
    }
    model.currentHeartRateBpm = state.currentHeartRateBpm;
    model.averageHeartRateBpm = state.averageHeartRateBpm;
    model.currentHeartRateZone = state.currentHeartRateZone;
    model.heartRateZoneCount = state.heartRateZoneCount;
    model.distanceMeters = state.distanceMeters;
    model.elapsedSeconds = state.elapsedSeconds;
    model.activeEnergyTenthsKilocalorie =
        state.activeEnergyTenthsKilocalorie;
    model.cyclingPowerWatts = state.cyclingPowerWatts;
    model.cyclingCadenceTenthsRpm = state.cyclingCadenceTenthsRpm;
    model.altitudeMeters = state.altitudeMeters;
    return model;
  }

  model.speedTenthsKmh = {
      true, static_cast<uint32_t>(legacy.speedKilometersPerHour) * 10U};
  model.altitudeMeters = {true, legacy.altitudeMeters};
  model.distanceMeters = {true, legacy.distanceMeters};
  model.elapsedSeconds = {true, legacy.elapsedSeconds};
  return model;
}

inline void unavailable(char *buffer, std::size_t size) {
  if (buffer != nullptr && size > 0) {
    std::snprintf(buffer, size, "--");
  }
}

inline void formatTenths(uint32_t value, char *buffer, std::size_t size) {
  std::snprintf(buffer, size, "%lu.%lu", static_cast<unsigned long>(value / 10),
                static_cast<unsigned long>(value % 10));
}

inline void formatSpeed(const ViewModel &model, char *buffer,
                        std::size_t size) {
  if (!model.speedTenthsKmh.available) {
    unavailable(buffer, size);
    return;
  }
  formatTenths(model.speedTenthsKmh.value, buffer, size);
}

template <typename T>
inline void formatInteger(const workout_telemetry::OptionalMetric<T> &metric,
                          char *buffer, std::size_t size) {
  if (!metric.available) {
    unavailable(buffer, size);
    return;
  }
  std::snprintf(buffer, size, "%lld",
                static_cast<long long>(metric.value));
}

inline void formatDistance(
    const workout_telemetry::OptionalMetric<uint32_t> &metric, char *buffer,
    std::size_t size) {
  if (!metric.available) {
    unavailable(buffer, size);
    return;
  }
  const uint32_t meters = metric.value;
  if (meters >= 10000) {
    std::snprintf(buffer, size, "%lu km",
                  static_cast<unsigned long>(meters / 1000));
  } else if (meters >= 1000) {
    const uint32_t deciKilometers = (meters + 50U) / 100U;
    std::snprintf(buffer, size, "%lu.%lu km",
                  static_cast<unsigned long>(deciKilometers / 10U),
                  static_cast<unsigned long>(deciKilometers % 10U));
  } else {
    std::snprintf(buffer, size, "%lu m",
                  static_cast<unsigned long>(meters));
  }
}

inline void formatElapsed(
    const workout_telemetry::OptionalMetric<uint32_t> &metric, char *buffer,
    std::size_t size) {
  if (!metric.available) {
    unavailable(buffer, size);
    return;
  }
  const uint32_t elapsed = metric.value;
  const uint32_t hours = elapsed / 3600;
  const uint32_t minutes = (elapsed / 60) % 60;
  const uint32_t seconds = elapsed % 60;
  if (hours > 0) {
    std::snprintf(buffer, size, "%lu:%02lu:%02lu",
                  static_cast<unsigned long>(hours),
                  static_cast<unsigned long>(minutes),
                  static_cast<unsigned long>(seconds));
  } else {
    std::snprintf(buffer, size, "%02lu:%02lu",
                  static_cast<unsigned long>(minutes),
                  static_cast<unsigned long>(seconds));
  }
}

inline int8_t fiveZoneIndex(const ViewModel &model) {
  if (!model.currentHeartRateZone.available ||
      !model.heartRateZoneCount.available ||
      model.heartRateZoneCount.value != 5 ||
      model.currentHeartRateZone.value < 1 ||
      model.currentHeartRateZone.value > 5) {
    return -1;
  }
  return static_cast<int8_t>(model.currentHeartRateZone.value - 1);
}

inline void formatEnergy(const ViewModel &model, char *buffer,
                         std::size_t size) {
  if (!model.activeEnergyTenthsKilocalorie.available) {
    unavailable(buffer, size);
    return;
  }
  formatTenths(model.activeEnergyTenthsKilocalorie.value, buffer, size);
}

inline void formatCadence(const ViewModel &model, char *buffer,
                          std::size_t size) {
  if (!model.cyclingCadenceTenthsRpm.available) {
    unavailable(buffer, size);
    return;
  }
  formatTenths(model.cyclingCadenceTenthsRpm.value, buffer, size);
}

inline BottomMetricSelection selectBottomMetrics(const ViewModel &model) {
  const bool hasPower = model.cyclingPowerWatts.available;
  const bool hasCadence = model.cyclingCadenceTenthsRpm.available;
  if (hasPower && hasCadence) {
    return {BottomMetric::Power, BottomMetric::Cadence};
  }
  if (hasPower) {
    return {BottomMetric::Power, BottomMetric::RouteRemaining};
  }
  if (hasCadence) {
    return {BottomMetric::Cadence, BottomMetric::RouteRemaining};
  }
  return {BottomMetric::Altitude, BottomMetric::RouteRemaining};
}

inline const char *bottomMetricTitle(BottomMetric metric) {
  switch (metric) {
  case BottomMetric::Altitude:
    return "Altitude m";
  case BottomMetric::RouteRemaining:
    return "Route left";
  case BottomMetric::Power:
    return "Power W";
  case BottomMetric::Cadence:
    return "Cadence rpm";
  }
  return "--";
}

inline void formatBottomMetric(BottomMetric metric, const ViewModel &model,
                               char *buffer, std::size_t size) {
  switch (metric) {
  case BottomMetric::Altitude:
    formatInteger(model.altitudeMeters, buffer, size);
    return;
  case BottomMetric::RouteRemaining:
    formatDistance(model.routeRemainingMeters, buffer, size);
    return;
  case BottomMetric::Power:
    formatInteger(model.cyclingPowerWatts, buffer, size);
    return;
  case BottomMetric::Cadence:
    formatCadence(model, buffer, size);
    return;
  }
  unavailable(buffer, size);
}

inline const char *statusLabel(const ViewModel &model) {
  if (!model.usesWorkout) {
    return "LEGACY RIDE";
  }
  if (model.stale) {
    return "LINK LOST";
  }
  switch (model.sessionState) {
  case SessionState::Starting:
    return "STARTING";
  case SessionState::Running:
    return "LIVE";
  case SessionState::Paused:
    return "PAUSED";
  case SessionState::Ending:
    return "ENDING";
  case SessionState::Ended:
    return "ENDED";
  case SessionState::Failed:
    return "FAILED";
  case SessionState::Idle:
    return "LEGACY RIDE";
  }
  return "--";
}

inline bool shouldShowStatus(const ViewModel &model) {
  if (!model.usesWorkout) {
    return false;
  }
  if (model.stale) {
    return true;
  }
  return model.sessionState != SessionState::Running &&
         model.sessionState != SessionState::Idle;
}

inline const char *sourceFreshnessLabel(const ViewModel &model) {
  if (!model.usesWorkout) {
    return "PHONE GPS";
  }
  if (model.stale) {
    return "WATCH / LINK LOST";
  }
  if (model.sessionState == SessionState::Failed) {
    return "WATCH / FAILED";
  }
  if (model.sessionState == SessionState::Ended) {
    return "WATCH / FINAL";
  }
  if ((model.sourceFlags &
       workout_telemetry_protocol::SOURCE_PAIRED_SPEED_SENSOR) != 0) {
    return "SPEED SENSOR / LIVE";
  }
  if ((model.sourceFlags &
       workout_telemetry_protocol::SOURCE_WATCH_GPS_SPEED) != 0) {
    return "WATCH GPS / LIVE";
  }
  return "WATCH / LIVE";
}

} // namespace ride_telemetry_presenter
