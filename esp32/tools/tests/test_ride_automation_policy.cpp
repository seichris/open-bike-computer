#include "../../lib/ride_automation/outstanding_decision_tracker.hpp"
#include "../../lib/ride_automation/ride_automation_runtime.hpp"
#include "../../lib/ride_automation/ride_automation_trace.hpp"
#include "../../lib/ride_automation/ride_automation_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <limits>
#include <cstdlib>
#include <fstream>

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

RideEvidenceObservation watchGps(float metersPerSecond, uint32_t nowMs,
                                 uint32_t sequence,
                                 float horizontalAccuracyMeters = 5.0F,
                                 uint16_t epoch = 1) {
  RideEvidenceObservation observation;
  observation.watchGpsSpeedMetersPerSecond =
      metric(metersPerSecond, nowMs);
  observation.watchGpsHorizontalUncertaintyMeters =
      metric(horizontalAccuracyMeters, nowMs);
  observation.watchGpsFixValid = flag(true, nowMs);
  observation.watchGpsSampleIdentityAvailable = true;
  observation.watchGpsSampleEpoch = epoch;
  observation.watchGpsSampleSequence = sequence;
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

RideEvidenceObservation withWatchGps(RideEvidenceObservation observation,
                                     const RideEvidenceObservation &watch) {
  observation.watchGpsSpeedMetersPerSecond =
      watch.watchGpsSpeedMetersPerSecond;
  observation.watchGpsHorizontalUncertaintyMeters =
      watch.watchGpsHorizontalUncertaintyMeters;
  observation.watchGpsFixValid = watch.watchGpsFixValid;
  observation.watchGpsSampleIdentityAvailable =
      watch.watchGpsSampleIdentityAvailable;
  observation.watchGpsSampleEpoch = watch.watchGpsSampleEpoch;
  observation.watchGpsSampleSequence = watch.watchGpsSampleSequence;
  return observation;
}

// The device reconciles the one decision it is waiting on against workout
// telemetry. These cases model what the Watch reports around a transition.
void testOutstandingDecisionTracker() {
  using ride_automation_runtime::kOriginConfirmationGraceMs;
  using ride_automation_runtime::ObservedWorkout;
  using ride_automation_runtime::OutstandingDecisionTracker;
  using workout_telemetry_protocol::PauseOrigin;
  using workout_telemetry_protocol::SessionState;
  using WireTransition = ride_automation_protocol::Transition;

  const auto workout = [](SessionState state, PauseOrigin pauseOrigin,
                          PauseOrigin lastTransitionOrigin,
                          bool originReceived = true) {
    ObservedWorkout observed;
    observed.sessionState = state;
    observed.originReceived = originReceived;
    observed.pauseOrigin = pauseOrigin;
    observed.lastTransitionOrigin = lastTransitionOrigin;
    return observed;
  };
  const auto began = [](WireTransition transition) {
    OutstandingDecisionTracker tracker;
    tracker.begin(transition);
    return tracker;
  };
  constexpr uint32_t grace = kOriginConfirmationGraceMs;

  // No decision, nothing to contradict.
  OutstandingDecisionTracker idle;
  assert(!idle.observe(
      workout(SessionState::Ended, PauseOrigin::None, PauseOrigin::Manual),
      0));

  // A pause decision is never contradicted by the origin of the running state
  // it started from: that origin describes an older transition, such as the
  // rider's manual start, or the Watch's marker for this very request.
  for (PauseOrigin earlier :
       {PauseOrigin::Manual, PauseOrigin::System, PauseOrigin::Unknown,
        PauseOrigin::Automatic, PauseOrigin::None}) {
    auto pause = began(WireTransition::Pause);
    for (uint32_t nowMs = 0; nowMs < 30'000; nowMs += 1'000) {
      assert(!pause.observe(
          workout(SessionState::Running, PauseOrigin::None, earlier), nowMs));
      assert(!pause.pauseOriginPending());
    }
  }

  // The pause lands. The origin is absent, then unknown while the Watch
  // writes its marker, then automatic. Nothing in that sequence contradicts,
  // and the unconfirmed pause is reported as pending.
  auto pauseLands = began(WireTransition::Pause);
  assert(!pauseLands.observe(
      workout(SessionState::Running, PauseOrigin::None, PauseOrigin::Manual),
      0));
  assert(!pauseLands.observe(
      workout(SessionState::Running, PauseOrigin::None, PauseOrigin::Unknown),
      1'000));
  assert(!pauseLands.observe(
      workout(SessionState::Paused, PauseOrigin::None, PauseOrigin::None,
              false),
      2'000));
  assert(pauseLands.pauseOriginPending());
  assert(!pauseLands.observe(
      workout(SessionState::Paused, PauseOrigin::Unknown,
              PauseOrigin::Unknown),
      3'000));
  assert(pauseLands.pauseOriginPending());
  assert(!pauseLands.observe(
      workout(SessionState::Paused, PauseOrigin::Automatic,
              PauseOrigin::Automatic),
      4'000));
  assert(!pauseLands.pauseOriginPending());

  // The rider's own pause retires the decision at once.
  for (PauseOrigin riders : {PauseOrigin::Manual, PauseOrigin::System}) {
    auto pause = began(WireTransition::Pause);
    assert(pause.observe(workout(SessionState::Paused, riders, riders),
                         1'000));
    assert(!pause.pauseOriginPending());
  }

  // An origin that is still unknown after the grace was not the detector's.
  auto unknownPause = began(WireTransition::Pause);
  const ObservedWorkout pausedUnknown = workout(
      SessionState::Paused, PauseOrigin::Unknown, PauseOrigin::Unknown);
  assert(!unknownPause.observe(pausedUnknown, 1'000));
  assert(!unknownPause.observe(pausedUnknown, 1'000 + grace - 1));
  assert(unknownPause.pauseOriginPending());
  assert(unknownPause.observe(pausedUnknown, 1'000 + grace));
  assert(!unknownPause.pauseOriginPending());

  // The grace is measured on the wrapping millisecond clock.
  auto wrappingPause = began(WireTransition::Pause);
  const uint32_t beforeWrap = std::numeric_limits<uint32_t>::max() - 1'000;
  assert(!wrappingPause.observe(pausedUnknown, beforeWrap));
  assert(!wrappingPause.observe(pausedUnknown, beforeWrap + grace - 1));
  assert(wrappingPause.observe(pausedUnknown, beforeWrap + grace));

  // An absent origin never contradicts by itself, but after the grace it no
  // longer holds the lifecycle either.
  auto absentOrigin = began(WireTransition::Pause);
  const ObservedWorkout pausedNoOrigin = workout(
      SessionState::Paused, PauseOrigin::None, PauseOrigin::None, false);
  assert(!absentOrigin.observe(pausedNoOrigin, 1'000));
  assert(absentOrigin.pauseOriginPending());
  assert(!absentOrigin.observe(pausedNoOrigin, 1'000 + grace));
  assert(!absentOrigin.pauseOriginPending());
  assert(!absentOrigin.observe(pausedNoOrigin, 29'000));

  // The origin frame can lag the state change. The Watch's marker window only
  // begins when it reports unknown, so that first sighting gets a full grace
  // even if the wait for the frame already used one up.
  auto lateOriginFrame = began(WireTransition::Pause);
  assert(!lateOriginFrame.observe(pausedNoOrigin, 1'000));
  assert(!lateOriginFrame.observe(pausedNoOrigin, 1'000 + grace - 1));
  assert(lateOriginFrame.pauseOriginPending());
  assert(!lateOriginFrame.observe(pausedUnknown, 1'000 + grace));
  assert(lateOriginFrame.pauseOriginPending());
  assert(!lateOriginFrame.observe(pausedUnknown, 1'000 + 2 * grace - 1));
  assert(lateOriginFrame.pauseOriginPending());
  assert(lateOriginFrame.observe(pausedUnknown, 1'000 + 2 * grace));
  assert(!lateOriginFrame.pauseOriginPending());
  auto lateOriginThenAutomatic = began(WireTransition::Pause);
  assert(!lateOriginThenAutomatic.observe(pausedNoOrigin, 1'000));
  assert(!lateOriginThenAutomatic.observe(pausedUnknown, 1'000 + grace));
  assert(!lateOriginThenAutomatic.observe(
      workout(SessionState::Paused, PauseOrigin::Automatic,
              PauseOrigin::Automatic),
      2'000 + grace));

  // The grace restarts only for the first unknown sighting in a state: an
  // origin that alternates between unknown and absent cannot extend it.
  auto alternatingOrigin = began(WireTransition::Pause);
  const ObservedWorkout pausedOriginCleared = workout(
      SessionState::Paused, PauseOrigin::None, PauseOrigin::None);
  assert(!alternatingOrigin.observe(pausedUnknown, 0));
  assert(!alternatingOrigin.observe(pausedOriginCleared, grace - 2));
  assert(!alternatingOrigin.observe(pausedUnknown, grace - 1));
  assert(alternatingOrigin.observe(pausedUnknown, grace));

  // A pause that landed and was then undone is spent, whoever resumed it. A
  // retry must not pause the ride a second time.
  for (PauseOrigin resumedBy :
       {PauseOrigin::Manual, PauseOrigin::System, PauseOrigin::Unknown,
        PauseOrigin::Automatic, PauseOrigin::None}) {
    auto pause = began(WireTransition::Pause);
    assert(!pause.observe(
        workout(SessionState::Paused, PauseOrigin::Automatic,
                PauseOrigin::Automatic),
        1'000));
    assert(pause.observe(
        workout(SessionState::Running, PauseOrigin::None, resumedBy), 2'000));
  }

  // A resume decision starts from an automatic pause. The Watch reports
  // unknown from the moment it records the request until the marker for the
  // resumed session is written.
  auto resumeLands = began(WireTransition::Resume);
  assert(!resumeLands.observe(
      workout(SessionState::Paused, PauseOrigin::Automatic,
              PauseOrigin::Automatic),
      0));
  assert(!resumeLands.pauseOriginPending());
  assert(!resumeLands.observe(pausedUnknown, 1'000));
  assert(resumeLands.pauseOriginPending());
  assert(!resumeLands.observe(
      workout(SessionState::Running, PauseOrigin::None, PauseOrigin::Unknown),
      2'000));
  assert(!resumeLands.pauseOriginPending());
  assert(!resumeLands.observe(
      workout(SessionState::Running, PauseOrigin::None,
              PauseOrigin::Automatic),
      3'000));

  // Each state gets its own grace: a slow resume is not cut short by the time
  // already spent waiting in the paused state.
  auto slowResume = began(WireTransition::Resume);
  const ObservedWorkout runningUnknown = workout(
      SessionState::Running, PauseOrigin::None, PauseOrigin::Unknown);
  assert(!slowResume.observe(pausedUnknown, 0));
  assert(!slowResume.observe(pausedUnknown, grace - 1));
  assert(!slowResume.observe(runningUnknown, grace));
  assert(!slowResume.observe(runningUnknown, 2 * grace - 1));
  assert(slowResume.observe(runningUnknown, 2 * grace));

  // The rider resumed, or re-attributed the pause, before the detector's
  // resume was confirmed.
  for (PauseOrigin riders : {PauseOrigin::Manual, PauseOrigin::System}) {
    auto resumed = began(WireTransition::Resume);
    assert(resumed.observe(
        workout(SessionState::Running, PauseOrigin::None, riders), 1'000));
    auto repaused = began(WireTransition::Resume);
    assert(repaused.observe(workout(SessionState::Paused, riders, riders),
                            1'000));
  }

  // A resume that landed and was followed by another pause is spent.
  auto resumeUndone = began(WireTransition::Resume);
  assert(!resumeUndone.observe(
      workout(SessionState::Running, PauseOrigin::None,
              PauseOrigin::Automatic),
      1'000));
  assert(resumeUndone.observe(
      workout(SessionState::Paused, PauseOrigin::Automatic,
              PauseOrigin::Automatic),
      2'000));

  // Terminal, idle and foreign-session telemetry retire a decision as before.
  for (SessionState terminal :
       {SessionState::Ending, SessionState::Ended, SessionState::Failed}) {
    for (WireTransition transition :
         {WireTransition::Start, WireTransition::Pause,
          WireTransition::Resume}) {
      auto tracker = began(transition);
      assert(tracker.observe(
          workout(terminal, PauseOrigin::None, PauseOrigin::Automatic), 0));
    }
  }
  const ObservedWorkout noWorkout = workout(
      SessionState::Idle, PauseOrigin::None, PauseOrigin::None, false);
  assert(began(WireTransition::Pause).observe(noWorkout, 0));
  assert(began(WireTransition::Resume).observe(noWorkout, 0));
  assert(!began(WireTransition::Start).observe(noWorkout, 0));
  ObservedWorkout otherSession = workout(
      SessionState::Running, PauseOrigin::None, PauseOrigin::Automatic);
  otherSession.sessionMismatch = true;
  assert(began(WireTransition::Pause).observe(otherSession, 0));
  // The session ID travels in the origin frame; without one there is no
  // mismatch to act on yet.
  otherSession.originReceived = false;
  assert(!began(WireTransition::Pause).observe(otherSession, 0));

  // A start decision still loses to any start it did not make.
  auto start = began(WireTransition::Start);
  assert(!start.observe(
      workout(SessionState::Running, PauseOrigin::None, PauseOrigin::None,
              false),
      0));
  assert(!start.observe(
      workout(SessionState::Running, PauseOrigin::None,
              PauseOrigin::Automatic),
      1'000));
  for (PauseOrigin other :
       {PauseOrigin::Manual, PauseOrigin::System, PauseOrigin::Unknown}) {
    assert(began(WireTransition::Start)
               .observe(workout(SessionState::Running, PauseOrigin::None,
                                other),
                        2'000));
  }

  // A paused session is the rider's unless its origin is confirmed automatic.
  // While that confirmation is pending for a transition the device asked for,
  // the previous lifecycle is kept, and only if it was one the pending
  // decision could have started from.
  using ride_automation_runtime::pausedSessionLifecycle;
  for (ConfirmedLifecycle previous :
       {ConfirmedLifecycle::Idle, ConfirmedLifecycle::Running,
        ConfirmedLifecycle::AutomaticallyPaused,
        ConfirmedLifecycle::ManuallyPaused, ConfirmedLifecycle::Finished}) {
    assert(pausedSessionLifecycle(true, false, previous) ==
           ConfirmedLifecycle::AutomaticallyPaused);
    assert(pausedSessionLifecycle(true, true, previous) ==
           ConfirmedLifecycle::AutomaticallyPaused);
    assert(pausedSessionLifecycle(false, false, previous) ==
           ConfirmedLifecycle::ManuallyPaused);
    const bool held = previous == ConfirmedLifecycle::Running ||
                      previous == ConfirmedLifecycle::AutomaticallyPaused;
    assert(pausedSessionLifecycle(false, true, previous) ==
           (held ? previous : ConfirmedLifecycle::ManuallyPaused));
  }

  // The reason the lifecycle is held: an automatic resume whose paused state
  // was briefly read as the rider's would get the manual-resume grace, and a
  // stop right after it would not pause.
  Settings ask;
  const auto stoppedFor = [&](RideAutomationPolicy &policy, uint32_t fromMs,
                              uint32_t toMs) {
    Decision last;
    for (uint32_t nowMs = fromMs; nowMs <= toMs; nowMs += 1'000) {
      last = policy.update(nowMs, wheel(0.0F, nowMs),
                           ConfirmedLifecycle::Running, ask);
    }
    return last;
  };
  RideAutomationPolicy heldResume;
  assert(!heldResume.update(0, wheel(4.0F, 0),
                            ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!heldResume.update(
      1'000, wheel(4.0F, 1'000),
      pausedSessionLifecycle(false, true,
                             ConfirmedLifecycle::AutomaticallyPaused),
      ask));
  assert(stoppedFor(heldResume, 2'000, 7'000).transition ==
         Transition::Pause);
  RideAutomationPolicy misreadResume;
  assert(!misreadResume.update(0, wheel(4.0F, 0),
                               ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!misreadResume.update(
      1'000, wheel(4.0F, 1'000),
      pausedSessionLifecycle(false, false,
                             ConfirmedLifecycle::AutomaticallyPaused),
      ask));
  assert(!stoppedFor(misreadResume, 2'000, 7'000));
}

// Watch samples reach the device on their own clock. The candidate span must
// tolerate a sample that is late or briefly missing without acting on data
// that is too old.
void testWatchGpsDeliveryTolerance() {
  Settings ask;
  Decision decision;

  // The newest sample ages past the decision limit before its successor is
  // delivered. The span continues, and the pause is emitted once a fresh
  // sample completes it.
  RideAutomationPolicy lateSuccessor;
  for (uint32_t second = 0; second <= 2; ++second) {
    assert(!lateSuccessor.update(
        second * 1'000, watchGps(0.1F, second * 1'000, second + 1),
        ConfirmedLifecycle::Running, ask));
  }
  assert(!lateSuccessor.update(5'500, watchGps(0.1F, 2'000, 3),
                               ConfirmedLifecycle::Running, ask));
  assert(lateSuccessor.detectorStatus().phase ==
         DetectorPhase::PauseCandidate);
  assert(!lateSuccessor.update(6'000, watchGps(0.1F, 4'500, 4),
                               ConfirmedLifecycle::Running, ask));
  decision = lateSuccessor.update(7'000, watchGps(0.1F, 5'500, 5),
                                  ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);
  assert(decision.candidateBeganAtMs == 0);

  // A complete span cannot pause on a sample that is too old to act on.
  RideAutomationPolicy staleSpan;
  for (uint32_t second = 0; second <= 5; ++second) {
    assert(!staleSpan.update(
        second * 1'000 + 3'500, watchGps(0.1F, second * 1'000, second + 1),
        ConfirmedLifecycle::Running, ask));
  }
  assert(staleSpan.detectorStatus().progressPercent == 100);
  decision = staleSpan.update(9'000, watchGps(0.1F, 7'000, 7),
                              ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);

  // A late sample that is not stopped still ends the span, even though it is
  // too old to act as a movement veto. Without that, samples 5 and 6 below
  // would complete the five-second span begun at sample 1.
  RideAutomationPolicy lateMovement;
  for (uint32_t second = 0; second <= 2; ++second) {
    assert(!lateMovement.update(
        second * 1'000, watchGps(0.1F, second * 1'000, second + 1),
        ConfirmedLifecycle::Running, ask));
  }
  assert(!lateMovement.update(6'200, watchGps(3.0F, 3'000, 4),
                              ConfirmedLifecycle::Running, ask));
  assert(!lateMovement.update(6'400, watchGps(0.1F, 4'500, 5),
                              ConfirmedLifecycle::Running, ask));
  assert(!lateMovement.update(6'600, watchGps(0.1F, 5'000, 6),
                              ConfirmedLifecycle::Running, ask));
  for (uint32_t second = 6; second <= 9; ++second) {
    assert(!lateMovement.update(
        second * 1'000 + 1'000, watchGps(0.1F, second * 1'000, second + 1),
        ConfirmedLifecycle::Running, ask));
  }
  decision = lateMovement.update(11'000, watchGps(0.1F, 9'500, 11),
                                 ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);
  assert(decision.candidateBeganAtMs == 4'500);

  // The span is kept only while a successor could still follow within the
  // sample-gap limit: the decision freshness limit plus one sample gap.
  RideAutomationPolicy abandoned;
  for (uint32_t second = 0; second <= 4; ++second) {
    assert(!abandoned.update(
        second * 1'000, watchGps(0.1F, second * 1'000, second + 1),
        ConfirmedLifecycle::Running, ask));
  }
  assert(!abandoned.update(10'000, watchGps(0.1F, 4'000, 5),
                           ConfirmedLifecycle::Running, ask));
  assert(abandoned.detectorStatus().phase == DetectorPhase::PauseCandidate);
  assert(!abandoned.update(10'001, watchGps(0.1F, 4'000, 5),
                           ConfirmedLifecycle::Running, ask));
  assert(abandoned.detectorStatus().phase == DetectorPhase::Quiet);
  // A sample delivered after that starts a new span instead of extending it.
  assert(!abandoned.update(10'500, watchGps(0.1F, 9'000, 6),
                           ConfirmedLifecycle::Running, ask));
  assert(abandoned.detectorStatus().progressPercent == 0);

  // The fallback sources keep accumulating beside a Watch feed whose samples
  // are too far apart to build a span, instead of being cleared every time
  // the Watch feed is fresh.
  RideAutomationPolicy irregularWatch;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    const uint32_t sampleIndex = nowMs / 4'000;
    decision = irregularWatch.update(
        nowMs,
        withWatchGps(gpsImu(0.1F, 0.1F, 0.0F, nowMs, true),
                     watchGps(0.1F, sampleIndex * 4'000, sampleIndex + 1)),
        ConfirmedLifecycle::Running, ask);
    assert((decision.transition == Transition::Pause) == (nowMs == 10'000));
  }
  assert((decision.evidenceMask & EvidenceGpsStopped) != 0);
  assert((decision.evidenceMask & EvidenceWatchGpsStopped) != 0);
  assert(decision.candidateBeganAtMs == 0);

  // Fresh Watch GPS between the stopped and moving thresholds still outranks
  // a fallback that looks stopped.
  RideAutomationPolicy watchCrawl;
  for (uint32_t nowMs = 0; nowMs <= 20'000; nowMs += 1'000) {
    assert(!watchCrawl.update(
        nowMs,
        withWatchGps(gpsImu(0.1F, 0.1F, 0.0F, nowMs, true),
                     watchGps(1.2F, nowMs, nowMs / 1'000 + 1)),
        ConfirmedLifecycle::Running, ask));
  }

  // Resume follows the same rules: the span survives a late successor, and
  // the resume is emitted only on a fresh sample.
  RideAutomationPolicy lateResume;
  assert(!lateResume.update(0, watchGps(3.0F, 0, 1),
                            ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!lateResume.update(1'000, watchGps(3.0F, 1'000, 2),
                            ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!lateResume.update(4'500, watchGps(3.0F, 1'000, 2),
                            ConfirmedLifecycle::AutomaticallyPaused, ask));
  decision = lateResume.update(5'000, watchGps(3.0F, 3'500, 3),
                               ConfirmedLifecycle::AutomaticallyPaused, ask);
  assert(decision.transition == Transition::Resume);

  RideAutomationPolicy staleResume;
  assert(!staleResume.update(3'200, watchGps(3.0F, 0, 1),
                             ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!staleResume.update(5'200, watchGps(3.0F, 2'000, 2),
                             ConfirmedLifecycle::AutomaticallyPaused, ask));
  decision = staleResume.update(5'400, watchGps(3.0F, 4'500, 3),
                                ConfirmedLifecycle::AutomaticallyPaused, ask);
  assert(decision.transition == Transition::Resume);

  RideAutomationPolicy lateStop;
  assert(!lateStop.update(0, watchGps(3.0F, 0, 1),
                          ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!lateStop.update(4'200, watchGps(0.1F, 1'000, 2),
                          ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!lateStop.update(4'400, watchGps(3.0F, 2'500, 3),
                          ConfirmedLifecycle::AutomaticallyPaused, ask));
}

// A wheel sensor's stop candidate runs beside a Watch feed that also reports
// stopped. Fresh Watch GPS between the thresholds still outranks it.
void testWheelBesideWatchGps() {
  Settings ask;
  Decision decision;
  const auto wheelWithWatch = [](float wheelSpeed, uint32_t nowMs,
                                 const RideEvidenceObservation &watch) {
    return withWatchGps(wheel(wheelSpeed, nowMs), watch);
  };

  // Both sources stopped with an unbroken Watch span: one pause, at the five
  // seconds either source needs on its own.
  RideAutomationPolicy bothStopped;
  for (uint32_t nowMs = 0; nowMs <= 5'000; nowMs += 1'000) {
    decision = bothStopped.update(
        nowMs,
        wheelWithWatch(0.0F, nowMs, watchGps(0.1F, nowMs, nowMs / 1'000 + 1)),
        ConfirmedLifecycle::Running, ask);
    assert((decision.transition == Transition::Pause) == (nowMs == 5'000));
  }
  assert((decision.evidenceMask & EvidenceWheelStopped) != 0);
  assert((decision.evidenceMask & EvidenceWatchGpsStopped) != 0);
  assert(bothStopped.counters().pause == 1);

  // Watch samples too far apart to build a span, each still fresh and
  // stopped: the wheel candidate completes instead of being cleared by them.
  RideAutomationPolicy brokenWatchSpan;
  for (uint32_t nowMs = 0; nowMs <= 5'000; nowMs += 1'000) {
    const uint32_t sampleIndex = nowMs / 4'000;
    decision = brokenWatchSpan.update(
        nowMs,
        wheelWithWatch(0.0F, nowMs,
                       watchGps(0.1F, sampleIndex * 4'000, sampleIndex + 1)),
        ConfirmedLifecycle::Running, ask);
    assert((decision.transition == Transition::Pause) == (nowMs == 5'000));
  }
  assert(decision.candidateBeganAtMs == 0);

  // Fresh Watch GPS between the stopped and moving thresholds outranks a
  // stopped wheel.
  RideAutomationPolicy watchCrawl;
  for (uint32_t nowMs = 0; nowMs <= 15'000; nowMs += 1'000) {
    assert(!watchCrawl.update(
        nowMs,
        wheelWithWatch(0.0F, nowMs, watchGps(1.2F, nowMs, nowMs / 1'000 + 1)),
        ConfirmedLifecycle::Running, ask));
  }

  // One such Watch sample restarts both candidates: the wheel candidate
  // still needs its own uninterrupted five seconds.
  RideAutomationPolicy interrupted;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    const float watchSpeed = nowMs == 4'000 ? 1.2F : 0.1F;
    decision = interrupted.update(
        nowMs,
        wheelWithWatch(0.0F, nowMs,
                       watchGps(watchSpeed, nowMs, nowMs / 1'000 + 1)),
        ConfirmedLifecycle::Running, ask);
    assert((decision.transition == Transition::Pause) == (nowMs == 10'000));
  }
  assert(decision.candidateBeganAtMs == 5'000);
}

} // namespace

int main() {
  testOutstandingDecisionTracker();
  testWatchGpsDeliveryTolerance();
  testWheelBesideWatchGps();
  assert(!ride_automation_runtime::decisionTransportExpired(30'999, 1'000));
  assert(ride_automation_runtime::decisionTransportExpired(31'000, 1'000));
  assert(ride_automation_runtime::decisionTransportExpired(29'999, UINT32_MAX));
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

  SampleSpanLatch sampleSpan;
  assert(!sampleSpan.update(true, true, 1, 1, 0, 5'000, 3'000));
  assert(!sampleSpan.update(true, true, 1, 2, 1'000, 5'000, 3'000));
  assert(!sampleSpan.update(true, true, 1, 2, 4'000, 5'000, 3'000));
  assert(sampleSpan.spanMs() == 1'000);
  assert(!sampleSpan.update(true, true, 1, 3, 4'001, 5'000, 3'000));
  assert(sampleSpan.spanMs() == 0);
  assert(!sampleSpan.update(true, true, 2, 1, 5'000, 5'000, 3'000));
  assert(sampleSpan.spanMs() == 0);

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
  assert(decision.profileVersion == 4);
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

#if defined(RIDE_AUTOMATION_AUTOMATIC_START)
  Settings automatic = ask;
  automatic.startMode = StartMode::Automatic;
  RideAutomationPolicy sensorAutomatic;
  assert(!runSeconds(sensorAutomatic, 0, 10, ConfirmedLifecycle::Idle,
                     automatic, 2.0F));
  decision = sensorAutomatic.update(10'000, wheel(2.0F, 10'000),
                                    ConfirmedLifecycle::Idle, automatic);
  assert(decision.transition == Transition::Start);
#endif

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

#if defined(RIDE_AUTOMATION_AUTOMATIC_START)
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
#endif

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

  // Raw Watch workout GPS is the sensorless primary path. The duration is
  // based on distinct producer samples, with no device IMU requirement.
  RideAutomationPolicy watchPrimaryPause;
  for (uint32_t second = 0; second < 5; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!watchPrimaryPause.update(
        nowMs, watchGps(0.1F, nowMs, second + 1),
        ConfirmedLifecycle::Running, ask));
  }
  assert(!watchPrimaryPause.update(
      4'999, watchGps(0.1F, 4'999, 6),
      ConfirmedLifecycle::Running, ask));
  decision = watchPrimaryPause.update(
      5'000, watchGps(0.1F, 5'000, 7),
      ConfirmedLifecycle::Running, ask);
  assert(decision.transition == Transition::Pause);
  assert((decision.evidenceMask & EvidenceWatchGpsStopped) != 0);
  assert((decision.sourceHealthMask & SourceHealthWatchGpsFresh) != 0);

  // Exercise the actual policy output through the transport encoder. The
  // Watch health bit must survive, not just the older four source bits.
  ride_automation_protocol::Frame watchFrame;
  watchFrame.kind = ride_automation_protocol::Kind::Decision;
  watchFrame.transition = ride_automation_protocol::Transition::Pause;
  watchFrame.origin = ride_automation_protocol::Origin::Automatic;
  watchFrame.rideGeneration = 1;
  watchFrame.decisionSequence = decision.sequence;
  watchFrame.evidenceMask = decision.evidenceMask;
  watchFrame.sourceHealthMask = decision.sourceHealthMask;
  watchFrame.profileVersion = 1;
  watchFrame.sessionID[0] = 1;
  uint8_t wire[ride_automation_protocol::FRAME_SIZE]{};
  assert(ride_automation_protocol::encode(watchFrame, wire, sizeof(wire)));
  ride_automation_protocol::Frame decodedWatch;
  assert(ride_automation_protocol::decode(wire, sizeof(wire), decodedWatch));
  assert(decodedWatch.sourceHealthMask == SourceHealthWatchGpsFresh);
  if (const char *fixturePath = std::getenv("RAUT_POLICY_FRAME_PATH")) {
    std::ofstream fixture(fixturePath, std::ios::binary);
    fixture.write(reinterpret_cast<const char *>(wire), sizeof(wire));
    assert(fixture.good());
  }

  // A brief movement veto must discard the preceding Watch stopped span.
  for (int source = 0; source < 3; ++source) {
    RideAutomationPolicy veto;
    for (uint32_t second = 0; second < 9; ++second) {
      auto observation = watchGps(0.1F, second * 1'000, second + 1);
      if (second == 4) {
        if (source == 0)
          observation.wheelSpeedMetersPerSecond = metric(5.0F, 4'000);
        else if (source == 1)
          observation.cadenceRpm = metric(70.0F, 4'000);
        else {
          observation.gpsSpeedMetersPerSecond = metric(5.0F, 4'000);
          observation.gpsFixValid = flag(true, 4'000);
          observation.gpsHorizontalUncertaintyMeters = metric(5.0F, 4'000);
          observation.imuMotionScore = metric(1.0F, 4'000);
        }
      }
      assert(!veto.update(second * 1'000, observation,
                          ConfirmedLifecycle::Running, ask));
    }
  }

  for (int source = 0; source < 2; ++source) {
    RideAutomationPolicy mixedResume;
    for (uint32_t second = 0; second <= 3; ++second) {
      auto observation = watchGps(0.1F, second * 1'000, second + 1);
      if (source == 0)
        observation.wheelSpeedMetersPerSecond = metric(5.0F, second * 1'000);
      else
        observation.cadenceRpm = metric(70.0F, second * 1'000);
      const auto result = mixedResume.update(second * 1'000, observation,
                                             ConfirmedLifecycle::AutomaticallyPaused, ask);
      if (second == 2) assert(result.transition == Transition::Resume);
      assert(!mixedResume.takePendingCancellation());
    }
    assert(!mixedResume.update(4'000, watchGps(0.1F, 4'000, 5),
                               ConfirmedLifecycle::AutomaticallyPaused, ask));
    assert(mixedResume.takePendingCancellation());
  }

  // Repeating a transport frame cannot advance the sample window.
  RideAutomationPolicy watchDuplicate;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    assert(!watchDuplicate.update(
        nowMs, watchGps(0.1F, nowMs, 1),
        ConfirmedLifecycle::Running, ask));
  }

  // A producer restart or an excessive location-sample gap starts a new span.
  RideAutomationPolicy watchGap;
  assert(!watchGap.update(0, watchGps(0.1F, 0, 1),
                          ConfirmedLifecycle::Running, ask));
  assert(!watchGap.update(1'000, watchGps(0.1F, 1'000, 2),
                          ConfirmedLifecycle::Running, ask));
  assert(!watchGap.update(5'000, watchGps(0.1F, 5'000, 3),
                          ConfirmedLifecycle::Running, ask));
  assert(!watchGap.update(9'000, watchGps(0.1F, 9'000, 1, 5.0F, 2),
                          ConfirmedLifecycle::Running, ask));

  RideAutomationPolicy watchBadAccuracy;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    assert(!watchBadAccuracy.update(
        nowMs, watchGps(0.1F, nowMs, nowMs / 1'000 + 1, 12.51F),
        ConfirmedLifecycle::Running, ask));
  }

  RideAutomationPolicy watchThreshold;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    assert(!watchThreshold.update(
        nowMs, watchGps(0.8F, nowMs, nowMs / 1'000 + 1),
        ConfirmedLifecycle::Running, ask));
  }

  // Any fresh direct movement remains a safety veto for auto-pause.
  RideAutomationPolicy watchStoppedWheelMoving;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    auto observation = watchGps(0.1F, nowMs, nowMs / 1'000 + 1);
    observation.wheelSpeedMetersPerSecond = metric(5.0F, nowMs);
    assert(!watchStoppedWheelMoving.update(
        nowMs, observation, ConfirmedLifecycle::Running, ask));
  }

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

  RideAutomationPolicy watchPrimaryResume;
  assert(!watchPrimaryResume.update(
      0, watchGps(2.0F, 0, 1),
      ConfirmedLifecycle::AutomaticallyPaused, ask));
  assert(!watchPrimaryResume.update(
      1'999, watchGps(2.0F, 1'999, 2),
      ConfirmedLifecycle::AutomaticallyPaused, ask));
  decision = watchPrimaryResume.update(
      2'000, watchGps(2.0F, 2'000, 3),
      ConfirmedLifecycle::AutomaticallyPaused, ask);
  assert(decision.transition == Transition::Resume);

  RideAutomationPolicy watchBelowResume;
  for (uint32_t nowMs = 0; nowMs <= 10'000; nowMs += 1'000) {
    assert(!watchBelowResume.update(
        nowMs, watchGps(1.99F, nowMs, nowMs / 1'000 + 1),
        ConfirmedLifecycle::AutomaticallyPaused, ask));
  }

  RideAutomationPolicy manualPause;
  for (uint32_t second = 0; second < 30; ++second) {
    const uint32_t nowMs = second * 1'000;
    assert(!manualPause.update(nowMs, wheel(4.0F, nowMs),
                               ConfirmedLifecycle::ManuallyPaused, ask));
  }
  for (uint32_t nowMs = 30'000; nowMs <= 40'000; nowMs += 1'000) {
    assert(!manualPause.update(
        nowMs, watchGps(5.0F, nowMs, nowMs / 1'000 + 1),
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
  health = resolveDetectionHealth({false, false, false, false, false, true});
  assert(health.state == DetectionHealthState::HealthyWatchGps);
  assert(health.healthy() && !health.directSensorAvailable);
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
  assert(std::strstr(json, "\"schema\":4") != nullptr);
  assert(std::strstr(json, "\"profile\":4") != nullptr);
  assert(std::strstr(json, "\"watch_gps_sequence\":null") != nullptr);
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
