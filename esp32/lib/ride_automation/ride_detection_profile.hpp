#pragma once

#include <cstdint>

namespace ride_automation {

// All detector constants live in this profile so traces remain attributable to
// the policy that produced them. This profile may control only internal builds;
// production remains capability-off until the physical trace gates pass.
struct RideDetectionProfile {
  uint16_t version = 4;

  uint32_t wheelFreshnessMs = 3'000;
  uint32_t cadenceFreshnessMs = 3'000;
  uint32_t gpsFreshnessMs = 3'000;
  uint32_t imuFreshnessMs = 1'000;
  uint32_t watchGpsFreshnessMs = 3'000;

  float wheelMovingMetersPerSecond = 1.5F;
  float wheelStoppedMetersPerSecond = 0.5F;
  float cadenceMovingRpm = 20.0F;
  float cadenceStoppedRpm = 5.0F;
  float gpsStartMetersPerSecond = 2.8F;
  float gpsResumeMetersPerSecond = 2.0F;
  float gpsStoppedMetersPerSecond = 0.8F;
  float maximumGpsHorizontalUncertaintyMeters = 12.5F;
  float imuMovingScore = 0.55F;
  float imuStoppedScore = 0.25F;
  float watchGpsStoppedMetersPerSecond = 0.8F;
  float watchGpsResumeMetersPerSecond = 2.0F;
  float maximumWatchGpsHorizontalUncertaintyMeters = 12.5F;

  uint8_t sensorStartPositiveSeconds = 8;
  uint8_t sensorAutomaticPositiveSeconds = 10;
  uint8_t sensorStartWindowSeconds = 10;
  uint8_t gpsImuAskPositiveSeconds = 8;
  uint8_t gpsImuAskWindowSeconds = 12;
  uint8_t gpsImuAutomaticPositiveSeconds = 20;
  uint8_t gpsImuAutomaticWindowSeconds = 20;
  float gpsImuAskDisplacementMeters = 30.0F;
  float gpsImuAutomaticDisplacementMeters = 60.0F;

  uint32_t sensorPauseMs = 5'000;
  uint32_t gpsImuPauseMs = 10'000;
  uint32_t sensorResumeMs = 2'000;
  uint32_t gpsImuResumeMs = 4'000;
  uint32_t watchGpsPauseMs = 5'000;
  uint32_t watchGpsResumeMs = 2'000;
  uint32_t watchGpsMaximumSampleGapMs = 3'000;
  uint32_t decisionRetrySuppressionMs = 5'000;
  uint32_t manualResumeGraceMs = 15'000;
  uint32_t startSuppressionStoppedMs = 120'000;
  uint32_t finishCooldownMaximumMs = 900'000;
  uint32_t promptSnoozeMaximumMs = 900'000;
};

constexpr RideDetectionProfile kRideDetectionProfile{};

} // namespace ride_automation
