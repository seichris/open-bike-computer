#include "ride_automation_runtime.hpp"

#if defined(RIDE_AUTOMATION_INTERNAL_CONTROL) &&                        \
    !defined(RIDE_AUTOMATION_SHADOW)
#error "RIDE_AUTOMATION_INTERNAL_CONTROL requires RIDE_AUTOMATION_SHADOW"
#endif

#if defined(RIDE_AUTOMATION_SHADOW) &&                                  \
    (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206))

#include "gps_ride_observation.hpp"
#include "ble_navigation.hpp"
#include "qmi8658.hpp"
#include "ride_automation_trace.hpp"
#include "ride_automation_protocol.hpp"
#include "speaker.hpp"
#include "workout_telemetry_runtime.hpp"

#include <Arduino.h>
#include <Preferences.h>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <algorithm>
#include <cmath>

namespace {

ride_automation::ShadowRuntime runtime;
const ride_automation::CyclingMotionSource *cyclingMotionSource = nullptr;
uint32_t lastTraceMs = 0;
bool traceInitialized = false;
ride_automation_protocol::Frame lastInboundFrame;
bool hasInboundFrame = false;
ride_automation_protocol::Frame outstandingDecision;
bool hasOutstandingDecision = false;
uint32_t rideGeneration = 1;
ride_automation::Settings configuredSettings;
uint8_t configuredAlertMode = 0;
uint32_t configGeneration = 0;
uint8_t pendingFrame[ride_automation_protocol::FRAME_SIZE]{};
ride_automation_protocol::Kind pendingFrameKind =
    ride_automation_protocol::Kind::Decision;
bool pendingFrameValid = false;
uint32_t pendingSentAtMs = 0;
uint8_t pendingAttempts = 0;
bool promptResponded = false;
bool promptAccepted = false;
ride_automation_runtime::UiError uiError =
    ride_automation_runtime::UiError::None;
uint32_t uiErrorUntilMs = 0;
uint32_t resumedMessageUntilMs = 0;
ride_automation::DetectionHealth detectionHealth;
ride_automation::ConfirmedLifecycle retainedLifecycle =
    ride_automation::ConfirmedLifecycle::Idle;
uint16_t runningStartGraceSessionToken = 0;
bool decisionAcknowledged = false;
uint32_t outstandingDecisionBeganAtMs = 0;
uint32_t lastAcknowledgedDecisionRetryAtMs = 0;
bool persistedStartSuppression = false;

struct InboundTransportFrame {
  ride_automation_protocol::Frame frame;
  uint32_t receivedAtMs = 0;
};

QueueHandle_t inboundTransportQueue = nullptr;

struct GpsWindow {
  struct Point {
    uint32_t capturedAtMs = 0;
    double latitude = 0.0;
    double longitude = 0.0;
  };

  static constexpr std::size_t kCapacity = 32;
  Point points[kCapacity]{};
  std::size_t start = 0;
  std::size_t count = 0;
  uint32_t lastCapturedAtMs = 0;

  void clear() { *this = {}; }

  void append(const Point &point) {
    if (count > 0 &&
        static_cast<int32_t>(point.capturedAtMs - lastCapturedAtMs) <= 0)
      return;
    lastCapturedAtMs = point.capturedAtMs;
    if (count == kCapacity) {
      start = (start + 1) % kCapacity;
      --count;
    }
    points[(start + count) % kCapacity] = point;
    ++count;
  }

  const Point &at(std::size_t index) const {
    return points[(start + index) % kCapacity];
  }

  void prune(uint32_t nowMs, uint32_t maximumAgeMs) {
    while (count > 0 &&
           static_cast<uint32_t>(nowMs - at(0).capturedAtMs) > maximumAgeMs) {
      start = (start + 1) % kCapacity;
      --count;
    }
  }
};

GpsWindow gpsWindow;
RidePositionSource gpsWindowSource = RidePositionSource::None;

constexpr char kPreferencesNamespace[] = "rideDetect";
constexpr char kConfigurationBlobKey[] = "configV1";
constexpr std::size_t kConfigurationBlobSize = 14;

uint32_t configurationChecksum(const uint8_t *bytes, std::size_t length) {
  uint32_t hash = 2'166'136'261U;
  for (std::size_t index = 0; index < length; ++index) {
    hash ^= bytes[index];
    hash *= 16'777'619U;
  }
  return hash;
}

ride_automation::StartMode normalizedStartMode(
    ride_automation::StartMode startMode) {
#if defined(RIDE_AUTOMATION_AUTOMATIC_START)
  return startMode;
#else
  return startMode == ride_automation::StartMode::Automatic
             ? ride_automation::StartMode::Ask
             : startMode;
#endif
}

void encodeConfigurationBlob(const ride_automation::Settings &settings,
                             uint8_t alertMode, uint32_t generation,
                             uint8_t *bytes) {
  std::fill(bytes, bytes + kConfigurationBlobSize, 0);
  bytes[0] = 1;
  bytes[1] = 0;
  bytes[2] = static_cast<uint8_t>(settings.startMode);
  bytes[3] = settings.autoPauseEnabled ? 1 : 0;
  bytes[4] = alertMode;
  ride_automation_protocol::writeUInt32(bytes, 6, generation);
  ride_automation_protocol::writeUInt32(
      bytes, 10, configurationChecksum(bytes, 10));
}

bool decodeConfigurationBlob(const uint8_t *bytes,
                             ride_automation::Settings &settings,
                             uint8_t &alertMode, uint32_t &generation) {
  if (ride_automation_protocol::readUInt16(bytes, 0) != 1 ||
      bytes[2] > 2 || bytes[3] > 1 || bytes[4] > 2 ||
      ride_automation_protocol::readUInt32(bytes, 10) !=
          configurationChecksum(bytes, 10)) {
    return false;
  }
  settings.startMode = normalizedStartMode(
      static_cast<ride_automation::StartMode>(bytes[2]));
  settings.autoPauseEnabled = bytes[3] == 1;
  alertMode = bytes[4];
  generation = ride_automation_protocol::readUInt32(bytes, 6);
  return true;
}

void loadConfiguration() {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, true))
    return;
  uint8_t blob[kConfigurationBlobSize]{};
  if (preferences.getBytesLength(kConfigurationBlobKey) == sizeof(blob) &&
      preferences.getBytes(kConfigurationBlobKey, blob, sizeof(blob)) ==
          sizeof(blob) &&
      decodeConfigurationBlob(blob, configuredSettings, configuredAlertMode,
                              configGeneration)) {
    preferences.end();
    return;
  }
  const uint16_t schema = preferences.getUShort("schema", 0);
  const uint8_t startMode = preferences.getUChar("start", 1);
  const uint8_t alertMode = preferences.getUChar("alert", 0);
  if (schema == 1 && startMode <= 2 && alertMode <= 2) {
    configuredSettings.startMode = normalizedStartMode(
        static_cast<ride_automation::StartMode>(startMode));
    configuredSettings.autoPauseEnabled = preferences.getBool("pause", true);
    configuredAlertMode = alertMode;
    configGeneration = preferences.getULong("generation", 0);
  }
  preferences.end();
}

void loadPersistentRuntimeState() {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) {
    rideGeneration = esp_random();
    if (rideGeneration == 0)
      rideGeneration = 1;
    persistedStartSuppression = false;
    return;
  }
  const uint32_t nextGeneration = preferences.getULong("rideGen", 0) + 1U;
  rideGeneration = nextGeneration == 0 ? 1 : nextGeneration;
  if (preferences.putULong("rideGen", rideGeneration) != sizeof(uint32_t)) {
    // A failed NVS write must not reuse the same boot generation after the
    // next reset. Fall back to a non-zero per-boot nonce so stale decisions
    // cannot be correlated with this runtime instance.
    rideGeneration = esp_random();
    if (rideGeneration == 0)
      rideGeneration = 1;
  }
  persistedStartSuppression = preferences.getBool("suppressed", false);
  preferences.end();
}

void persistStartSuppression(bool active) {
  if (persistedStartSuppression == active)
    return;
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false))
    return;
  if (preferences.putBool("suppressed", active) == sizeof(uint8_t))
    persistedStartSuppression = active;
  preferences.end();
}

void snoozeStartAndPersist(uint32_t nowMs) {
  runtime.policy().snoozeStart(nowMs);
  persistStartSuppression(true);
}

bool persistConfiguration(const ride_automation::Settings &settings,
                          uint8_t alertMode, uint32_t generation) {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false))
    return false;
  uint8_t expected[kConfigurationBlobSize]{};
  uint8_t verified[kConfigurationBlobSize]{};
  encodeConfigurationBlob(settings, alertMode, generation, expected);
  const bool wrote = preferences.putBytes(
                         kConfigurationBlobKey, expected, sizeof(expected)) ==
                     sizeof(expected);
  const bool readBack = wrote &&
      preferences.getBytes(kConfigurationBlobKey, verified,
                           sizeof(verified)) == sizeof(verified);
  preferences.end();
  return readBack && std::equal(expected, expected + sizeof(expected),
                                verified);
}

bool sendTransportFrame(const ride_automation_protocol::Frame &frame) {
  uint8_t bytes[ride_automation_protocol::FRAME_SIZE]{};
  return ride_automation_protocol::encode(frame, bytes, sizeof(bytes)) &&
         bleNavServer.notifyRideAutomationFrame(bytes, sizeof(bytes));
}

bool queueTransportFrame(const ride_automation_protocol::Frame &frame,
                         uint32_t nowMs) {
  if (!ride_automation_protocol::encode(frame, pendingFrame,
                                         sizeof(pendingFrame))) {
    return false;
  }
  pendingFrameValid = true;
  pendingFrameKind = frame.kind;
  pendingAttempts = 0;
  pendingSentAtMs = nowMs;
  return bleNavServer.notifyRideAutomationFrame(pendingFrame,
                                                sizeof(pendingFrame));
}

void showTransportError(ride_automation_protocol::Result result,
                        uint32_t nowMs) {
  using ride_automation_protocol::Result;
  switch (result) {
  case Result::SessionMismatch:
    uiError = ride_automation_runtime::UiError::SessionMismatch;
    break;
  case Result::Rejected:
  case Result::Stale:
    uiError = ride_automation_runtime::UiError::Rejected;
    break;
  case Result::WatchUnavailable:
  case Result::None:
  case Result::Accepted:
    uiError = ride_automation_runtime::UiError::PhoneOrWatchUnavailable;
    break;
  }
  uiErrorUntilMs = nowMs + 8'000;
}

void playConfirmedTransitionAlert() {
  if (configuredAlertMode != 0)
    return;
  waveshare_board::speaker::requestPlay(
      waveshare_board::speaker::Sound::BellDing, 55);
}

double degreesToRadians(double degrees) {
  return degrees * 0.017453292519943295;
}

float distanceMeters(double latitudeA, double longitudeA, double latitudeB,
                     double longitudeB) {
  constexpr double kEarthRadiusMeters = 6'371'000.0;
  const double latitudeDelta = degreesToRadians(latitudeB - latitudeA);
  const double longitudeDelta = degreesToRadians(longitudeB - longitudeA);
  const double a = std::sin(latitudeDelta / 2.0) *
                       std::sin(latitudeDelta / 2.0) +
                   std::cos(degreesToRadians(latitudeA)) *
                       std::cos(degreesToRadians(latitudeB)) *
                       std::sin(longitudeDelta / 2.0) *
                       std::sin(longitudeDelta / 2.0);
  const double boundedA = std::max(0.0, std::min(1.0, a));
  return static_cast<float>(
      kEarthRadiusMeters * 2.0 *
      std::atan2(std::sqrt(boundedA), std::sqrt(1.0 - boundedA)));
}

ride_automation::ConfirmedLifecycle confirmedLifecycle(
    const workout_telemetry::Snapshot &workout,
    ride_automation::ConfirmedLifecycle fallback) {
  using ride_automation::ConfirmedLifecycle;
  using workout_telemetry_protocol::SessionState;
  if (workout.stale || !workout.state.coreReceived)
    return fallback;
  switch (workout.state.sessionState) {
  case SessionState::Starting:
  case SessionState::Running:
    return ConfirmedLifecycle::Running;
  case SessionState::Paused:
    return workout.state.originReceived &&
                   workout.state.pauseOrigin ==
                       workout_telemetry_protocol::PauseOrigin::Automatic
               ? ConfirmedLifecycle::AutomaticallyPaused
               : ConfirmedLifecycle::ManuallyPaused;
  case SessionState::Ending:
  case SessionState::Ended:
  case SessionState::Failed:
    return ConfirmedLifecycle::Finished;
  case SessionState::Idle:
    return ConfirmedLifecycle::Idle;
  }
  return ConfirmedLifecycle::Idle;
}

bool workoutContradictsOutstandingDecision(
    const workout_telemetry::Snapshot &workout) {
  using ride_automation_protocol::Transition;
  using workout_telemetry_protocol::PauseOrigin;
  using workout_telemetry_protocol::SessionState;
  if (!hasOutstandingDecision || workout.stale ||
      !workout.state.coreReceived) {
    return false;
  }
  const SessionState state = workout.state.sessionState;
  if (state == SessionState::Ending || state == SessionState::Ended ||
      state == SessionState::Failed) {
    return true;
  }
  if (outstandingDecision.transition != Transition::Start &&
      state == SessionState::Idle) {
    return true;
  }
  if (!workout.state.originReceived)
    return false;
  if (outstandingDecision.transition != Transition::Start &&
      ride_automation_protocol::hasSessionID(outstandingDecision.sessionID) &&
      workout.state.sessionID != outstandingDecision.sessionID) {
    return true;
  }
  switch (outstandingDecision.transition) {
  case Transition::Start:
    return workout.state.lastTransitionOrigin == PauseOrigin::Manual;
  case Transition::Pause:
    return (state == SessionState::Paused &&
            workout.state.pauseOrigin == PauseOrigin::Manual) ||
           (state == SessionState::Running &&
            workout.state.lastTransitionOrigin == PauseOrigin::Manual);
  case Transition::Resume:
    return (state == SessionState::Paused &&
            workout.state.pauseOrigin == PauseOrigin::Manual) ||
           (state == SessionState::Running &&
            workout.state.lastTransitionOrigin == PauseOrigin::Manual);
  case Transition::None:
    return false;
  }
  return false;
}

void appendWorkoutSensorEvidence(uint32_t nowMs,
                                 ride_automation::RideEvidenceObservation &out) {
  const workout_telemetry::Snapshot workout =
      workout_telemetry_runtime::snapshot(nowMs);
  if (workout.stale ||
      !workout_telemetry::isActiveWorkout(workout.state))
    return;
  if (workout.state.speedCentimetersPerSecond.available &&
      (workout.state.sourceFlags &
       workout_telemetry_protocol::SOURCE_PAIRED_SPEED_SENSOR) != 0) {
    out.wheelSpeedMetersPerSecond = {
        true,
        static_cast<float>(workout.state.speedCentimetersPerSecond.value) /
            100.0F,
        workout.state.lastCoreReceivedAtMs,
        ride_automation::kRideDetectionProfile.wheelFreshnessMs};
  }
  if (workout.state.cyclingCadenceTenthsRpm.available) {
    out.cadenceRpm = {
        true,
        static_cast<float>(workout.state.cyclingCadenceTenthsRpm.value) /
            10.0F,
        workout.state.lastExtendedReceivedAtMs,
        ride_automation::kRideDetectionProfile.cadenceFreshnessMs};
  }
}

void appendGpsEvidence(uint32_t nowMs,
                       const GpsRideObservation &value,
                       ride_automation::RideEvidenceObservation &out) {
  out.gpsPositionSource = static_cast<uint8_t>(value.source);
  out.gpsFixValid = {value.fixAvailable, value.fixValid,
                     value.capturedAtMs,
                     ride_automation::kRideDetectionProfile.gpsFreshnessMs};
  out.gpsSpeedMetersPerSecond = {
      value.speedAvailable, value.speedMetersPerSecond, value.capturedAtMs,
      ride_automation::kRideDetectionProfile.gpsFreshnessMs};
  out.gpsHorizontalUncertaintyMeters = {
      value.horizontalUncertaintyAvailable,
      value.horizontalUncertaintyMeters,
      value.capturedAtMs,
      ride_automation::kRideDetectionProfile.gpsFreshnessMs};

  if (value.source == RidePositionSource::None ||
      nowMs - value.capturedAtMs >
          ride_automation::kRideDetectionProfile.gpsFreshnessMs)
    return;

  const bool goodLocation = value.locationAvailable && value.fixAvailable &&
                            value.fixValid &&
                            value.horizontalUncertaintyAvailable &&
                            value.horizontalUncertaintyMeters <=
                                ride_automation::kRideDetectionProfile
                                    .maximumGpsHorizontalUncertaintyMeters;
  if (!goodLocation)
    return;

  if (gpsWindowSource != value.source) {
    gpsWindow.clear();
    gpsWindowSource = value.source;
  }

  gpsWindow.append({value.capturedAtMs, value.latitude,
                    value.longitude});
  gpsWindow.prune(value.capturedAtMs, 25'000);
  if (gpsWindow.count == 0)
    return;
  const GpsWindow::Point &oldest = gpsWindow.at(0);
  const float displacement = distanceMeters(oldest.latitude, oldest.longitude,
                                            value.latitude, value.longitude);
  out.gpsNetDisplacementMeters = {
      true, displacement, value.capturedAtMs,
      ride_automation::kRideDetectionProfile.gpsFreshnessMs};

  float stationaryDisplacement = 0.0F;
  for (std::size_t index = 0; index < gpsWindow.count; ++index) {
    const GpsWindow::Point &point = gpsWindow.at(index);
    if (static_cast<uint32_t>(value.capturedAtMs -
                              point.capturedAtMs) > 10'000)
      continue;
    stationaryDisplacement = std::max(
        stationaryDisplacement,
        distanceMeters(point.latitude, point.longitude, value.latitude,
                       value.longitude));
  }
  const float stationaryRadiusMeters =
      fmaxf(8.0F, value.horizontalUncertaintyMeters * 2.0F);
  const bool stationary = stationaryDisplacement <= stationaryRadiusMeters;
  out.gpsStationaryWindowValid = {
      true, stationary, value.capturedAtMs,
      ride_automation::kRideDetectionProfile.gpsFreshnessMs};
}

void appendImuEvidence(ride_automation::RideEvidenceObservation &out) {
  const waveshare_board::imu::Status &imu = waveshare_board::imu::status();
  const bool usable = imu.configured && imu.dataValid &&
                      imu.motionWindowSamples >= 10;
  out.imuMotionScore = {
      usable, imu.motionScore, imu.lastSampleMs,
      ride_automation::kRideDetectionProfile.imuFreshnessMs};
}

bool matchesOutstandingResponse(
    const ride_automation_protocol::Frame &frame) {
  return ride_automation_protocol::matchesOutstandingResponse(
      hasOutstandingDecision, outstandingDecision, frame);
}

bool processInboundTransportFrame(
    const ride_automation_protocol::Frame &frame, uint32_t receivedAtMs) {
  if (ride_automation_protocol::isDuplicateOrOutOfOrderInbound(
          hasInboundFrame, lastInboundFrame, frame)) {
    return false;
  }

  if (frame.kind == ride_automation_protocol::Kind::Acknowledgement ||
      frame.kind == ride_automation_protocol::Kind::Confirmation) {
    if (!matchesOutstandingResponse(frame))
      return false;
    const bool accepted =
        frame.result == ride_automation_protocol::Result::Accepted;
    if (frame.kind == ride_automation_protocol::Kind::Acknowledgement &&
        frame.acknowledgedKind == static_cast<uint8_t>(
                                      ride_automation_protocol::Kind::
                                          PromptResponse)) {
      if (!promptResponded)
        return false;
      if (pendingFrameValid &&
          pendingFrameKind ==
              ride_automation_protocol::Kind::PromptResponse) {
        pendingFrameValid = false;
      }
      if (!accepted) {
        showTransportError(frame.result, receivedAtMs);
        snoozeStartAndPersist(receivedAtMs);
        hasOutstandingDecision = false;
        decisionAcknowledged = false;
        promptAccepted = false;
      } else {
        // Accepting the rider's prompt response proves the phone already
        // correlated the underlying start decision, even if its earlier
        // decision ACK was lost or reordered behind this frame.
        decisionAcknowledged = true;
        lastAcknowledgedDecisionRetryAtMs = receivedAtMs;
      }
    } else if (!accepted) {
      if (pendingFrameValid &&
          pendingFrameKind == ride_automation_protocol::Kind::Decision) {
        pendingFrameValid = false;
      }
      const bool quietAskDecline =
          frame.kind == ride_automation_protocol::Kind::Confirmation &&
          outstandingDecision.transition ==
              ride_automation_protocol::Transition::Start &&
          outstandingDecision.startMode ==
              static_cast<uint8_t>(ride_automation::StartMode::Ask) &&
          frame.result == ride_automation_protocol::Result::Rejected;
      if (!quietAskDecline)
        showTransportError(frame.result, receivedAtMs);
      if (frame.kind == ride_automation_protocol::Kind::Confirmation &&
          outstandingDecision.transition ==
              ride_automation_protocol::Transition::Start) {
        snoozeStartAndPersist(receivedAtMs);
      } else {
        runtime.policy().rejectPending(receivedAtMs);
      }
      hasOutstandingDecision = false;
      decisionAcknowledged = false;
    } else if (frame.kind ==
               ride_automation_protocol::Kind::Acknowledgement) {
      if (pendingFrameValid &&
          pendingFrameKind == ride_automation_protocol::Kind::Decision) {
        pendingFrameValid = false;
      }
      decisionAcknowledged = true;
      lastAcknowledgedDecisionRetryAtMs = receivedAtMs;
    } else {
      pendingFrameValid = false;
      if (outstandingDecision.transition ==
          ride_automation_protocol::Transition::Resume) {
        resumedMessageUntilMs = receivedAtMs + 3'000;
      }
      playConfirmedTransitionAlert();
      hasOutstandingDecision = false;
      decisionAcknowledged = false;
    }
  } else if (frame.kind == ride_automation_protocol::Kind::PromptResponse) {
    if (!matchesOutstandingResponse(frame) ||
        outstandingDecision.transition !=
            ride_automation_protocol::Transition::Start) {
      return false;
    }
    const ride_automation_protocol::PromptResponseResolution resolution =
        ride_automation_protocol::resolvePromptResponse(
            promptResponded, promptAccepted, frame.result);
    promptResponded = true;
    promptAccepted = resolution.accepted;
    if (resolution.shouldSnooze)
      snoozeStartAndPersist(receivedAtMs);

    ride_automation_protocol::Frame response = frame;
    response.kind = ride_automation_protocol::Kind::Acknowledgement;
    response.result = resolution.acknowledgement;
    response.acknowledgedKind = static_cast<uint8_t>(
        ride_automation_protocol::Kind::PromptResponse);
    response.monotonicSeconds = receivedAtMs / 1'000;
    sendTransportFrame(response);
  }

  const bool configurationTargetsCurrentBoot =
      frame.rideGeneration == rideGeneration;
  if (frame.kind == ride_automation_protocol::Kind::Configuration &&
      configurationTargetsCurrentBoot &&
      (configGeneration == 0 ||
       ride_automation_protocol::serialNumberNewer(
           frame.watermarkOrConfigGeneration, configGeneration))) {
    ride_automation::Settings candidateSettings = configuredSettings;
    candidateSettings.startMode = normalizedStartMode(
        static_cast<ride_automation::StartMode>(frame.startMode));
    candidateSettings.autoPauseEnabled = frame.autoPauseEnabled;
    if (persistConfiguration(candidateSettings, frame.alertMode,
                             frame.watermarkOrConfigGeneration)) {
      configuredSettings = candidateSettings;
      configuredAlertMode = frame.alertMode;
      configGeneration = frame.watermarkOrConfigGeneration;
    }
  }
  if (frame.kind == ride_automation_protocol::Kind::Configuration) {
    ride_automation_protocol::Frame response;
    response.kind =
        ride_automation_protocol::Kind::ConfigurationAcknowledgement;
    response.result =
        configurationTargetsCurrentBoot &&
                frame.watermarkOrConfigGeneration == configGeneration
            ? ride_automation_protocol::Result::Accepted
            : ride_automation_protocol::Result::Rejected;
    response.rideGeneration = rideGeneration;
    response.profileVersion =
        ride_automation::kRideDetectionProfile.version;
    response.watermarkOrConfigGeneration = configGeneration;
    response.startMode = static_cast<uint8_t>(configuredSettings.startMode);
    response.autoPauseEnabled = configuredSettings.autoPauseEnabled;
    response.alertMode = configuredAlertMode;
    response.monotonicSeconds = receivedAtMs / 1'000;
    sendTransportFrame(response);
  } else if (frame.kind == ride_automation_protocol::Kind::Resynchronize) {
    ride_automation_protocol::Frame response;
    response.kind = ride_automation_protocol::Kind::Resynchronize;
    response.rideGeneration = rideGeneration;
    response.profileVersion =
        ride_automation::kRideDetectionProfile.version;
    response.watermarkOrConfigGeneration =
        ride_automation_protocol::outstandingDecisionWatermark(
            hasOutstandingDecision, outstandingDecision);
    response.startMode = static_cast<uint8_t>(configuredSettings.startMode);
    response.autoPauseEnabled = configuredSettings.autoPauseEnabled;
    response.alertMode = configuredAlertMode;
    response.monotonicSeconds = receivedAtMs / 1'000;
    sendTransportFrame(response);
  }

  lastInboundFrame = frame;
  hasInboundFrame = true;
  return true;
}

} // namespace

namespace ride_automation_runtime {

void setCyclingMotionSource(
    const ride_automation::CyclingMotionSource *source) {
  cyclingMotionSource = source;
}

void beginFirmwareShadow() {
  runtime = ride_automation::ShadowRuntime{};
  gpsWindow = {};
  lastTraceMs = 0;
  traceInitialized = false;
  lastInboundFrame = {};
  hasInboundFrame = false;
  outstandingDecision = {};
  hasOutstandingDecision = false;
  configuredSettings = {};
  configuredAlertMode = 0;
  configGeneration = 0;
  loadConfiguration();
  loadPersistentRuntimeState();
  if (persistedStartSuppression)
    runtime.policy().snoozeStart(0);
  if (inboundTransportQueue == nullptr) {
    inboundTransportQueue = xQueueCreate(8, sizeof(InboundTransportFrame));
  } else {
    xQueueReset(inboundTransportQueue);
  }
  pendingFrameValid = false;
  pendingFrameKind = ride_automation_protocol::Kind::Decision;
  pendingSentAtMs = 0;
  pendingAttempts = 0;
  promptResponded = false;
  promptAccepted = false;
  uiError = ride_automation_runtime::UiError::None;
  uiErrorUntilMs = 0;
  resumedMessageUntilMs = 0;
  detectionHealth = {};
  retainedLifecycle = ride_automation::ConfirmedLifecycle::Idle;
  runningStartGraceSessionToken = 0;
  decisionAcknowledged = false;
  outstandingDecisionBeganAtMs = 0;
  lastAcknowledgedDecisionRetryAtMs = 0;
#if defined(RIDE_AUTOMATION_INTERNAL_CONTROL)
  Serial.println(
      "Ride automation: internal control enabled; production remains gated");
#else
  Serial.println("Ride automation: shadow trace enabled; controls disabled");
#endif
}

void processFirmwareShadow(uint32_t nowMs) {
  InboundTransportFrame inbound;
  while (inboundTransportQueue != nullptr &&
         xQueueReceive(inboundTransportQueue, &inbound, 0) == pdTRUE) {
    if (!processInboundTransportFrame(inbound.frame, inbound.receivedAtMs))
      Serial.println("BLE Ride Automation: rejected queued frame");
  }
  if (traceInitialized && nowMs - lastTraceMs < 1'000)
    return;
  traceInitialized = true;
  lastTraceMs = nowMs;

  ride_automation::RideEvidenceObservation observation;
  appendWorkoutSensorEvidence(nowMs, observation);
  if (cyclingMotionSource != nullptr)
    cyclingMotionSource->appendEvidence(nowMs, observation);
  GpsRideObservation gpsObservation = currentGpsRideObservation(
      nowMs, ride_automation::kRideDetectionProfile.gpsFreshnessMs);
  if (gpsObservation.source == RidePositionSource::None) {
    gpsObservation = currentGpsRideObservation(nowMs, UINT32_MAX);
  }
  appendGpsEvidence(nowMs, gpsObservation, observation);
  appendImuEvidence(observation);
  const bool directEvidenceAvailable =
      (ride_automation::metricFresh(
           observation.wheelSpeedMetersPerSecond, nowMs,
           ride_automation::kRideDetectionProfile.wheelFreshnessMs) &&
       ride_automation::nonnegativeFinite(
           observation.wheelSpeedMetersPerSecond.value)) ||
      (ride_automation::metricFresh(
           observation.cadenceRpm, nowMs,
           ride_automation::kRideDetectionProfile.cadenceFreshnessMs) &&
       ride_automation::nonnegativeFinite(observation.cadenceRpm.value));
  const bool imuEvidenceAvailable = ride_automation::metricFresh(
          observation.imuMotionScore, nowMs,
          ride_automation::kRideDetectionProfile.imuFreshnessMs) &&
      ride_automation::nonnegativeFinite(observation.imuMotionScore.value);
  const bool gpsEvidenceAvailable = ride_automation::flagFresh(
          observation.gpsFixValid, nowMs,
          ride_automation::kRideDetectionProfile.gpsFreshnessMs) &&
      observation.gpsFixValid.value &&
      ride_automation::metricFresh(
          observation.gpsSpeedMetersPerSecond, nowMs,
          ride_automation::kRideDetectionProfile.gpsFreshnessMs) &&
      ride_automation::nonnegativeFinite(
          observation.gpsSpeedMetersPerSecond.value) &&
      ride_automation::metricFresh(
          observation.gpsHorizontalUncertaintyMeters, nowMs,
          ride_automation::kRideDetectionProfile.gpsFreshnessMs) &&
      observation.gpsHorizontalUncertaintyMeters.value <=
          ride_automation::kRideDetectionProfile
              .maximumGpsHorizontalUncertaintyMeters;
  detectionHealth = ride_automation::resolveDetectionHealth({
      directEvidenceAvailable,
      gpsObservation.source != RidePositionSource::None &&
          gpsObservation.fixAvailable,
      gpsObservation.source != RidePositionSource::None &&
          nowMs - gpsObservation.capturedAtMs <=
              ride_automation::kRideDetectionProfile.gpsFreshnessMs,
      gpsEvidenceAvailable,
      imuEvidenceAvailable,
  });

  const ride_automation::Settings settings = configuredSettings;
  const workout_telemetry::Snapshot workout =
      workout_telemetry_runtime::snapshot(nowMs);
  const ride_automation::ConfirmedLifecycle lifecycle =
      confirmedLifecycle(workout, retainedLifecycle);
  if (!workout.stale && workout.state.coreReceived)
    retainedLifecycle = lifecycle;
  // Every newly observed running session receives a conservative startup
  // grace. Manual provenance may arrive one telemetry frame later, while an
  // automatic start safely tolerates the same brief pause suppression.
  if (!workout.stale && workout.state.coreReceived &&
      workout.state.sessionState ==
          workout_telemetry_protocol::SessionState::Running &&
      workout.state.sessionToken != runningStartGraceSessionToken) {
    runtime.policy().noteManualRunningTransition(nowMs);
    runningStartGraceSessionToken = workout.state.sessionToken;
  }
  const ride_automation::Decision decision =
      runtime.update(nowMs, observation, lifecycle, settings);

  if (runtime.policy().takePendingCancellation() ||
      workoutContradictsOutstandingDecision(workout)) {
    if (hasOutstandingDecision) {
      ride_automation_protocol::Frame cancellation = outstandingDecision;
      cancellation.kind = ride_automation_protocol::Kind::Cancellation;
      cancellation.result = ride_automation_protocol::Result::Stale;
      cancellation.monotonicSeconds = nowMs / 1'000;
      sendTransportFrame(cancellation);
    }
    pendingFrameValid = false;
    hasOutstandingDecision = false;
    decisionAcknowledged = false;
    promptResponded = false;
    promptAccepted = false;
  }

  if (decision) {
    ride_automation_protocol::Frame frame;
    frame.kind = ride_automation_protocol::Kind::Decision;
    frame.transition = static_cast<ride_automation_protocol::Transition>(
        static_cast<uint8_t>(decision.transition));
    frame.origin = ride_automation_protocol::Origin::Automatic;
    frame.rideGeneration = rideGeneration;
    frame.decisionSequence = decision.sequence;
    frame.evidenceMask = decision.evidenceMask;
    frame.profileVersion = decision.profileVersion;
    if (workout.state.originReceived)
      frame.sessionID = workout.state.sessionID;
    frame.watermarkOrConfigGeneration = configGeneration;
    frame.startMode = static_cast<uint8_t>(settings.startMode);
    frame.autoPauseEnabled = settings.autoPauseEnabled;
    frame.alertMode = configuredAlertMode;
    frame.candidateBeganSeconds = decision.candidateBeganAtMs / 1'000;
    frame.monotonicSeconds = nowMs / 1'000;
    frame.sourceHealthMask = decision.sourceHealthMask;
#if defined(RIDE_AUTOMATION_INTERNAL_CONTROL)
    queueTransportFrame(frame, nowMs);
    outstandingDecision = frame;
    hasOutstandingDecision = true;
    decisionAcknowledged = false;
    outstandingDecisionBeganAtMs = nowMs;
    lastAcknowledgedDecisionRetryAtMs = nowMs;
    promptResponded = false;
    promptAccepted = false;
    if (frame.transition == ride_automation_protocol::Transition::Start &&
        configuredSettings.startMode == ride_automation::StartMode::Ask &&
        configuredAlertMode == 0) {
      waveshare_board::speaker::requestPlay(
          waveshare_board::speaker::Sound::BellDing, 55);
    }
#endif
  } else if (pendingFrameValid && pendingAttempts < 4) {
    const uint32_t retryDelayMs = 1'000U << pendingAttempts;
    if (nowMs - pendingSentAtMs >= retryDelayMs) {
      pendingSentAtMs = nowMs;
      ++pendingAttempts;
      bleNavServer.notifyRideAutomationFrame(pendingFrame,
                                             sizeof(pendingFrame));
    }
  } else if (pendingFrameValid && pendingAttempts >= 4 &&
             nowMs - pendingSentAtMs >= 16'000) {
    pendingFrameValid = false;
    showTransportError(
        ride_automation_protocol::Result::WatchUnavailable, nowMs);
    if (hasOutstandingDecision &&
        outstandingDecision.transition ==
            ride_automation_protocol::Transition::Start) {
      snoozeStartAndPersist(nowMs);
    } else {
      runtime.policy().rejectPending(nowMs);
    }
    hasOutstandingDecision = false;
    decisionAcknowledged = false;
  }

  if (hasOutstandingDecision && decisionAcknowledged) {
    if (nowMs - outstandingDecisionBeganAtMs >= 30'000) {
      showTransportError(
          ride_automation_protocol::Result::WatchUnavailable, nowMs);
      if (outstandingDecision.transition ==
          ride_automation_protocol::Transition::Start) {
        snoozeStartAndPersist(nowMs);
      } else {
        runtime.policy().rejectPending(nowMs);
      }
      hasOutstandingDecision = false;
      decisionAcknowledged = false;
    } else if (nowMs - lastAcknowledgedDecisionRetryAtMs >= 5'000) {
      lastAcknowledgedDecisionRetryAtMs = nowMs;
      sendTransportFrame(outstandingDecision);
    }
  }

  const bool suppressionIsActive =
      runtime.policy().startSuppressionActive();
  if (suppressionIsActive != persistedStartSuppression)
    persistStartSuppression(suppressionIsActive);

  ride_automation::TraceRecord trace;
  trace.timestampMs = nowMs;
  trace.lifecycle = lifecycle;
  trace.settings = settings;
  trace.observation = observation;
  trace.evidenceMask = runtime.lastEvidenceMask();
  trace.decision = decision;
  trace.counters = runtime.counters();
  char output[1'536];
  if (ride_automation::formatTraceJsonLine(trace, output, sizeof(output)) >= 0)
    Serial.println(output);
#if !defined(RIDE_AUTOMATION_INTERNAL_CONTROL)
  if (decision)
    runtime.policy().rejectPending(nowMs);
#endif
}

bool ingestTransportFrame(const uint8_t *data, std::size_t length,
                          uint32_t receivedAtMs) {
  ride_automation_protocol::Frame frame;
  if (!ride_automation_protocol::decode(data, length, frame))
    return false;
  if (inboundTransportQueue == nullptr)
    return false;
  const InboundTransportFrame inbound{frame, receivedAtMs};
  return xQueueSend(inboundTransportQueue, &inbound, 0) == pdTRUE;
}

UiSnapshot uiSnapshot(uint32_t nowMs) {
  if (uiError != UiError::None &&
      static_cast<int32_t>(uiErrorUntilMs - nowMs) > 0) {
    return {UiPhase::Error, uiError, 0,
            hasOutstandingDecision
                ? outstandingDecision.decisionSequence
                : 0};
  }
  if (uiError != UiError::None)
    uiError = UiError::None;
  if (resumedMessageUntilMs != 0 &&
      static_cast<int32_t>(resumedMessageUntilMs - nowMs) > 0) {
    return {UiPhase::RideResumed, UiError::None, 100, 0};
  }
  resumedMessageUntilMs = 0;
  if (hasOutstandingDecision) {
    const uint32_t sequence = outstandingDecision.decisionSequence;
    switch (outstandingDecision.transition) {
    case ride_automation_protocol::Transition::Start:
      if (configuredSettings.startMode == ride_automation::StartMode::Ask) {
        if (!promptResponded) {
          return {UiPhase::StartPrompt, UiError::None, 100, sequence,
                  static_cast<uint8_t>(
                      nowMs - outstandingDecisionBeganAtMs >= 30'000
                          ? 0
                          : 30U -
                                (nowMs - outstandingDecisionBeganAtMs) /
                                    1'000U)};
        }
        if (!promptAccepted)
          return {};
      }
      return {UiPhase::Starting, UiError::None, 100, sequence};
    case ride_automation_protocol::Transition::Pause:
      return {UiPhase::AwaitingPause, UiError::None, 100, sequence};
    case ride_automation_protocol::Transition::Resume:
      return {UiPhase::AwaitingResume, UiError::None, 100, sequence};
    case ride_automation_protocol::Transition::None:
      break;
    }
  }
  const ride_automation::DetectorStatus detector =
      runtime.policy().detectorStatus();
  switch (detector.phase) {
  case ride_automation::DetectorPhase::StartCandidate:
    return {UiPhase::StartCandidate, UiError::None,
            detector.progressPercent, 0};
  case ride_automation::DetectorPhase::PauseCandidate:
    return {UiPhase::PauseCandidate, UiError::None,
            detector.progressPercent, 0};
  case ride_automation::DetectorPhase::ResumeCandidate:
    return {UiPhase::ResumeCandidate, UiError::None,
            detector.progressPercent, 0};
  case ride_automation::DetectorPhase::AwaitingConfirmation:
  case ride_automation::DetectorPhase::RestartCooldown:
  case ride_automation::DetectorPhase::Quiet:
    break;
  }
  if (!detectionHealth.healthy() && nowMs > 15'000 &&
      configuredSettings.startMode != ride_automation::StartMode::Off) {
    return {UiPhase::SensorDegraded, UiError::None, 0, 0, 0,
            detectionHealth};
  }
  return {UiPhase::Hidden, UiError::None, 0, 0, 0, detectionHealth};
}

bool respondToStartPrompt(bool accept, uint32_t nowMs) {
#if defined(RIDE_AUTOMATION_INTERNAL_CONTROL)
  if (!hasOutstandingDecision || promptResponded ||
      outstandingDecision.transition !=
          ride_automation_protocol::Transition::Start ||
      configuredSettings.startMode != ride_automation::StartMode::Ask) {
    return false;
  }
  ride_automation_protocol::Frame response = outstandingDecision;
  response.kind = ride_automation_protocol::Kind::PromptResponse;
  response.result = accept ? ride_automation_protocol::Result::Accepted
                           : ride_automation_protocol::Result::Rejected;
  response.monotonicSeconds = nowMs / 1'000;
  promptResponded = true;
  promptAccepted = accept;
  if (!accept)
    snoozeStartAndPersist(nowMs);
  queueTransportFrame(response, nowMs);
  return true;
#else
  (void)accept;
  (void)nowMs;
  return false;
#endif
}

bool needsAttention(uint32_t nowMs) {
  const UiPhase phase = uiSnapshot(nowMs).phase;
  return phase == UiPhase::StartPrompt || phase == UiPhase::Starting ||
         phase == UiPhase::Error;
}

ConfigurationSnapshot configurationSnapshot() {
  return {configuredSettings.startMode,
          configuredSettings.autoPauseEnabled,
          configuredAlertMode,
          configGeneration};
}

bool setLocalConfiguration(ride_automation::StartMode startMode,
                           bool autoPauseEnabled, uint8_t alertMode) {
  if (static_cast<uint8_t>(startMode) >
          static_cast<uint8_t>(ride_automation::StartMode::Automatic) ||
      alertMode > 2) {
    return false;
  }
  const uint32_t generation = configGeneration == UINT32_MAX
                                  ? 1
                                  : configGeneration + 1;
  const ride_automation::Settings candidate{
      normalizedStartMode(startMode), autoPauseEnabled};
  if (!persistConfiguration(candidate, alertMode, generation))
    return false;
  configuredSettings = candidate;
  configuredAlertMode = alertMode;
  configGeneration = generation;
  return true;
}

} // namespace ride_automation_runtime

#else

namespace ride_automation_runtime {

void setCyclingMotionSource(const ride_automation::CyclingMotionSource *) {}
void beginFirmwareShadow() {}
void processFirmwareShadow(uint32_t) {}
bool ingestTransportFrame(const uint8_t *, std::size_t, uint32_t) {
  return false;
}
UiSnapshot uiSnapshot(uint32_t) { return {}; }
bool respondToStartPrompt(bool, uint32_t) { return false; }
bool needsAttention(uint32_t) { return false; }
ConfigurationSnapshot configurationSnapshot() { return {}; }
bool setLocalConfiguration(ride_automation::StartMode, bool, uint8_t) {
  return false;
}

} // namespace ride_automation_runtime

#endif
