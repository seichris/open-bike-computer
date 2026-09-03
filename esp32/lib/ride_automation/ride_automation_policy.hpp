#pragma once

#include "ride_detection_profile.hpp"
#include "ride_evidence_window.hpp"

#include <cmath>
#include <cstdint>

namespace ride_automation {

enum class ConfirmedLifecycle : uint8_t {
  Idle = 0,
  Running,
  AutomaticallyPaused,
  ManuallyPaused,
  Finished,
};

enum class StartMode : uint8_t { Off = 0, Ask, Automatic };
enum class Transition : uint8_t { None = 0, Start, Pause, Resume };
enum class DetectorPhase : uint8_t {
  Quiet = 0,
  StartCandidate,
  AwaitingConfirmation,
  PauseCandidate,
  ResumeCandidate,
  RestartCooldown,
};

enum class SensorCombination : uint8_t {
  Neither = 0,
  SpeedOnly,
  CadenceOnly,
  SpeedAndCadence,
};

enum class MotionEvidenceState : uint8_t {
  Uncertain = 0,
  WheelMoving,
  WheelStopped,
  SlowCrawl,
  CadenceMoving,
  GpsImuMoving,
  GpsImuStopped,
  WatchGpsMoving,
  WatchGpsStopped,
  WheelDropout,
  SourceConflict,
};

struct DetectorStatus {
  DetectorPhase phase = DetectorPhase::Quiet;
  uint8_t progressPercent = 0;
};

enum EvidenceMask : uint16_t {
  EvidenceNone = 0,
  EvidenceWheelMoving = 1U << 0,
  EvidenceCadenceMoving = 1U << 1,
  EvidenceGpsMoving = 1U << 2,
  EvidenceImuMoving = 1U << 3,
  EvidenceWheelStopped = 1U << 4,
  EvidenceCadenceStopped = 1U << 5,
  EvidenceGpsStopped = 1U << 6,
  EvidenceImuStopped = 1U << 7,
  EvidenceGpsDisplacement = 1U << 8,
  EvidenceSourceConflict = 1U << 9,
  EvidenceWatchGpsMoving = 1U << 10,
  EvidenceWatchGpsStopped = 1U << 11,
};

enum SourceHealthMask : uint16_t {
  SourceHealthNone = 0,
  SourceHealthWheelFresh = 1U << 0,
  SourceHealthCadenceFresh = 1U << 1,
  SourceHealthGpsFresh = 1U << 2,
  SourceHealthImuFresh = 1U << 3,
  SourceHealthWatchGpsFresh = 1U << 4,
};

struct TimedMetric {
  bool available = false;
  float value = 0.0F;
  uint32_t capturedAtMs = 0;
  uint32_t maximumAgeMs = 0;
};

struct TimedFlag {
  bool available = false;
  bool value = false;
  uint32_t capturedAtMs = 0;
  uint32_t maximumAgeMs = 0;
};

struct RideEvidenceObservation {
  uint8_t gpsPositionSource = 0;
  TimedMetric wheelSpeedMetersPerSecond;
  TimedMetric cadenceRpm;
  TimedMetric gpsSpeedMetersPerSecond;
  TimedMetric imuMotionScore;
  TimedFlag gpsFixValid;
  TimedMetric gpsHorizontalUncertaintyMeters;
  TimedFlag gpsStationaryWindowValid;
  TimedMetric gpsNetDisplacementMeters;
  TimedMetric watchGpsSpeedMetersPerSecond;
  TimedMetric watchGpsHorizontalUncertaintyMeters;
  TimedFlag watchGpsFixValid;
  bool watchGpsSampleIdentityAvailable = false;
  uint16_t watchGpsSampleEpoch = 0;
  uint32_t watchGpsSampleSequence = 0;
};

struct Settings {
  StartMode startMode = StartMode::Ask;
  bool autoPauseEnabled = true;
};

struct Decision {
  Transition transition = Transition::None;
  uint32_t sequence = 0;
  uint16_t evidenceMask = EvidenceNone;
  uint16_t sourceHealthMask = SourceHealthNone;
  uint16_t profileVersion = 0;
  uint32_t candidateBeganAtMs = 0;
  uint32_t decidedAtMs = 0;

  explicit operator bool() const { return transition != Transition::None; }
};

struct ShadowCounters {
  uint32_t start = 0;
  uint32_t pause = 0;
  uint32_t resume = 0;
  uint32_t sourceConflict = 0;
};

constexpr bool metricFresh(const TimedMetric &metric, uint32_t nowMs,
                           uint32_t profileMaximumAgeMs) {
  const uint32_t maximumAge =
      metric.maximumAgeMs > 0 && metric.maximumAgeMs < profileMaximumAgeMs
          ? metric.maximumAgeMs
          : profileMaximumAgeMs;
  return metric.available && maximumAge > 0 &&
         elapsedMs(nowMs, metric.capturedAtMs) <= maximumAge;
}

constexpr bool flagFresh(const TimedFlag &flag, uint32_t nowMs,
                         uint32_t profileMaximumAgeMs) {
  const uint32_t maximumAge =
      flag.maximumAgeMs > 0 && flag.maximumAgeMs < profileMaximumAgeMs
          ? flag.maximumAgeMs
          : profileMaximumAgeMs;
  return flag.available && maximumAge > 0 &&
         elapsedMs(nowMs, flag.capturedAtMs) <= maximumAge;
}

inline bool nonnegativeFinite(float value) {
  return std::isfinite(value) && value >= 0.0F;
}

class RideAutomationPolicy {
public:
  explicit RideAutomationPolicy(
      RideDetectionProfile profile = kRideDetectionProfile)
      : profile_(profile) {}

  Decision update(uint32_t nowMs, const RideEvidenceObservation &observation,
                  ConfirmedLifecycle lifecycle, const Settings &settings) {
    detectorStatus_ = {};
    pendingCancellation_ = false;
    reconcileLifecycle(nowMs, lifecycle);

    const Normalized evidence = normalize(nowMs, observation);
    lastEvidenceMask_ = evidence.mask;
    lastSensorCombination_ = evidence.sensorCombination;
    if (evidence.wheelKnown)
      hasObservedWheelEvidence_ = true;
    lastMotionEvidenceState_ =
        classifyMotionEvidence(evidence, hasObservedWheelEvidence_);
    if (lifecycle == ConfirmedLifecycle::Idle) {
      startSensorWindow_.observe(nowMs, evidence.hasDirect,
                                 evidence.directMoving,
                                 evidence.directConflict);
      const bool gpsImuMoving = evidence.gpsMoving && evidence.imuMoving;
      startGpsImuWindow_.observe(
          nowMs, evidence.gpsKnown && evidence.imuKnown, gpsImuMoving,
          evidence.gpsKnown && evidence.imuKnown && !gpsImuMoving);
    }

    if (evidence.directConflict)
      saturatingIncrement(counters_.sourceConflict);

    if (pendingTransition_ != Transition::None) {
      if (pendingEvidenceContradicted(evidence)) {
        pendingTransition_ = Transition::None;
        pendingCancellation_ = true;
        clearCandidateLatches();
        startSensorWindow_.reset();
        startGpsImuWindow_.reset();
        return {};
      }
      detectorStatus_ = {DetectorPhase::AwaitingConfirmation, 100};
      return {};
    }

    switch (lifecycle) {
    case ConfirmedLifecycle::Idle:
      return evaluateStart(nowMs, evidence, settings);
    case ConfirmedLifecycle::Running:
      return evaluatePause(nowMs, evidence, settings);
    case ConfirmedLifecycle::AutomaticallyPaused:
      return evaluateResume(nowMs, evidence);
    case ConfirmedLifecycle::ManuallyPaused:
    case ConfirmedLifecycle::Finished:
      clearCandidateLatches();
      return {};
    }
    return {};
  }

  const ShadowCounters &counters() const { return counters_; }
  Transition pendingTransition() const { return pendingTransition_; }
  uint16_t lastEvidenceMask() const { return lastEvidenceMask_; }
  SensorCombination lastSensorCombination() const {
    return lastSensorCombination_;
  }
  MotionEvidenceState lastMotionEvidenceState() const {
    return lastMotionEvidenceState_;
  }
  DetectorStatus detectorStatus() const { return detectorStatus_; }
  bool startSuppressionActive() const { return startSuppressionActive_; }
  bool takePendingCancellation() {
    const bool value = pendingCancellation_;
    pendingCancellation_ = false;
    return value;
  }

  void rejectPending(uint32_t nowMs) {
    pendingTransition_ = Transition::None;
    suppressUntilMs_ = nowMs + profile_.decisionRetrySuppressionMs;
    suppressionActive_ = true;
    clearCandidateLatches();
  }

  void snoozeStart(uint32_t nowMs) {
    if (pendingTransition_ == Transition::Start)
      pendingTransition_ = Transition::None;
    beginStartSuppression(nowMs, profile_.promptSnoozeMaximumMs);
    startSensorWindow_.reset();
    startGpsImuWindow_.reset();
  }

  // A rider-initiated start/resume owns the workout boundary. Suppress pause
  // evidence long enough that stationary startup handling cannot immediately
  // undo the rider's action.
  void noteManualRunningTransition(uint32_t nowMs) {
    pauseSuppressedUntilMs_ = nowMs + profile_.manualResumeGraceMs;
    pauseSuppressionActive_ = true;
    pauseLatch_.reset();
    watchPauseLatch_.reset();
    pausePath_ = PausePath::None;
  }

  void reset() {
    *this = RideAutomationPolicy(profile_);
  }

private:
  struct Normalized {
    bool wheelKnown = false;
    bool cadenceKnown = false;
    bool hasDirect = false;
    bool wheelMoving = false;
    bool cadenceMoving = false;
    bool directMoving = false;
    bool wheelStopped = false;
    bool cadenceStopped = false;
    bool allDirectStopped = false;
    bool directConflict = false;
    bool gpsKnown = false;
    bool gpsMoving = false;
    bool gpsResumeMoving = false;
    bool gpsStopped = false;
    bool gpsDisplacedForAsk = false;
    bool gpsDisplacedForAutomatic = false;
    bool imuKnown = false;
    bool imuMoving = false;
    bool imuStopped = false;
    bool watchGpsKnown = false;
    bool watchGpsMoving = false;
    bool watchGpsStopped = false;
    uint16_t watchGpsSampleEpoch = 0;
    uint32_t watchGpsSampleSequence = 0;
    uint32_t watchGpsCapturedAtMs = 0;
    SensorCombination sensorCombination = SensorCombination::Neither;
    uint16_t mask = EvidenceNone;
    uint16_t sourceHealthMask = SourceHealthNone;
  };

  enum class PausePath : uint8_t { None = 0, WatchGps, Direct, GpsImu };

  bool pendingEvidenceContradicted(const Normalized &evidence) const {
    switch (pendingTransition_) {
    case Transition::Start:
      return hasConfirmedStoppedEvidence(evidence);
    case Transition::Pause:
      return hasConfirmedMovingEvidence(evidence);
    case Transition::Resume:
      return hasConfirmedStoppedEvidence(evidence);
    case Transition::None:
      return false;
    }
    return false;
  }

  static bool hasConfirmedMovingEvidence(const Normalized &evidence) {
    return evidence.wheelMoving || evidence.cadenceMoving ||
           evidence.watchGpsMoving ||
           (evidence.gpsKnown && evidence.imuKnown &&
            evidence.gpsResumeMoving && evidence.imuMoving);
  }

  static bool hasConfirmedStoppedEvidence(const Normalized &evidence) {
    if (evidence.watchGpsKnown)
      return evidence.watchGpsStopped;
    if (evidence.wheelKnown) {
      return evidence.wheelStopped &&
             (!evidence.cadenceKnown || evidence.cadenceStopped);
    }
    return !evidence.cadenceMoving && evidence.gpsKnown && evidence.imuKnown &&
           evidence.gpsStopped && evidence.imuStopped;
  }

  static MotionEvidenceState
  classifyMotionEvidence(const Normalized &evidence,
                         bool hasObservedWheelEvidence) {
    if (evidence.directConflict)
      return MotionEvidenceState::SourceConflict;
    if (evidence.wheelMoving)
      return MotionEvidenceState::WheelMoving;
    if (evidence.cadenceMoving)
      return MotionEvidenceState::CadenceMoving;
    if (evidence.watchGpsMoving)
      return MotionEvidenceState::WatchGpsMoving;
    if (evidence.watchGpsStopped)
      return MotionEvidenceState::WatchGpsStopped;
    if (evidence.wheelStopped)
      return MotionEvidenceState::WheelStopped;
    if (evidence.wheelKnown)
      return MotionEvidenceState::SlowCrawl;
    if (evidence.gpsKnown && evidence.imuKnown &&
        evidence.gpsResumeMoving && evidence.imuMoving)
      return MotionEvidenceState::GpsImuMoving;
    if (evidence.gpsKnown && evidence.imuKnown && evidence.gpsStopped &&
        evidence.imuStopped)
      return MotionEvidenceState::GpsImuStopped;
    if (hasObservedWheelEvidence)
      return MotionEvidenceState::WheelDropout;
    return MotionEvidenceState::Uncertain;
  }

  static void saturatingIncrement(uint32_t &value) {
    if (value != UINT32_MAX)
      ++value;
  }

  static uint8_t progressPercent(uint32_t value, uint32_t required) {
    if (required == 0 || value >= required)
      return 100;
    return static_cast<uint8_t>((value * 100U) / required);
  }

  bool suppressionElapsed(uint32_t nowMs) {
    if (!suppressionActive_)
      return true;
    if (static_cast<int32_t>(nowMs - suppressUntilMs_) < 0)
      return false;
    suppressionActive_ = false;
    return true;
  }

  static bool deadlineElapsed(uint32_t nowMs, uint32_t deadlineMs) {
    return static_cast<int32_t>(nowMs - deadlineMs) >= 0;
  }

  bool startSuppressionElapsed(uint32_t nowMs,
                               const Normalized &evidence) {
    if (!startSuppressionActive_)
      return true;
    const bool stopped = hasConfirmedStoppedEvidence(evidence);
    const bool stoppedLongEnough = startSuppressionStoppedLatch_.update(
        nowMs, stopped, profile_.startSuppressionStoppedMs);
    if (!stoppedLongEnough &&
        !deadlineElapsed(nowMs, startSuppressedUntilMs_)) {
      return false;
    }
    startSuppressionActive_ = false;
    startSuppressionStoppedLatch_.reset();
    return true;
  }

  void beginStartSuppression(uint32_t nowMs, uint32_t maximumMs) {
    startSuppressedUntilMs_ = nowMs + maximumMs;
    startSuppressionActive_ = true;
    startSuppressionStoppedLatch_.reset();
  }

  bool pauseSuppressionElapsed(uint32_t nowMs) {
    if (!pauseSuppressionActive_)
      return true;
    if (!deadlineElapsed(nowMs, pauseSuppressedUntilMs_))
      return false;
    pauseSuppressionActive_ = false;
    return true;
  }

  Normalized normalize(uint32_t nowMs,
                       const RideEvidenceObservation &observation) const {
    Normalized result;
    result.wheelKnown =
        metricFresh(observation.wheelSpeedMetersPerSecond, nowMs,
                    profile_.wheelFreshnessMs) &&
        nonnegativeFinite(observation.wheelSpeedMetersPerSecond.value);
    result.cadenceKnown =
        metricFresh(observation.cadenceRpm, nowMs,
                    profile_.cadenceFreshnessMs) &&
        nonnegativeFinite(observation.cadenceRpm.value);
    result.hasDirect = result.wheelKnown || result.cadenceKnown;
    if (result.wheelKnown && result.cadenceKnown) {
      result.sensorCombination = SensorCombination::SpeedAndCadence;
    } else if (result.wheelKnown) {
      result.sensorCombination = SensorCombination::SpeedOnly;
    } else if (result.cadenceKnown) {
      result.sensorCombination = SensorCombination::CadenceOnly;
    }
    result.wheelMoving =
        result.wheelKnown && observation.wheelSpeedMetersPerSecond.value >=
                                 profile_.wheelMovingMetersPerSecond;
    result.cadenceMoving =
        result.cadenceKnown &&
        observation.cadenceRpm.value >= profile_.cadenceMovingRpm;
    result.directMoving = result.wheelMoving || result.cadenceMoving;
    result.wheelStopped =
        result.wheelKnown && observation.wheelSpeedMetersPerSecond.value <
                                 profile_.wheelStoppedMetersPerSecond;
    result.cadenceStopped =
        result.cadenceKnown &&
        observation.cadenceRpm.value < profile_.cadenceStoppedRpm;
    result.allDirectStopped =
        result.hasDirect && (!result.wheelKnown || result.wheelStopped) &&
        (!result.cadenceKnown || result.cadenceStopped);
    // A moving source always vetoes a pause. A disagreement is explicit when
    // one fresh direct source is moving and the other says stopped.
    result.directConflict =
        result.wheelKnown && result.cadenceKnown &&
        ((result.wheelMoving && result.cadenceStopped) ||
         (result.cadenceMoving && result.wheelStopped));

    const bool gpsSpeedFresh = metricFresh(
        observation.gpsSpeedMetersPerSecond, nowMs, profile_.gpsFreshnessMs);
    const bool gpsFixFresh =
        flagFresh(observation.gpsFixValid, nowMs, profile_.gpsFreshnessMs);
    const bool gpsUncertaintyFresh = metricFresh(
        observation.gpsHorizontalUncertaintyMeters, nowMs,
        profile_.gpsFreshnessMs);
    result.gpsKnown = gpsSpeedFresh &&
                      nonnegativeFinite(
                          observation.gpsSpeedMetersPerSecond.value) &&
                      gpsFixFresh && observation.gpsFixValid.value &&
                      gpsUncertaintyFresh &&
                      nonnegativeFinite(
                          observation.gpsHorizontalUncertaintyMeters.value) &&
                      observation.gpsHorizontalUncertaintyMeters.value <=
                          profile_.maximumGpsHorizontalUncertaintyMeters;
    result.gpsMoving =
        result.gpsKnown && observation.gpsSpeedMetersPerSecond.value >=
                               profile_.gpsStartMetersPerSecond;
    result.gpsResumeMoving =
        result.gpsKnown && observation.gpsSpeedMetersPerSecond.value >=
                               profile_.gpsResumeMetersPerSecond;
    result.gpsStopped =
        result.gpsKnown &&
        flagFresh(observation.gpsStationaryWindowValid, nowMs,
                  profile_.gpsFreshnessMs) &&
        observation.gpsStationaryWindowValid.value &&
        observation.gpsSpeedMetersPerSecond.value <
            profile_.gpsStoppedMetersPerSecond;
    const bool gpsDisplacementFresh = metricFresh(
        observation.gpsNetDisplacementMeters, nowMs, profile_.gpsFreshnessMs);
    result.gpsDisplacedForAsk =
        result.gpsKnown && gpsDisplacementFresh &&
        nonnegativeFinite(observation.gpsNetDisplacementMeters.value) &&
        observation.gpsNetDisplacementMeters.value >=
                               profile_.gpsImuAskDisplacementMeters;
    result.gpsDisplacedForAutomatic =
        result.gpsKnown && gpsDisplacementFresh &&
        nonnegativeFinite(observation.gpsNetDisplacementMeters.value) &&
        observation.gpsNetDisplacementMeters.value >=
                               profile_.gpsImuAutomaticDisplacementMeters;

    result.imuKnown = metricFresh(observation.imuMotionScore, nowMs,
                                  profile_.imuFreshnessMs) &&
                      std::isfinite(observation.imuMotionScore.value) &&
                      observation.imuMotionScore.value >= 0.0F &&
                      observation.imuMotionScore.value <= 1.0F;
    result.imuMoving = result.imuKnown &&
                       observation.imuMotionScore.value >=
                           profile_.imuMovingScore;
    result.imuStopped = result.imuKnown &&
                        observation.imuMotionScore.value <=
                            profile_.imuStoppedScore;

    const bool watchSpeedFresh = metricFresh(
        observation.watchGpsSpeedMetersPerSecond, nowMs,
        profile_.watchGpsFreshnessMs);
    const bool watchFixFresh = flagFresh(
        observation.watchGpsFixValid, nowMs,
        profile_.watchGpsFreshnessMs);
    const bool watchAccuracyFresh = metricFresh(
        observation.watchGpsHorizontalUncertaintyMeters, nowMs,
        profile_.watchGpsFreshnessMs);
    result.watchGpsKnown =
        watchSpeedFresh &&
        nonnegativeFinite(observation.watchGpsSpeedMetersPerSecond.value) &&
        watchFixFresh && observation.watchGpsFixValid.value &&
        watchAccuracyFresh &&
        nonnegativeFinite(
            observation.watchGpsHorizontalUncertaintyMeters.value) &&
        observation.watchGpsHorizontalUncertaintyMeters.value <=
            profile_.maximumWatchGpsHorizontalUncertaintyMeters &&
        observation.watchGpsSampleIdentityAvailable &&
        observation.watchGpsSampleEpoch != 0 &&
        observation.watchGpsSampleSequence != 0;
    result.watchGpsMoving =
        result.watchGpsKnown &&
        observation.watchGpsSpeedMetersPerSecond.value >=
            profile_.watchGpsResumeMetersPerSecond;
    result.watchGpsStopped =
        result.watchGpsKnown &&
        observation.watchGpsSpeedMetersPerSecond.value <
            profile_.watchGpsStoppedMetersPerSecond;
    result.watchGpsSampleEpoch = observation.watchGpsSampleEpoch;
    result.watchGpsSampleSequence = observation.watchGpsSampleSequence;
    result.watchGpsCapturedAtMs =
        observation.watchGpsSpeedMetersPerSecond.capturedAtMs;

    if (result.wheelKnown)
      result.sourceHealthMask |= SourceHealthWheelFresh;
    if (result.cadenceKnown)
      result.sourceHealthMask |= SourceHealthCadenceFresh;
    if (result.gpsKnown)
      result.sourceHealthMask |= SourceHealthGpsFresh;
    if (result.imuKnown)
      result.sourceHealthMask |= SourceHealthImuFresh;
    if (result.watchGpsKnown)
      result.sourceHealthMask |= SourceHealthWatchGpsFresh;

    if (result.wheelMoving)
      result.mask |= EvidenceWheelMoving;
    if (result.cadenceMoving)
      result.mask |= EvidenceCadenceMoving;
    if (result.gpsMoving || result.gpsResumeMoving)
      result.mask |= EvidenceGpsMoving;
    if (result.imuMoving)
      result.mask |= EvidenceImuMoving;
    if (result.wheelStopped)
      result.mask |= EvidenceWheelStopped;
    if (result.cadenceStopped)
      result.mask |= EvidenceCadenceStopped;
    if (result.gpsStopped)
      result.mask |= EvidenceGpsStopped;
    if (result.imuStopped)
      result.mask |= EvidenceImuStopped;
    if (result.gpsDisplacedForAsk)
      result.mask |= EvidenceGpsDisplacement;
    if (result.directConflict)
      result.mask |= EvidenceSourceConflict;
    if (result.watchGpsMoving)
      result.mask |= EvidenceWatchGpsMoving;
    if (result.watchGpsStopped)
      result.mask |= EvidenceWatchGpsStopped;
    return result;
  }

  Decision evaluateStart(uint32_t nowMs, const Normalized &evidence,
                         const Settings &settings) {
    pauseLatch_.reset();
    resumeLatch_.reset();
    watchPauseLatch_.reset();
    watchResumeLatch_.reset();
    if (settings.startMode == StartMode::Off || !suppressionElapsed(nowMs) ||
        !startSuppressionElapsed(nowMs, evidence)) {
      if (settings.startMode != StartMode::Off &&
          (suppressionActive_ || startSuppressionActive_)) {
        detectorStatus_ = {DetectorPhase::RestartCooldown, 0};
      }
      startSensorWindow_.reset();
      startGpsImuWindow_.reset();
      return {};
    }

    const auto sensorCounts = startSensorWindow_.counts(
        nowMs, profile_.sensorStartWindowSeconds);
    const uint8_t requiredSensorSeconds =
        settings.startMode == StartMode::Automatic
            ? profile_.sensorAutomaticPositiveSeconds
            : profile_.sensorStartPositiveSeconds;
    const bool sensorReady =
        sensorCounts.positive >= requiredSensorSeconds &&
        sensorCounts.contradictory == 0;

    const auto gpsCounts = startGpsImuWindow_.counts(
        nowMs, settings.startMode == StartMode::Automatic
                   ? profile_.gpsImuAutomaticWindowSeconds
                   : profile_.gpsImuAskWindowSeconds);
    const uint8_t requiredGpsSeconds =
        settings.startMode == StartMode::Automatic
            ? profile_.gpsImuAutomaticPositiveSeconds
            : profile_.gpsImuAskPositiveSeconds;
    const bool gpsReady = settings.startMode == StartMode::Automatic
                              ? gpsCounts.positive >= requiredGpsSeconds &&
                                    evidence.gpsDisplacedForAutomatic
                              : gpsCounts.positive >= requiredGpsSeconds &&
                                    evidence.gpsDisplacedForAsk;
    const uint8_t sensorProgress = progressPercent(
        sensorCounts.positive, requiredSensorSeconds);
    const uint8_t gpsProgress = progressPercent(
        gpsCounts.positive, requiredGpsSeconds);
    if (sensorCounts.positive > 0 || gpsCounts.positive > 0) {
      detectorStatus_ = {
          DetectorPhase::StartCandidate,
          sensorProgress > gpsProgress ? sensorProgress : gpsProgress};
    }
    if (!sensorReady && !gpsReady)
      return {};
    return emit(Transition::Start, nowMs, evidence.mask,
                evidence.sourceHealthMask,
                sensorReady ? nowMs - requiredSensorSeconds * 1'000U
                            : nowMs - requiredGpsSeconds * 1'000U);
  }

  Decision evaluatePause(uint32_t nowMs, const Normalized &evidence,
                         const Settings &settings) {
    if (!settings.autoPauseEnabled || !suppressionElapsed(nowMs) ||
        !pauseSuppressionElapsed(nowMs)) {
      pauseLatch_.reset();
      watchPauseLatch_.reset();
      pausePath_ = PausePath::None;
      return {};
    }
    resumeLatch_.reset();
    watchResumeLatch_.reset();

    if (evidence.directConflict) {
      pauseLatch_.reset();
      pausePath_ = PausePath::None;
      return {};
    }
    if (evidence.wheelMoving) {
      pauseLatch_.reset();
      pausePath_ = PausePath::None;
      return {};
    }
    if (evidence.cadenceMoving) {
      pauseLatch_.reset();
      pausePath_ = PausePath::None;
      return {};
    }
    if (evidence.gpsKnown && evidence.imuKnown &&
        evidence.gpsResumeMoving && evidence.imuMoving) {
      pauseLatch_.reset();
      pausePath_ = PausePath::None;
      return {};
    }

    if (evidence.watchGpsMoving) {
      pauseLatch_.reset();
      watchPauseLatch_.reset();
      pausePath_ = PausePath::None;
      return {};
    }

    bool condition = false;
    uint32_t requiredMs = 0;
    if (evidence.watchGpsKnown) {
      pauseLatch_.reset();
      pausePath_ = PausePath::WatchGps;
      const bool ready = watchPauseLatch_.update(
          true, evidence.watchGpsStopped, evidence.watchGpsSampleEpoch,
          evidence.watchGpsSampleSequence, evidence.watchGpsCapturedAtMs,
          profile_.watchGpsPauseMs, profile_.watchGpsMaximumSampleGapMs);
      if (!ready) {
        if (watchPauseLatch_.active()) {
          detectorStatus_ = {
              DetectorPhase::PauseCandidate,
              progressPercent(watchPauseLatch_.spanMs(),
                              profile_.watchGpsPauseMs)};
        }
        return {};
      }
      return emit(Transition::Pause, nowMs, evidence.mask,
                  evidence.sourceHealthMask,
                  watchPauseLatch_.beganAtMs());
    }
    watchPauseLatch_.reset();
    if (evidence.wheelKnown) {
      if (pausePath_ != PausePath::Direct) {
        pauseLatch_.reset();
        pausePath_ = PausePath::Direct;
      }
      condition = evidence.wheelStopped &&
                  (!evidence.cadenceKnown || evidence.cadenceStopped);
      requiredMs = profile_.sensorPauseMs;
    } else {
      if (!evidence.gpsKnown || !evidence.imuKnown) {
        pauseLatch_.reset();
        pausePath_ = PausePath::None;
        return {};
      }
      if (pausePath_ != PausePath::GpsImu) {
        pauseLatch_.reset();
        pausePath_ = PausePath::GpsImu;
      }
      condition = evidence.gpsStopped && evidence.imuStopped;
      requiredMs = profile_.gpsImuPauseMs;
    }
    if (!pauseLatch_.update(nowMs, condition, requiredMs))
    {
      if (pauseLatch_.active()) {
        detectorStatus_ = {
            DetectorPhase::PauseCandidate,
            progressPercent(pauseLatch_.accumulatedMs(nowMs), requiredMs)};
      }
      return {};
    }
    return emit(Transition::Pause, nowMs, evidence.mask,
                evidence.sourceHealthMask,
                pauseLatch_.beganAtMs());
  }

  Decision evaluateResume(uint32_t nowMs, const Normalized &evidence) {
    pauseLatch_.reset();
    watchPauseLatch_.reset();
    if (!suppressionElapsed(nowMs)) {
      resumeLatch_.reset();
      watchResumeLatch_.reset();
      return {};
    }
    const bool directPath = evidence.directMoving;
    const bool watchReady = watchResumeLatch_.update(
        evidence.watchGpsKnown, evidence.watchGpsMoving,
        evidence.watchGpsSampleEpoch, evidence.watchGpsSampleSequence,
        evidence.watchGpsCapturedAtMs, profile_.watchGpsResumeMs,
        profile_.watchGpsMaximumSampleGapMs);
    const bool gpsPath = !evidence.watchGpsKnown && !evidence.wheelKnown &&
                         !evidence.cadenceMoving &&
                         evidence.gpsResumeMoving && evidence.imuMoving;
    const uint32_t requiredMs =
        directPath ? profile_.sensorResumeMs : profile_.gpsImuResumeMs;
    const bool fallbackReady = resumeLatch_.update(
        nowMs, directPath || gpsPath, requiredMs);
    if (!watchReady && !fallbackReady) {
      if (watchResumeLatch_.active() || resumeLatch_.active()) {
        const uint8_t watchProgress = progressPercent(
            watchResumeLatch_.spanMs(), profile_.watchGpsResumeMs);
        const uint8_t fallbackProgress = progressPercent(
            resumeLatch_.accumulatedMs(nowMs), requiredMs);
        detectorStatus_ = {
            DetectorPhase::ResumeCandidate,
            watchProgress > fallbackProgress
                ? watchProgress : fallbackProgress};
      }
      return {};
    }
    return emit(Transition::Resume, nowMs, evidence.mask,
                evidence.sourceHealthMask,
                watchReady ? watchResumeLatch_.beganAtMs()
                           : resumeLatch_.beganAtMs());
  }

  Decision emit(Transition transition, uint32_t nowMs, uint16_t evidenceMask,
                uint16_t sourceHealthMask,
                uint32_t candidateBeganAtMs) {
    pendingTransition_ = transition;
    detectorStatus_ = {DetectorPhase::AwaitingConfirmation, 100};
    if (++nextSequence_ == 0)
      ++nextSequence_;
    switch (transition) {
    case Transition::Start:
      saturatingIncrement(counters_.start);
      break;
    case Transition::Pause:
      saturatingIncrement(counters_.pause);
      break;
    case Transition::Resume:
      saturatingIncrement(counters_.resume);
      break;
    case Transition::None:
      break;
    }
    return Decision{transition, nextSequence_, evidenceMask,
                    sourceHealthMask, profile_.version,
                    candidateBeganAtMs, nowMs};
  }

  void reconcileLifecycle(uint32_t nowMs, ConfirmedLifecycle lifecycle) {
    if (!lifecycleInitialized_) {
      lifecycleInitialized_ = true;
      lastLifecycle_ = lifecycle;
      if (lifecycle == ConfirmedLifecycle::Finished) {
        beginStartSuppression(nowMs, profile_.finishCooldownMaximumMs);
      }
      return;
    }
    if (lifecycle == lastLifecycle_)
      return;
    const ConfirmedLifecycle previous = lastLifecycle_;
    lastLifecycle_ = lifecycle;
    pendingTransition_ = Transition::None;
    clearCandidateLatches();
    startSensorWindow_.reset();
    startGpsImuWindow_.reset();
    if (lifecycle == ConfirmedLifecycle::Finished) {
      hasObservedWheelEvidence_ = false;
      beginStartSuppression(nowMs, profile_.finishCooldownMaximumMs);
    }
    if (previous == ConfirmedLifecycle::ManuallyPaused &&
        lifecycle == ConfirmedLifecycle::Running) {
      noteManualRunningTransition(nowMs);
    }
  }

  void clearCandidateLatches() {
    pauseLatch_.reset();
    watchPauseLatch_.reset();
    pausePath_ = PausePath::None;
    resumeLatch_.reset();
    watchResumeLatch_.reset();
  }

  RideDetectionProfile profile_;
  EvidenceWindow<24> startSensorWindow_;
  EvidenceWindow<24> startGpsImuWindow_;
  DurationLatch pauseLatch_;
  SampleSpanLatch watchPauseLatch_;
  PausePath pausePath_ = PausePath::None;
  DurationLatch resumeLatch_;
  SampleSpanLatch watchResumeLatch_;
  bool lifecycleInitialized_ = false;
  ConfirmedLifecycle lastLifecycle_ = ConfirmedLifecycle::Idle;
  Transition pendingTransition_ = Transition::None;
  bool pendingCancellation_ = false;
  uint32_t nextSequence_ = 0;
  bool suppressionActive_ = false;
  uint32_t suppressUntilMs_ = 0;
  bool startSuppressionActive_ = false;
  uint32_t startSuppressedUntilMs_ = 0;
  DurationLatch startSuppressionStoppedLatch_;
  bool pauseSuppressionActive_ = false;
  uint32_t pauseSuppressedUntilMs_ = 0;
  ShadowCounters counters_{};
  uint16_t lastEvidenceMask_ = EvidenceNone;
  SensorCombination lastSensorCombination_ = SensorCombination::Neither;
  MotionEvidenceState lastMotionEvidenceState_ =
      MotionEvidenceState::Uncertain;
  bool hasObservedWheelEvidence_ = false;
  DetectorStatus detectorStatus_{};
};

} // namespace ride_automation
