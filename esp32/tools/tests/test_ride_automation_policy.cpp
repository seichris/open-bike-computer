#include "../../lib/ride_automation/ride_automation_runtime.hpp"
#include "../../lib/ride_automation/ride_automation_trace.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <limits>

namespace {

using namespace ride_automation;

TimedMetric metric(float value, uint32_t capturedAtMs,
                   uint32_t maximumAgeMs = 0) {
  return TimedMetric{true, value, capturedAtMs, maximumAgeMs};
}

TimedFlag flag(bool value, uint32_t capturedAtMs,
               uint32_t maximumAgeMs = 0) {
  return TimedFlag{true, value, capturedAtMs, maximumAgeMs};
}

RideEvidenceObservation wheel(float metersPerSecond, uint32_t nowMs) {
  RideEvidenceObservation observation;
  observation.wheelSpeedMetersPerSecond = metric(metersPerSecond, nowMs);
  return observation;
}

RideEvidenceObservation cadence(float rpm, uint32_t nowMs) {
  RideEvidenceObservation observation;
  observation.cadenceRpm = metric(rpm, nowMs);
  return observation;
}

RideEvidenceObservation wheelAndCadence(float metersPerSecond, float rpm,
                                        uint32_t nowMs) {
  auto observation = wheel(metersPerSecond, nowMs);
  observation.cadenceRpm = metric(rpm, nowMs);
  return observation;
}

RideEvidenceObservation gpsImu(float gpsMetersPerSecond, float motionScore,
                               float displacementMeters, uint32_t nowMs,
                               bool stationary = false) {
  RideEvidenceObservation observation;
  observation.gpsSpeedMetersPerSecond = metric(gpsMetersPerSecond, nowMs);
  observation.gpsFixValid = flag(true, nowMs);
  observation.gpsHorizontalUncertaintyMeters = metric(5.0F, nowMs);
  observation.gpsStationaryWindowValid = flag(stationary, nowMs);
  observation.gpsNetDisplacementMeters = metric(displacementMeters, nowMs);
  observation.imuMotionScore = metric(motionScore, nowMs);
  return observation;
}

Decision runSeconds(RideAutomationPolicy &policy, uint32_t startMs,
                    uint8_t seconds, ConfirmedLifecycle lifecycle,
                    const Settings &settings, float wheelSpeed) {
  Decision result;
  for (uint8_t offset = 0; offset < seconds; ++offset) {
    const uint32_t nowMs = startMs + static_cast<uint32_t>(offset) * 1'000U;
    result = policy.update(nowMs, wheel(wheelSpeed, nowMs), lifecycle,
                           settings);
  }
  return result;
}

} // namespace

int main() {
  using ride_automation_runtime::shouldEndDetailedCapture;
  assert(shouldEndDetailedCapture(ConfirmedLifecycle::Running,
                                  ConfirmedLifecycle::Finished));
  assert(shouldEndDetailedCapture(ConfirmedLifecycle::ManuallyPaused,
                                  ConfirmedLifecycle::Finished));
  assert(!shouldEndDetailedCapture(ConfirmedLifecycle::Finished,
                                   ConfirmedLifecycle::Finished));
  assert(!shouldEndDetailedCapture(ConfirmedLifecycle::Running,
                                   ConfirmedLifecycle::ManuallyPaused));
  using ride_automation_runtime::shouldEndDetailedCaptureAfterTelemetryLoss;
  constexpr uint32_t staleGrace =
      ride_automation_runtime::kDetailedCaptureTelemetryLossGraceMs;
  assert(!shouldEndDetailedCaptureAfterTelemetryLoss(
      ConfirmedLifecycle::Running, true, staleGrace - 1, 0));
  assert(shouldEndDetailedCaptureAfterTelemetryLoss(
      ConfirmedLifecycle::Running, true, staleGrace, 0));
  assert(!shouldEndDetailedCaptureAfterTelemetryLoss(
      ConfirmedLifecycle::Running, false, staleGrace, 0));
  assert(!shouldEndDetailedCaptureAfterTelemetryLoss(
      ConfirmedLifecycle::Finished, true, staleGrace, 0));
  assert(shouldEndDetailedCaptureAfterTelemetryLoss(
      ConfirmedLifecycle::ManuallyPaused, true, 100,
      std::numeric_limits<uint32_t>::max() - staleGrace + 100));
  using ride_automation_runtime::UiPhase;
  assert(!ride_automation_runtime::shouldShowAutomationPanel(
      UiPhase::SensorDegraded));
  assert(ride_automation_runtime::shouldShowDetectionWaitingMessage(
      UiPhase::SensorDegraded, true));
  assert(!ride_automation_runtime::shouldShowDetectionWaitingMessage(
      UiPhase::SensorDegraded, false));
  assert(!ride_automation_runtime::shouldShowDetectionWaitingMessage(
      UiPhase::StartCandidate, true));

  Settings ask;
  ask.startMode = StartMode::Ask;
  ask.autoPauseEnabled = true;

  // Missing and stale measurements are not zero-valued stopped evidence.
  TimedMetric missing;
  assert(!metricFresh(missing, 100, 3'000));
  assert(metricFresh(metric(0.0F, 100), 3'100, 3'000));
  assert(!metricFresh(metric(0.0F, 100), 3'101, 3'000));
  // A caller may tighten freshness but cannot exceed the profile ceiling.
  assert(!metricFresh(metric(1.0F, 0, 60'000), 3'001, 3'000));
  assert(metricFresh(metric(1.0F,
                            std::numeric_limits<uint32_t>::max() - 500),
                     499, 1'000));

  DurationLatch longRunningLatch;
  assert(!longRunningLatch.update(0, true,
                                  std::numeric_limits<uint32_t>::max()));
  assert(!longRunningLatch.update(
      std::numeric_limits<uint32_t>::max() - 10, true,
      std::numeric_limits<uint32_t>::max()));
  longRunningLatch.freeze(100);
  assert(longRunningLatch.accumulatedMs(100) ==
         std::numeric_limits<uint32_t>::max());
  assert(longRunningLatch.update(
      200, true, std::numeric_limits<uint32_t>::max()));

  EvidenceWindow<12> window;
  for (uint32_t second = 0; second < 8; ++second)
    window.observe(second * 1'000, true, true);
  assert(window.counts(7'000, 10).positive == 7);
  window.observe(8'000, true, true);
  assert(window.counts(8'000, 10).positive == 8);
  window.observe(8'000, true, false, true);
  assert(window.counts(8'000, 10).contradictory == 0);
  window.observe(9'000, true, true);
  assert(window.counts(9'000, 10).contradictory == 1);
  window.reset();
  const uint32_t nearWrap = std::numeric_limits<uint32_t>::max() - 3'500;
  for (uint32_t second = 0; second < 8; ++second)
    window.observe(nearWrap + second * 1'000U, true, true);
  assert(window.counts(nearWrap + 7'000U, 10).positive == 7);
  window.observe(nearWrap + 8'000U, true, true);
  assert(window.counts(nearWrap + 8'000U, 10).positive == 8);

  RideAutomationPolicy sensorAsk;
  Decision decision = runSeconds(sensorAsk, 0, 8, ConfirmedLifecycle::Idle,
                                 ask, 2.0F);
  assert(!decision);
  assert(sensorAsk.detectorStatus().phase == DetectorPhase::StartCandidate);
  assert(sensorAsk.detectorStatus().progressPercent == 87);
  decision = sensorAsk.update(8'000, wheel(2.0F, 8'000),
                              ConfirmedLifecycle::Idle, ask);
  assert(decision.transition == Transition::Start);
  assert(decision.sequence != 0);
  assert(decision.profileVersion == 3);
  assert(sensorAsk.detectorStatus().phase ==
         DetectorPhase::AwaitingConfirmation);
  assert(sensorAsk.detectorStatus().progressPercent == 100);
  assert((decision.evidenceMask & EvidenceWheelMoving) != 0);
  assert((decision.sourceHealthMask & SourceHealthWheelFresh) != 0);
  // A pending request is emitted exactly once until lifecycle confirmation.
  assert(!sensorAsk.update(9'000, wheel(2.0F, 9'000),
                           ConfirmedLifecycle::Idle, ask));

  // A delayed decision is retired as soon as authoritative evidence reverses.
  assert(!sensorAsk.update(10'000, wheel(0.0F, 10'000),
                           ConfirmedLifecycle::Idle, ask));
  assert(sensorAsk.takePendingCancellation());
  assert(sensorAsk.pendingTransition() == Transition::None);

  Settings automatic = ask;
  automatic.startMode = StartMode::Automatic;
  RideAutomationPolicy sensorAutomatic;
  assert(!runSeconds(sensorAutomatic, 0, 10, ConfirmedLifecycle::Idle,
                     automatic, 2.0F));
  decision = sensorAutomatic.update(10'000, wheel(2.0F, 10'000),
                                    ConfirmedLifecycle::Idle, automatic);
  assert(decision.transition == Transition::Start);

  Settings disabled = ask;
  disabled.startMode = StartMode::Off;
  RideAutomationPolicy startDisabled;
  assert(!runSeconds(startDisabled, 0, 30, ConfirmedLifecycle::Idle,
                     disabled, 4.0F));

  // Stale repeats cannot fill the start window.
  RideAutomationPolicy staleSensor;
  RideEvidenceObservation stale = wheel(2.0F, 0);
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000)
    decision = staleSensor.update(nowMs, stale, ConfirmedLifecycle::Idle, ask);
  assert(!decision);
  assert(staleSensor.counters().start == 0);

  // IMU can corroborate GPS but never starts a ride by itself.
  RideAutomationPolicy imuOnly;
  for (uint32_t nowMs = 0; nowMs <= 30'000; nowMs += 1'000) {
    RideEvidenceObservation observation;
    observation.imuMotionScore = metric(1.0F, nowMs);
    assert(!imuOnly.update(nowMs, observation, ConfirmedLifecycle::Idle, ask));
  }

  RideAutomationPolicy gpsAsk;
  for (uint32_t second = 0; second < 8; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!gpsAsk.update(nowMs, gpsImu(3.0F, 0.9F, 35.0F, nowMs),
                          ConfirmedLifecycle::Idle, ask));
  }
  decision = gpsAsk.update(8'000, gpsImu(3.0F, 0.9F, 35.0F, 8'000),
                           ConfirmedLifecycle::Idle, ask);
  assert(decision.transition == Transition::Start);
  assert((decision.evidenceMask & EvidenceGpsMoving) != 0);
  assert((decision.evidenceMask & EvidenceImuMoving) != 0);
  assert((decision.evidenceMask & EvidenceGpsDisplacement) != 0);

  RideAutomationPolicy gpsAutomatic;
  for (uint32_t second = 0; second < 20; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!gpsAutomatic.update(
        nowMs, gpsImu(3.0F, 0.9F, 65.0F, nowMs),
        ConfirmedLifecycle::Idle, automatic));
  }
  decision = gpsAutomatic.update(
      20'000, gpsImu(3.0F, 0.9F, 65.0F, 20'000),
      ConfirmedLifecycle::Idle, automatic);
  assert(decision.transition == Transition::Start);

  RideAutomationPolicy badAccuracy;
  for (uint32_t second = 0; second < 20; ++second) {
    const uint32_t nowMs = second * 1'000;
    auto observation = gpsImu(4.0F, 0.9F, 100.0F, nowMs);
    observation.gpsHorizontalUncertaintyMeters.value = 12.51F;
    assert(!badAccuracy.update(nowMs, observation, ConfirmedLifecycle::Idle,
                               ask));
  }
  RideAutomationPolicy boundaryAccuracy;
  for (uint32_t second = 0; second < 8; ++second) {
    const uint32_t nowMs = second * 1'000;
    auto observation = gpsImu(4.0F, 0.9F, 100.0F, nowMs);
    observation.gpsHorizontalUncertaintyMeters.value = 12.5F;
    assert(!boundaryAccuracy.update(nowMs, observation,
                                    ConfirmedLifecycle::Idle, ask));
  }
  auto boundaryObservation = gpsImu(4.0F, 0.9F, 100.0F, 8'000);
  boundaryObservation.gpsHorizontalUncertaintyMeters.value = 12.5F;
  assert(boundaryAccuracy
             .update(8'000, boundaryObservation, ConfirmedLifecycle::Idle,
                     ask)
             .transition == Transition::Start);

  RideAutomationPolicy staleGpsQuality;
  for (uint32_t second = 0; second < 20; ++second) {
    const uint32_t nowMs = second * 1'000;
    auto observation = gpsImu(4.0F, 0.9F, 100.0F, nowMs);
    observation.gpsFixValid.capturedAtMs = 0;
    observation.gpsHorizontalUncertaintyMeters.capturedAtMs = 0;
    observation.gpsNetDisplacementMeters.capturedAtMs = 0;
    assert(!staleGpsQuality.update(nowMs, observation,
                                   ConfirmedLifecycle::Idle, ask));
  }

  // GPS movement without displacement (including bounded jitter) cannot start.
  RideAutomationPolicy gpsJitter;
  for (uint32_t second = 0; second < 20; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!gpsJitter.update(nowMs, gpsImu(3.2F, 0.8F, 7.0F, nowMs),
                             ConfirmedLifecycle::Idle, ask));
  }

  // A contradictory direct source blocks the sensor start path.
  RideAutomationPolicy conflictStart;
  for (uint32_t second = 0; second < 12; ++second) {
    const uint32_t nowMs = second * 1'000;
    auto observation = wheel(2.0F, nowMs);
    observation.cadenceRpm = metric(0.0F, nowMs);
    assert(!conflictStart.update(nowMs, observation,
                                 ConfirmedLifecycle::Idle, ask));
  }
  assert(conflictStart.counters().sourceConflict == 12);

  RideAutomationPolicy pause;
  decision = runSeconds(pause, 0, 5, ConfirmedLifecycle::Running, ask, 0.0F);
  assert(!decision);
  assert(pause.detectorStatus().phase == DetectorPhase::PauseCandidate);
  assert(pause.detectorStatus().progressPercent == 80);
  decision = pause.update(5'000, wheel(0.0F, 5'000),
                          ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);
  assert(!pause.update(6'000, wheel(3.0F, 6'000),
                       ConfirmedLifecycle::Running, ask));
  assert(pause.takePendingCancellation());

  // Losing all evidence after issuing a transition is uncertainty, not a
  // contradiction. Keep the request pending until the lifecycle confirms it
  // or trustworthy movement reverses it.
  RideAutomationPolicy uncertainPendingPause;
  decision = runSeconds(uncertainPendingPause, 0, 5,
                        ConfirmedLifecycle::Running, ask, 0.0F);
  assert(!decision);
  decision = uncertainPendingPause.update(
      5'000, wheel(0.0F, 5'000), ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);
  assert(!uncertainPendingPause.update(
      6'000, {}, ConfirmedLifecycle::Running, ask));
  assert(!uncertainPendingPause.takePendingCancellation());
  assert(uncertainPendingPause.pendingTransition() == Transition::Pause);

  // Explicit sensor-combination matrix. A stopped wheel is authoritative;
  // cadence zero alone is not, and fresh movement always vetoes pause.
  RideAutomationPolicy speedOnlyStop;
  assert(speedOnlyStop.update(0, wheel(0.0F, 0),
                              ConfirmedLifecycle::Running, ask)
             .transition == Transition::None);
  assert(speedOnlyStop.lastSensorCombination() ==
         SensorCombination::SpeedOnly);
  assert(speedOnlyStop.lastMotionEvidenceState() ==
         MotionEvidenceState::WheelStopped);
  decision = speedOnlyStop.update(5'000, wheel(0.0F, 5'000),
                                  ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  RideAutomationPolicy speedOnlyMoving;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    assert(!speedOnlyMoving.update(nowMs, wheel(6.5F, nowMs),
                                   ConfirmedLifecycle::Running, ask));
  }
  assert(speedOnlyMoving.lastMotionEvidenceState() ==
         MotionEvidenceState::WheelMoving);

  // Independent trustworthy movement vetoes a stopped wheel reading. A
  // stuck-at-zero wheel sample must not retain the five-second pause path.
  RideAutomationPolicy stoppedWheelGpsMoving;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    auto observation = gpsImu(6.5F, 0.9F, 100.0F, nowMs);
    observation.wheelSpeedMetersPerSecond = metric(0.0F, nowMs);
    assert(!stoppedWheelGpsMoving.update(
        nowMs, observation, ConfirmedLifecycle::Running, ask));
  }

  RideAutomationPolicy bothTrueStop;
  for (uint32_t nowMs = 0; nowMs < 5'000; nowMs += 1'000) {
    assert(!bothTrueStop.update(
        nowMs, wheelAndCadence(0.0F, 0.0F, nowMs),
        ConfirmedLifecycle::Running, ask));
  }
  decision = bothTrueStop.update(
      5'000, wheelAndCadence(0.0F, 0.0F, 5'000),
      ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  RideAutomationPolicy bothCoasting;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    assert(!bothCoasting.update(
        nowMs, wheelAndCadence(6.5F, 0.0F, nowMs),
        ConfirmedLifecycle::Running, ask));
  }
  assert(bothCoasting.lastSensorCombination() ==
         SensorCombination::SpeedAndCadence);
  assert(bothCoasting.lastMotionEvidenceState() ==
         MotionEvidenceState::SourceConflict);

  RideAutomationPolicy slowCrawl;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    assert(!slowCrawl.update(nowMs, wheel(0.8F, nowMs),
                             ConfirmedLifecycle::Running, ask));
  }
  assert(slowCrawl.lastMotionEvidenceState() ==
         MotionEvidenceState::SlowCrawl);

  RideAutomationPolicy cadenceOnlyCoasting;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    auto observation = gpsImu(6.5F, 0.9F, 100.0F, nowMs);
    observation.cadenceRpm = metric(0.0F, nowMs);
    assert(!cadenceOnlyCoasting.update(
        nowMs, observation, ConfirmedLifecycle::Running, ask));
  }
  assert(cadenceOnlyCoasting.lastSensorCombination() ==
         SensorCombination::CadenceOnly);
  assert(cadenceOnlyCoasting.lastMotionEvidenceState() ==
         MotionEvidenceState::GpsImuMoving);

  RideAutomationPolicy cadenceOnlyTrueStop;
  for (uint32_t nowMs = 0; nowMs < 10'000; nowMs += 1'000) {
    auto observation = gpsImu(0.1F, 0.1F, 0.0F, nowMs, true);
    observation.cadenceRpm = metric(0.0F, nowMs);
    assert(!cadenceOnlyTrueStop.update(
        nowMs, observation, ConfirmedLifecycle::Running, ask));
  }
  auto cadenceStop = gpsImu(0.1F, 0.1F, 0.0F, 10'000, true);
  cadenceStop.cadenceRpm = metric(0.0F, 10'000);
  decision = cadenceOnlyTrueStop.update(
      10'000, cadenceStop, ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  RideAutomationPolicy sensorlessTrueStop;
  for (uint32_t nowMs = 0; nowMs < 10'000; nowMs += 1'000) {
    assert(!sensorlessTrueStop.update(
        nowMs, gpsImu(0.1F, 0.1F, 0.0F, nowMs, true),
        ConfirmedLifecycle::Running, ask));
  }
  decision = sensorlessTrueStop.update(
      10'000, gpsImu(0.1F, 0.1F, 0.0F, 10'000, true),
      ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  RideAutomationPolicy sensorlessMoving;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    assert(!sensorlessMoving.update(
        nowMs, gpsImu(6.5F, 0.9F, 100.0F, nowMs),
        ConfirmedLifecycle::Running, ask));
  }
  assert(sensorlessMoving.lastSensorCombination() ==
         SensorCombination::Neither);
  assert(sensorlessMoving.lastMotionEvidenceState() ==
         MotionEvidenceState::GpsImuMoving);

  Settings noAutoPause = ask;
  noAutoPause.autoPauseEnabled = false;
  RideAutomationPolicy pauseDisabled;
  assert(!runSeconds(pauseDisabled, 0, 20, ConfirmedLifecycle::Running,
                     noAutoPause, 0.0F));

  // Direct-sensor pause requires one uninterrupted fresh interval. A dropout
  // resets, rather than freezes, the direct candidate.
  RideAutomationPolicy directDropout;
  for (uint32_t nowMs = 0; nowMs <= 3'000; nowMs += 1'000)
    assert(!directDropout.update(nowMs, wheel(0.0F, nowMs),
                                 ConfirmedLifecycle::Running, ask));
  assert(!directDropout.update(4'000, {}, ConfirmedLifecycle::Running, ask));
  assert(!directDropout.update(100'000, wheel(0.0F, 100'000),
                               ConfirmedLifecycle::Running, ask));
  assert(!directDropout.update(101'000, wheel(0.0F, 101'000),
                               ConfirmedLifecycle::Running, ask));

  // Invalid negative/non-finite inputs are unavailable, not stopped evidence.
  RideAutomationPolicy invalidPause;
  for (uint32_t second = 0; second < 20; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!invalidPause.update(nowMs, wheel(-1.0F, nowMs),
                                ConfirmedLifecycle::Running, ask));
  }
  RideEvidenceObservation invalidImu = gpsImu(0.0F, 0.0F, 0.0F, 20'000,
                                              true);
  invalidImu.imuMotionScore.value = std::nanf("");
  assert(!invalidPause.update(20'000, invalidImu,
                              ConfirmedLifecycle::Running, ask));

  // Fresh moving evidence has authority over a stopped source and cancels a
  // pause candidate.
  RideAutomationPolicy conflictPause;
  for (uint32_t second = 0; second < 10; ++second) {
    const uint32_t nowMs = second * 1'000;
    auto observation = wheel(0.0F, nowMs);
    observation.cadenceRpm = metric(80.0F, nowMs);
    assert(!conflictPause.update(nowMs, observation,
                                 ConfirmedLifecycle::Running, ask));
  }

  // A GPS/IMU quality gap resets the pause candidate. Uncertainty must not
  // retain enough old stopped time to create a later false pause.
  RideAutomationPolicy gpsPause;
  for (uint32_t second = 0; second <= 4; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!gpsPause.update(nowMs, gpsImu(0.1F, 0.1F, 0.0F, nowMs, true),
                            ConfirmedLifecycle::Running, ask));
  }
  for (uint32_t nowMs = 5'000; nowMs <= 20'000; nowMs += 1'000)
    assert(!gpsPause.update(nowMs, {}, ConfirmedLifecycle::Running, ask));
  for (uint32_t nowMs = 21'000; nowMs < 31'000; nowMs += 1'000)
    assert(!gpsPause.update(nowMs,
                            gpsImu(0.1F, 0.1F, 0.0F, nowMs, true),
                            ConfirmedLifecycle::Running, ask));
  decision = gpsPause.update(31'000,
                             gpsImu(0.1F, 0.1F, 0.0F, 31'000, true),
                             ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  // A speed-sensor dropout is uncertainty, not a synthetic zero. Cadence zero
  // falls back to GPS/IMU and a fresh wheel reconnect cancels the candidate.
  RideAutomationPolicy dropoutReconnect;
  assert(!dropoutReconnect.update(0, wheel(5.0F, 0),
                                  ConfirmedLifecycle::Running, ask));
  assert(!dropoutReconnect.update(4'000, cadence(0.0F, 4'000),
                                  ConfirmedLifecycle::Running, ask));
  assert(dropoutReconnect.lastMotionEvidenceState() ==
         MotionEvidenceState::WheelDropout);
  for (uint32_t nowMs = 5'000; nowMs < 10'000; nowMs += 1'000) {
    auto observation = gpsImu(0.1F, 0.1F, 0.0F, nowMs, true);
    observation.cadenceRpm = metric(0.0F, nowMs);
    assert(!dropoutReconnect.update(
        nowMs, observation, ConfirmedLifecycle::Running, ask));
  }
  assert(!dropoutReconnect.update(
      10'000, wheelAndCadence(5.0F, 0.0F, 10'000),
      ConfirmedLifecycle::Running, ask));
  assert(dropoutReconnect.lastMotionEvidenceState() ==
         MotionEvidenceState::SourceConflict);

  RideAutomationPolicy resume;
  assert(!runSeconds(resume, 0, 2,
                     ConfirmedLifecycle::AutomaticallyPaused, ask, 2.0F));
  decision = resume.update(2'000, wheel(2.0F, 2'000),
                           ConfirmedLifecycle::AutomaticallyPaused, ask);
  assert(decision.transition == Transition::Resume);
  assert(!resume.update(3'000, wheel(0.0F, 3'000),
                        ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(resume.takePendingCancellation());

  RideAutomationPolicy gpsResume;
  for (uint32_t second = 0; second < 4; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!gpsResume.update(nowMs,
                             gpsImu(2.1F, 0.8F, 0.0F, nowMs),
                             ConfirmedLifecycle::AutomaticallyPaused, ask));
  }
  decision = gpsResume.update(4'000, gpsImu(2.1F, 0.8F, 0.0F, 4'000),
                              ConfirmedLifecycle::AutomaticallyPaused, ask);
  assert(decision.transition == Transition::Resume);

  RideAutomationPolicy manualPause;
  for (uint32_t second = 0; second < 30; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!manualPause.update(nowMs, wheel(4.0F, nowMs),
                               ConfirmedLifecycle::ManuallyPaused, ask));
  }

  // A rider's manual resume receives a grace interval before auto-pause can
  // begin accumulating stopped evidence again.
  RideAutomationPolicy manualResumeGrace;
  assert(!manualResumeGrace.update(0, {},
                                   ConfirmedLifecycle::ManuallyPaused, ask));
  for (uint32_t nowMs = 1'000; nowMs <= 20'000; nowMs += 1'000)
    assert(!manualResumeGrace.update(nowMs, wheel(0.0F, nowMs),
                                     ConfirmedLifecycle::Running, ask));
  decision = manualResumeGrace.update(21'000, wheel(0.0F, 21'000),
                                      ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  // Finishing suppresses detection until two continuous stopped minutes or
  // the fifteen-minute ceiling, whichever comes first. Moving time cannot
  // satisfy the stopped-evidence release.
  RideAutomationPolicy finishCooldown;
  assert(!finishCooldown.update(0, {}, ConfirmedLifecycle::Finished, ask));
  for (uint32_t nowMs = 1'000; nowMs < 900'000; nowMs += 10'000)
    assert(!finishCooldown.update(nowMs, wheel(3.0F, nowMs),
                                  ConfirmedLifecycle::Idle, ask));
  for (uint32_t nowMs = 900'000; nowMs < 908'000; nowMs += 1'000)
    assert(!finishCooldown.update(nowMs, wheel(3.0F, nowMs),
                                  ConfirmedLifecycle::Idle, ask));
  decision = finishCooldown.update(908'000, wheel(3.0F, 908'000),
                                   ConfirmedLifecycle::Idle, ask);
  assert(decision.transition == Transition::Start);

  RideAutomationPolicy finishStoppedRelease;
  assert(!finishStoppedRelease.update(0, {}, ConfirmedLifecycle::Finished,
                                      ask));
  for (uint32_t nowMs = 1'000; nowMs <= 121'000; nowMs += 1'000)
    assert(!finishStoppedRelease.update(nowMs, wheel(0.0F, nowMs),
                                        ConfirmedLifecycle::Idle, ask));
  for (uint32_t nowMs = 122'000; nowMs < 130'000; nowMs += 1'000)
    assert(!finishStoppedRelease.update(nowMs, wheel(3.0F, nowMs),
                                        ConfirmedLifecycle::Idle, ask));
  decision = finishStoppedRelease.update(130'000, wheel(3.0F, 130'000),
                                          ConfirmedLifecycle::Idle, ask);
  assert(decision.transition == Transition::Start);

  RideAutomationPolicy promptSnooze;
  decision = runSeconds(promptSnooze, 0, 9, ConfirmedLifecycle::Idle, ask,
                        3.0F);
  assert(decision.transition == Transition::Start);
  promptSnooze.snoozeStart(8'000);
  for (uint32_t nowMs = 9'000; nowMs < 908'000; nowMs += 10'000)
    assert(!promptSnooze.update(nowMs, wheel(3.0F, nowMs),
                                ConfirmedLifecycle::Idle, ask));
  for (uint32_t nowMs = 908'000; nowMs < 916'000; nowMs += 1'000)
    assert(!promptSnooze.update(nowMs, wheel(3.0F, nowMs),
                                ConfirmedLifecycle::Idle, ask));
  decision = promptSnooze.update(916'000, wheel(3.0F, 916'000),
                                 ConfirmedLifecycle::Idle, ask);
  assert(decision.transition == Transition::Start);

  RideAutomationPolicy promptStoppedRelease;
  decision = runSeconds(promptStoppedRelease, 0, 9,
                        ConfirmedLifecycle::Idle, ask, 3.0F);
  assert(decision.transition == Transition::Start);
  promptStoppedRelease.snoozeStart(8'000);
  for (uint32_t nowMs = 9'000; nowMs <= 129'000; nowMs += 1'000)
    assert(!promptStoppedRelease.update(nowMs, wheel(0.0F, nowMs),
                                        ConfirmedLifecycle::Idle, ask));
  for (uint32_t nowMs = 130'000; nowMs < 138'000; nowMs += 1'000)
    assert(!promptStoppedRelease.update(nowMs, wheel(3.0F, nowMs),
                                        ConfirmedLifecycle::Idle, ask));
  decision = promptStoppedRelease.update(138'000,
                                          wheel(3.0F, 138'000),
                                          ConfirmedLifecycle::Idle, ask);
  assert(decision.transition == Transition::Start);

  // A manual start gets the same fifteen-second pause grace as a manual
  // resume, followed by a fresh five-second pause candidate.
  RideAutomationPolicy manualStartGrace;
  manualStartGrace.noteManualRunningTransition(0);
  for (uint32_t nowMs = 0; nowMs < 20'000; nowMs += 1'000)
    assert(!manualStartGrace.update(nowMs, wheel(0.0F, nowMs),
                                    ConfirmedLifecycle::Running, ask));
  decision = manualStartGrace.update(20'000, wheel(0.0F, 20'000),
                                     ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  // Continuous timers retain their elapsed duration through millis() wrap.
  RideAutomationPolicy wrappedPause;
  const uint32_t pauseStart = std::numeric_limits<uint32_t>::max() - 2'500;
  assert(!wrappedPause.update(pauseStart, wheel(0.0F, pauseStart),
                              ConfirmedLifecycle::Running, ask));
  decision = wrappedPause.update(pauseStart + 5'000U,
                                 wheel(0.0F, pauseStart + 5'000U),
                                 ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  // Rejection suppresses immediate repeat requests and resets candidates.
  RideAutomationPolicy rejection;
  decision = runSeconds(rejection, 0, 9, ConfirmedLifecycle::Idle, ask, 2.0F);
  assert(decision.transition == Transition::Start);
  rejection.rejectPending(8'000);
  for (uint32_t nowMs = 9'000; nowMs < 13'000; nowMs += 1'000)
    assert(!rejection.update(nowMs, wheel(2.0F, nowMs),
                             ConfirmedLifecycle::Idle, ask));

  ShadowRuntime runtime;
  static_assert(!ShadowRuntime::kCanControlRide);
  decision = runtime.update(0, {}, ConfirmedLifecycle::Idle, ask);
  assert(!decision);
  runtime.update(1'000, wheel(2.0F, 1'000), ConfirmedLifecycle::Idle, ask);
  assert((runtime.lastEvidenceMask() & EvidenceWheelMoving) != 0);

  DetectionHealth health = resolveDetectionHealth({});
  assert(health.state == DetectionHealthState::NoExternalPosition);
  assert(!health.directSensorAvailable && !health.healthy());
  health = resolveDetectionHealth({false, true, false, false, false});
  assert(health.state == DetectionHealthState::PositionStale);
  health = resolveDetectionHealth({false, true, true, false, true});
  assert(health.state == DetectionHealthState::PositionLowQuality);
  health = resolveDetectionHealth({false, true, true, true, false});
  assert(health.state == DetectionHealthState::MotionUnavailable);
  health = resolveDetectionHealth({false, true, true, true, true});
  assert(health.state == DetectionHealthState::HealthyGpsAndMotion);
  assert(health.healthy() && !health.directSensorAvailable);
  health = resolveDetectionHealth({true, false, false, false, false});
  assert(health.state == DetectionHealthState::HealthyDirectSensor);
  assert(health.healthy() && health.directSensorAvailable);
  assert(!ride_automation_runtime::shouldShowAutomationPanel(
      ride_automation_runtime::UiPhase::SensorDegraded));
  assert(!ride_automation_runtime::shouldShowAutomationPanel(
      ride_automation_runtime::UiPhase::Hidden));
  assert(ride_automation_runtime::shouldShowAutomationPanel(
      ride_automation_runtime::UiPhase::StartPrompt));

  TraceRecord trace;
  trace.timestampMs = 123;
  trace.lifecycle = ConfirmedLifecycle::Idle;
  trace.decision = Decision{Transition::Start, 9, EvidenceWheelMoving,
                            SourceHealthWheelFresh, 1, 0, 123};
  trace.observation = wheel(2.0F, 123);
  trace.evidenceMask = EvidenceWheelMoving;
  trace.counters.start = 1;
  char json[2'048];
  const int length = formatTraceJsonLine(trace, json, sizeof(json));
  assert(length > 0 && static_cast<std::size_t>(length) < sizeof(json));
  assert(std::strstr(json, "\"schema\":3") != nullptr);
  assert(std::strstr(json, "\"profile\":3") != nullptr);
  assert(std::strstr(json, "\"gps_horizontal_uncertainty_m\"") !=
         nullptr);
  assert(std::strstr(json, "\"lifecycle\":\"idle\"") != nullptr);
  assert(std::strstr(json, "\"wheel_mps\":{") != nullptr);
  assert(std::strstr(json, "\"decision\":\"start\"") != nullptr);
  assert(std::strstr(json, "\"source_health_mask\":1") != nullptr);
  assert(std::strstr(json, "latitude") == nullptr);
  assert(std::strstr(json, "accelerometer") == nullptr);
  char tooSmall[8];
  assert(formatTraceJsonLine(trace, tooSmall, sizeof(tooSmall)) == -1);

  return 0;
}
