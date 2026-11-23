#pragma once

#include "ride_automation_policy.hpp"
#include "ride_automation_protocol.hpp"
#include "../ble_navigation/workout_telemetry_protocol.hpp"

#include <cstdint>

namespace ride_automation_runtime {

// How a paused Watch session maps onto the detector lifecycle. Only a
// confirmed automatic origin may be resumed automatically. While the Watch is
// still confirming the origin of a pause or resume this device asked for
// (`originPending`), the pause is not yet known to be the rider's either:
// keep the previous confirmed lifecycle, because reading that window as a
// manual pause would apply the manual-resume grace to an automatic resume.
inline ride_automation::ConfirmedLifecycle pausedSessionLifecycle(
    bool automaticOrigin, bool originPending,
    ride_automation::ConfirmedLifecycle previous) {
  using ride_automation::ConfirmedLifecycle;
  if (automaticOrigin)
    return ConfirmedLifecycle::AutomaticallyPaused;
  if (originPending && (previous == ConfirmedLifecycle::Running ||
                        previous == ConfirmedLifecycle::AutomaticallyPaused)) {
    return previous;
  }
  return ConfirmedLifecycle::ManuallyPaused;
}

// The Watch reports origin `unknown` while it durably writes the provenance
// marker for a pause or resume it has already been asked to apply, and a
// state change clears the origin until its frame arrives. For this long an
// unconfirmed origin means "confirmation pending"; after it, an origin that
// is still `unknown` is a transition the detector did not make.
constexpr uint32_t kOriginConfirmationGraceMs = 5'000U;

struct ObservedWorkout {
  workout_telemetry_protocol::SessionState sessionState =
      workout_telemetry_protocol::SessionState::Idle;
  bool originReceived = false;
  // The origin frame names a different Watch session than the decision.
  bool sessionMismatch = false;
  workout_telemetry_protocol::PauseOrigin pauseOrigin =
      workout_telemetry_protocol::PauseOrigin::None;
  workout_telemetry_protocol::PauseOrigin lastTransitionOrigin =
      workout_telemetry_protocol::PauseOrigin::None;
};

// Decides whether live workout telemetry contradicts the one decision the
// device is waiting on. It is fed once per detector tick, and remembers
// whether the session has reached the requested state: the origin of the
// state a pause decision started from describes an older transition (for
// example the rider's manual start) and is never evidence against it.
class OutstandingDecisionTracker {
public:
  void begin(ride_automation_protocol::Transition transition) {
    *this = OutstandingDecisionTracker{};
    transition_ = transition;
  }

  // Returns true when the decision can no longer apply and must be retired.
  bool observe(const ObservedWorkout &workout, uint32_t nowMs) {
    using ride_automation_protocol::Transition;
    using workout_telemetry_protocol::PauseOrigin;
    using workout_telemetry_protocol::SessionState;

    pauseOriginPending_ = false;
    if (transition_ == Transition::None)
      return false;

    const SessionState state = workout.sessionState;
    if (state == SessionState::Ending || state == SessionState::Ended ||
        state == SessionState::Failed) {
      return true;
    }
    if (transition_ == Transition::Start) {
      // A start decision loses to any start it did not make.
      return workout.originReceived &&
             workout.lastTransitionOrigin != PauseOrigin::None &&
             workout.lastTransitionOrigin != PauseOrigin::Automatic;
    }
    if (state == SessionState::Idle)
      return true;
    if (workout.originReceived && workout.sessionMismatch)
      return true;

    const bool paused = state == SessionState::Paused;
    const bool running = state == SessionState::Running;
    const bool atTarget =
        transition_ == Transition::Pause ? paused : running;
    const bool atBaseline =
        transition_ == Transition::Pause ? running : paused;
    if (atTarget) {
      targetStateObserved_ = true;
    } else if (atBaseline && targetStateObserved_) {
      // The transition landed and was then undone. Retire the decision so a
      // retry cannot apply it a second time.
      return true;
    }

    PauseOrigin origin = PauseOrigin::None;
    if (paused) {
      origin = workout.pauseOrigin;
    } else if (running && transition_ == Transition::Resume) {
      origin = workout.lastTransitionOrigin;
    } else {
      // A pause decision still waiting on a running session, or a session
      // that is only starting: nothing here describes the requested change.
      originUnconfirmed_ = false;
      return false;
    }
    if (!workout.originReceived)
      origin = PauseOrigin::None;

    switch (origin) {
    case PauseOrigin::Automatic:
      originUnconfirmed_ = false;
      return false;
    case PauseOrigin::Manual:
    case PauseOrigin::System:
      return true;
    case PauseOrigin::None:
    case PauseOrigin::Unknown:
      break;
    }

    if (!originUnconfirmed_ || unconfirmedState_ != state) {
      originUnconfirmed_ = true;
      unconfirmedState_ = state;
      unconfirmedSinceMs_ = nowMs;
    }
    if (static_cast<uint32_t>(nowMs - unconfirmedSinceMs_) <
        kOriginConfirmationGraceMs) {
      pauseOriginPending_ = paused;
      return false;
    }
    // An absent origin never contradicts on its own; the decision's transport
    // deadline bounds that wait.
    return origin == PauseOrigin::Unknown;
  }

  // True when the last observation was a paused session whose origin may
  // still be confirmed as automatic. The caller keeps its previous confirmed
  // lifecycle for that tick instead of reading the pause as the rider's.
  bool pauseOriginPending() const { return pauseOriginPending_; }

private:
  ride_automation_protocol::Transition transition_ =
      ride_automation_protocol::Transition::None;
  bool targetStateObserved_ = false;
  bool originUnconfirmed_ = false;
  workout_telemetry_protocol::SessionState unconfirmedState_ =
      workout_telemetry_protocol::SessionState::Idle;
  uint32_t unconfirmedSinceMs_ = 0;
  bool pauseOriginPending_ = false;
};

} // namespace ride_automation_runtime
