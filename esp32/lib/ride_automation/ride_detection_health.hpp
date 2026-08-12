#pragma once

#include <cstdint>

namespace ride_automation {

enum class DetectionHealthState : uint8_t {
  NoExternalPosition = 0,
  PositionStale,
  PositionLowQuality,
  MotionUnavailable,
  HealthyGpsAndMotion,
  HealthyDirectSensor,
};

struct DetectionHealthInput {
  bool directSensorFresh = false;
  bool externalPositionObserved = false;
  bool externalPositionFresh = false;
  bool externalPositionQualityValid = false;
  bool imuFresh = false;
};

struct DetectionHealth {
  DetectionHealthState state = DetectionHealthState::NoExternalPosition;
  bool directSensorAvailable = false;

  bool healthy() const {
    return state == DetectionHealthState::HealthyGpsAndMotion ||
           state == DetectionHealthState::HealthyDirectSensor;
  }
};

inline DetectionHealth
resolveDetectionHealth(const DetectionHealthInput &input) {
  if (input.directSensorFresh) {
    return {DetectionHealthState::HealthyDirectSensor, true};
  }
  if (!input.externalPositionObserved) {
    return {DetectionHealthState::NoExternalPosition, false};
  }
  if (!input.externalPositionFresh) {
    return {DetectionHealthState::PositionStale, false};
  }
  if (!input.externalPositionQualityValid) {
    return {DetectionHealthState::PositionLowQuality, false};
  }
  if (!input.imuFresh) {
    return {DetectionHealthState::MotionUnavailable, false};
  }
  return {DetectionHealthState::HealthyGpsAndMotion, false};
}

} // namespace ride_automation
