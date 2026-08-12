#pragma once

#include "ride_automation_policy.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace ride_automation {

constexpr uint8_t kRideAutomationTraceSchemaVersion = 2;

// One canonical, privacy-safe schema serves both firmware capture and host
// replay. It contains normalized policy inputs and output, never coordinates or
// raw accelerometer/gyroscope samples.
struct TraceRecord {
  uint32_t timestampMs = 0;
  uint16_t profileVersion = kRideDetectionProfile.version;
  ConfirmedLifecycle lifecycle = ConfirmedLifecycle::Idle;
  Settings settings{};
  RideEvidenceObservation observation{};
  uint16_t evidenceMask = EvidenceNone;
  Decision decision{};
  ShadowCounters counters{};
};

inline const char *lifecycleName(ConfirmedLifecycle lifecycle) {
  switch (lifecycle) {
  case ConfirmedLifecycle::Idle:
    return "idle";
  case ConfirmedLifecycle::Running:
    return "running";
  case ConfirmedLifecycle::AutomaticallyPaused:
    return "auto_paused";
  case ConfirmedLifecycle::ManuallyPaused:
    return "manual_paused";
  case ConfirmedLifecycle::Finished:
    return "finished";
  }
  return "finished";
}

inline const char *startModeName(StartMode mode) {
  switch (mode) {
  case StartMode::Off:
    return "off";
  case StartMode::Ask:
    return "ask";
  case StartMode::Automatic:
    return "automatic";
  }
  return "off";
}

inline const char *transitionName(Transition transition) {
  switch (transition) {
  case Transition::None:
    return "none";
  case Transition::Start:
    return "start";
  case Transition::Pause:
    return "pause";
  case Transition::Resume:
    return "resume";
  }
  return "none";
}

inline bool formatTimedMetric(char *output, std::size_t outputSize,
                              const TimedMetric &metric, uint32_t nowMs) {
  int written = 0;
  if (!metric.available || !nonnegativeFinite(metric.value)) {
    written = std::snprintf(output, outputSize, "null");
  } else {
    written = std::snprintf(
        output, outputSize, "{\"value\":%.7g,\"age_ms\":%lu}",
        static_cast<double>(metric.value),
        static_cast<unsigned long>(elapsedMs(nowMs, metric.capturedAtMs)));
  }
  return written >= 0 && static_cast<std::size_t>(written) < outputSize;
}

inline bool formatTimedFlag(char *output, std::size_t outputSize,
                            const TimedFlag &flag, uint32_t nowMs) {
  int written = 0;
  if (!flag.available) {
    written = std::snprintf(output, outputSize, "null");
  } else {
    written = std::snprintf(
        output, outputSize, "{\"value\":%s,\"age_ms\":%lu}",
        flag.value ? "true" : "false",
        static_cast<unsigned long>(elapsedMs(nowMs, flag.capturedAtMs)));
  }
  return written >= 0 && static_cast<std::size_t>(written) < outputSize;
}

inline int formatTraceJsonLine(const TraceRecord &record, char *output,
                               std::size_t outputSize) {
  if (output == nullptr || outputSize == 0)
    return -1;

  char wheel[64], cadence[64], gps[64], gpsFix[64], uncertainty[64];
  char stationary[64], displacement[64], imu[64];
  if (!formatTimedMetric(wheel, sizeof(wheel),
                         record.observation.wheelSpeedMetersPerSecond,
                         record.timestampMs) ||
      !formatTimedMetric(cadence, sizeof(cadence),
                         record.observation.cadenceRpm,
                         record.timestampMs) ||
      !formatTimedMetric(gps, sizeof(gps),
                         record.observation.gpsSpeedMetersPerSecond,
                         record.timestampMs) ||
      !formatTimedFlag(gpsFix, sizeof(gpsFix),
                       record.observation.gpsFixValid,
                       record.timestampMs) ||
      !formatTimedMetric(uncertainty, sizeof(uncertainty),
                         record.observation.gpsHorizontalUncertaintyMeters,
                         record.timestampMs) ||
      !formatTimedFlag(stationary, sizeof(stationary),
                       record.observation.gpsStationaryWindowValid,
                       record.timestampMs) ||
      !formatTimedMetric(displacement, sizeof(displacement),
                         record.observation.gpsNetDisplacementMeters,
                         record.timestampMs) ||
      !formatTimedMetric(imu, sizeof(imu), record.observation.imuMotionScore,
                         record.timestampMs))
    return -1;

  const int written = std::snprintf(
      output, outputSize,
      "{\"schema\":%u,\"profile\":%u,\"t_ms\":%lu,"
      "\"lifecycle\":\"%s\",\"settings\":{\"start_mode\":\"%s\","
      "\"auto_pause\":%s},\"evidence\":{\"wheel_mps\":%s,"
      "\"cadence_rpm\":%s,\"gps_mps\":%s,\"gps_fix_valid\":%s,"
      "\"gps_source\":%u,\"gps_horizontal_uncertainty_m\":%s,"
      "\"gps_stationary\":%s,"
      "\"gps_displacement_m\":%s,\"imu_motion_score\":%s},"
      "\"output\":{\"decision\":\"%s\",\"evidence_mask\":%u,"
      "\"source_health_mask\":%u,"
      "\"decision_sequence\":%lu,\"candidate_began_at_ms\":%lu,"
      "\"decided_at_ms\":%lu,\"counters\":{\"start\":%lu,"
      "\"pause\":%lu,\"resume\":%lu,\"conflict\":%lu}}}",
      static_cast<unsigned>(kRideAutomationTraceSchemaVersion),
      static_cast<unsigned>(record.profileVersion),
      static_cast<unsigned long>(record.timestampMs),
      lifecycleName(record.lifecycle), startModeName(record.settings.startMode),
      record.settings.autoPauseEnabled ? "true" : "false", wheel, cadence,
      gps, gpsFix, static_cast<unsigned>(record.observation.gpsPositionSource),
      uncertainty, stationary, displacement, imu,
      transitionName(record.decision.transition),
      static_cast<unsigned>(record.evidenceMask),
      static_cast<unsigned>(record.decision.sourceHealthMask),
      static_cast<unsigned long>(record.decision.sequence),
      static_cast<unsigned long>(record.decision.candidateBeganAtMs),
      static_cast<unsigned long>(record.decision.decidedAtMs),
      static_cast<unsigned long>(record.counters.start),
      static_cast<unsigned long>(record.counters.pause),
      static_cast<unsigned long>(record.counters.resume),
      static_cast<unsigned long>(record.counters.sourceConflict));
  return written >= 0 && static_cast<std::size_t>(written) < outputSize
             ? written
             : -1;
}

} // namespace ride_automation
