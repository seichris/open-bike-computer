// Host test: standalone GNSS movement in disconnected shutdown and display
// inactivity (docs/firmware-power-management.md).
//
//   g++ -std=c++17 -Wall -Wextra -Werror tools/tests/test_gnss_power_policy.cpp
#include "../../lib/ble_navigation/disconnected_shutdown_policy.hpp"
#include "../../lib/display_power/display_inactivity_policy.hpp"
#include "../../lib/position_source/gnss_motion_policy.hpp"

#include <cassert>
#include <cmath>
#include <cstdint>

namespace {

using disconnected_shutdown_policy::Action;
using disconnected_shutdown_policy::MotionHold;
using disconnected_shutdown_policy::Tracker;
using gnss_motion::Detector;
using gnss_motion::Sample;
using gnss_motion::Transition;

constexpr double kBaseLatitude = 25.2048;
constexpr double kBaseLongitude = 55.2708;
// Metres per degree of latitude, for synthetic tracks.
constexpr double kMetersPerDegree = 111'195.0;

Sample fix(uint32_t atMs, float speedKmh, double northMeters,
           double eastMeters = 0.0, bool valid = true) {
  Sample sample;
  sample.capturedAtMs = atMs;
  sample.locationValid = valid;
  sample.speedValid = valid;
  sample.speedKmh = speedKmh;
  sample.latitude = kBaseLatitude + northMeters / kMetersPerDegree;
  sample.longitude =
      kBaseLongitude +
      eastMeters / (kMetersPerDegree *
                    std::cos(kBaseLatitude * 3.14159265358979323846 / 180.0));
  return sample;
}

// Feeds one fix per second at a steady speed along a straight line and
// ticks between fixes; returns the position reached.
double ride(Detector &detector, uint32_t &now, uint32_t seconds,
            float speedKmh, double northMeters) {
  for (uint32_t second = 0; second < seconds; ++second) {
    now += 1'000;
    northMeters += speedKmh / 3.6;
    detector.observe(fix(now, speedKmh, northMeters));
    detector.tick(now);
  }
  return northMeters;
}

MotionHold holdFrom(const Detector &detector) {
  MotionHold hold;
  hold.moving = detector.moving();
  hold.moved = detector.moved();
  hold.lastMovementMs = detector.lastMovementMs();
  return hold;
}

void testDistance() {
  const Sample a = fix(0, 0, 0);
  const Sample b = fix(0, 0, 100);
  const Sample c = fix(0, 0, 0, 100);
  assert(std::fabs(gnss_motion::distanceMeters(a.latitude, a.longitude,
                                               b.latitude, b.longitude) -
                   100.0F) < 0.5F);
  assert(std::fabs(gnss_motion::distanceMeters(a.latitude, a.longitude,
                                               c.latitude, c.longitude) -
                   100.0F) < 0.5F);
}

void testStationaryJitterNeverMoves() {
  Detector detector;
  // Ten minutes parked by a window: speed noise up to 8 km/h, isolated
  // spikes to 15 km/h and a few metres of wander.
  for (uint32_t second = 1; second <= 600; ++second) {
    const uint32_t now = second * 1'000;
    const float speed = second % 97 == 0 ? 15.0F
                        : second % 13 == 0 ? 8.0F
                                           : static_cast<float>(second % 4);
    const double wander = std::sin(second * 0.7) * 6.0;
    detector.observe(fix(now, speed, wander, std::cos(second * 1.3) * 6.0));
    detector.tick(now);
    assert(!detector.moving());
  }
  assert(!detector.moved());
  assert(detector.takeTransition() == Transition::None);
}

void testFastSpeedWithoutDisplacementIsJitter() {
  Detector detector;
  // A multipath burst: several "fast" fixes that do not go anywhere.
  for (uint32_t second = 1; second <= 8; ++second)
    detector.observe(fix(second * 1'000, 14.0F, second % 2 ? 4.0 : -4.0));
  assert(!detector.moving());
}

void testRidingStartsAfterConsecutiveSamplesAndDisplacement() {
  Detector detector;
  uint32_t now = 0;
  double north = 0;
  // Two fast samples are not enough.
  north = ride(detector, now, 2, 18.0F, north);
  assert(!detector.moving());
  north = ride(detector, now, 2, 18.0F, north);
  assert(detector.moving());
  assert(detector.moved());
  assert(detector.takeTransition() == Transition::Started);
  assert(detector.lastMovementMs() == now);
  // A slow cyclist (10 km/h) needs a little longer for 15 m.
  Detector slow;
  uint32_t slowNow = 0;
  double slowNorth = 0;
  slowNorth = ride(slow, slowNow, 4, 10.0F, slowNorth);
  assert(!slow.moving());
  slowNorth = ride(slow, slowNow, 4, 10.0F, slowNorth);
  assert(slow.moving());
  (void)north;
  (void)slowNorth;
}

void testGapsBreakTheStartSequence() {
  Detector detector;
  double north = 0;
  for (uint32_t index = 0; index < 6; ++index) {
    north += 20.0;
    // Fixes four seconds apart are not consecutive.
    detector.observe(fix(index * 4'000, 18.0F, north));
  }
  assert(!detector.moving());
}

void testHysteresisKeepsSlowRidingMoving() {
  Detector detector;
  uint32_t now = 0;
  double north = ride(detector, now, 6, 20.0F, 0);
  assert(detector.moving());
  // Climbing at 6 km/h: below the start threshold, above the stop one.
  north = ride(detector, now, 60, 6.0F, north);
  assert(detector.moving());
  assert(detector.lastMovementMs() == now);
  (void)north;
}

void testStoppingEndsMovementAfterStopWindow() {
  Detector detector;
  uint32_t now = 0;
  double north = ride(detector, now, 10, 20.0F, 0);
  assert(detector.moving());
  (void)detector.takeTransition();
  const uint32_t lastMoving = detector.lastMovementMs();
  // Stopped at a light: slow fixes at the same place.
  for (uint32_t second = 1; second <= 15; ++second) {
    now += 1'000;
    detector.observe(fix(now, 1.0F, north));
    detector.tick(now);
    if (now - lastMoving < gnss_motion::kStopMs)
      assert(detector.moving());
  }
  assert(!detector.moving());
  assert(detector.lastMovementMs() == lastMoving);
  assert(detector.takeTransition() == Transition::Stopped);
}

void testStaleOrInvalidFixEndsMovement() {
  Detector stale;
  uint32_t now = 0;
  ride(stale, now, 10, 20.0F, 0);
  const uint32_t lastMoving = stale.lastMovementMs();
  // Tunnel: no fixes at all, only loop ticks.
  for (uint32_t step = 1; step <= 120; ++step)
    stale.tick(now + step * 100);
  assert(!stale.moving());
  assert(stale.lastMovementMs() == lastMoving);

  Detector invalid;
  now = 0;
  double north = ride(invalid, now, 10, 20.0F, 0);
  for (uint32_t second = 1; second <= 12; ++second) {
    now += 1'000;
    north += 5.0;
    invalid.observe(fix(now, 20.0F, north, 0, false));
    invalid.tick(now);
  }
  assert(!invalid.moving());
}

void testSpeedWithoutProgressCannotHoldForever() {
  Detector detector;
  uint32_t now = 0;
  double north = ride(detector, now, 6, 20.0F, 0);
  assert(detector.moving());
  const uint32_t realProgressEnded = now;
  // A receiver that keeps reporting 12 km/h while the position stays put.
  uint32_t lastMovementAfterStop = 0;
  for (uint32_t second = 1; second <= 120; ++second) {
    now += 1'000;
    detector.observe(fix(now, 12.0F, north + (second % 2 ? 3.0 : -3.0)));
    detector.tick(now);
    if (!detector.moving()) {
      if (lastMovementAfterStop == 0)
        lastMovementAfterStop = detector.lastMovementMs();
      // Once stopped it neither restarts nor extends the hold.
      assert(detector.lastMovementMs() == lastMovementAfterStop);
    }
  }
  assert(!detector.moving());
  // False speed extended the hold by at most one progress window.
  assert(detector.lastMovementMs() - realProgressEnded <=
         gnss_motion::kProgressWindowMs);
}

// main.cpp reads `now` before the fix is captured: a tick slightly earlier
// than the fix must not wrap into a four-billion-millisecond age.
void testTickBeforeCaptureKeepsMoving() {
  Detector detector;
  double north = 0;
  uint32_t capture = 10'000;
  for (uint32_t second = 0; second < 30; ++second) {
    capture += 1'000;
    north += 20.0 / 3.6;
    detector.observe(fix(capture, 20.0F, north));
    // The loop's `now` was read 3 ms before this fix was captured.
    detector.tick(capture - 3);
    if (second >= 3)
      assert(detector.moving());
  }
  assert(detector.moving());
  // Only Started was ever reported; no stationary churn while riding.
  assert(detector.takeTransition() == Transition::Started);
  assert(detector.takeTransition() == Transition::None);
  assert(gnss_motion::elapsedMs(100, 103) == 0);
  assert(gnss_motion::elapsedMs(5, UINT32_MAX - 4) == 10);
}

void testFutureMovementTimeHolds() {
  MotionHold recent;
  recent.moved = true;
  recent.lastMovementMs = 500'003; // read after `now`
  assert(disconnected_shutdown_policy::motionHolds(recent, 500'000, 120));
  Tracker tracker;
  tracker.update(0, false, 120, true);
  const auto held = tracker.update(500'000, false, 120, true, recent);
  assert(held.action == Action::None && held.heldByMotion);
}

void testNonGnssShutdownIsUnchanged() {
  Tracker withDefault;
  Tracker legacy;
  for (uint32_t now = 1'000; now <= 400'000; now += 1'000) {
    const auto a = withDefault.update(now, false, 120, true, MotionHold{});
    const auto b = legacy.update(now, false, 120, true);
    assert(a.action == b.action);
    assert(!a.heldByMotion);
  }
  Tracker due;
  assert(due.update(1'000, false, 120, true).action == Action::CountdownStarted);
  assert(due.update(120'999, false, 120, true).action == Action::None);
  assert(due.update(121'000, false, 120, true).action == Action::ShutdownDue);
}

void testNeverAndConnectedAlwaysWin() {
  MotionHold moving;
  moving.moving = true;
  moving.moved = true;
  Tracker tracker;
  for (uint32_t now = 1'000; now <= 3'600'000; now += 10'000) {
    assert(tracker.update(now, false, 0, true, moving).action == Action::None);
    assert(tracker.update(now + 1, true, 120, true, moving).action ==
           Action::None);
  }
}

void testMovingRideNeverShutsDown() {
  Tracker tracker;
  Detector detector;
  uint32_t now = 0;
  double north = 0;
  bool held = false;
  // A 30-minute phone-off ride.
  for (uint32_t second = 0; second < 1'800; ++second) {
    north = ride(detector, now, 1, 20.0F, north);
    const auto result = tracker.update(now, false, 120, true, holdFrom(detector));
    assert(result.action == Action::None ||
           result.action == Action::CountdownStarted);
    held = held || result.heldByMotion;
  }
  assert(held);
}

void testParkedAfterRideSleepsAfterBoundedHold() {
  Tracker tracker;
  Detector detector;
  uint32_t now = 0;
  double north = ride(detector, now, 600, 20.0F, 0); // ten minutes riding
  for (uint32_t step = 0; step < 600; ++step)
    tracker.update(now - 600'000 + step * 1'000, false, 120, true,
                   holdFrom(detector));
  const uint32_t parkedAt = now;
  // Parked with jitter, some of it inside the 4-9 km/h hysteresis band:
  // the progress check ends the movement and it never restarts.
  uint32_t dueAt = 0;
  for (uint32_t second = 1; second <= 900 && dueAt == 0; ++second) {
    now += 1'000;
    detector.observe(fix(now, second % 7 == 0 ? 6.0F : 1.0F,
                         north + std::sin(second) * 4.0));
    detector.tick(now);
    if (tracker.update(now, false, 120, true, holdFrom(detector)).action ==
        Action::ShutdownDue)
      dueAt = now;
  }
  assert(!detector.moving());
  assert(dueAt != 0);
  const uint32_t holdMs = disconnected_shutdown_policy::motionHoldSeconds * 1'000;
  // Five minutes after the last counted movement...
  assert(dueAt - detector.lastMovementMs() >= holdMs);
  assert(dueAt - detector.lastMovementMs() <= holdMs + 1'000);
  // ...which jitter can push back by at most one progress window.
  assert(dueAt - parkedAt <= holdMs + gnss_motion::kProgressWindowMs + 1'000);
}

void testStaleFixHoldIsBounded() {
  Tracker tracker;
  Detector detector;
  uint32_t now = 0;
  ride(detector, now, 60, 20.0F, 0);
  const uint32_t lastMoving = detector.lastMovementMs();
  uint32_t dueAt = 0;
  // The receiver loses its fix for good (no more fixes).
  for (uint32_t step = 1; step <= 1'200 && dueAt == 0; ++step) {
    now += 1'000;
    detector.tick(now);
    if (tracker.update(now, false, 120, true, holdFrom(detector)).action ==
        Action::ShutdownDue)
      dueAt = now;
  }
  assert(dueAt != 0);
  assert(dueAt - lastMoving <=
         disconnected_shutdown_policy::motionHoldSeconds * 1'000 + 1'000);
}

void testLongerConfiguredTimeoutWins() {
  MotionHold recent;
  recent.moved = true;
  recent.lastMovementMs = 100'000;
  Tracker tracker;
  assert(tracker.update(100'000, false, 600, true, recent).action ==
         Action::CountdownStarted);
  // The configured ten minutes, measured from the last movement.
  assert(tracker.update(699'999, false, 600, true, recent).action ==
         Action::None);
  assert(tracker.update(700'000, false, 600, true, recent).action ==
         Action::ShutdownDue);
}

void testReconnectThenDisconnectWhileMoving() {
  MotionHold moving;
  moving.moving = true;
  moving.moved = true;
  Tracker tracker;
  tracker.update(0, false, 120, true);
  assert(tracker.update(130'000, false, 120, true).action ==
         Action::ShutdownDue);
  // The phone returns before the shutdown completes; a fresh disconnect
  // during a ride is then held.
  assert(tracker.update(131'000, true, 120, true, moving).action ==
         Action::None);
  assert(tracker.update(132'000, false, 120, true, moving).action ==
         Action::CountdownStarted);
  const auto held = tracker.update(400'000, false, 120, true, moving);
  assert(held.action == Action::None && held.heldByMotion);
}

void testAnnouncedShutdownIsNotWithdrawn() {
  Tracker tracker;
  tracker.update(0, false, 120, true);
  assert(tracker.update(120'000, false, 120, true).action ==
         Action::ShutdownDue);
  MotionHold moving;
  moving.moving = true;
  moving.moved = true;
  assert(tracker.update(121'000, false, 120, true, moving).action ==
         Action::ShutdownRetry);
}

void testRegistrationGraceStillApplies() {
  MotionHold recent;
  recent.moved = true;
  recent.lastMovementMs = 0;
  Tracker tracker;
  const auto started = tracker.update(0, false, 120, false, recent);
  assert(started.timeoutSeconds ==
         disconnected_shutdown_policy::registrationGraceSeconds);
  assert(tracker.update(599'999, false, 120, false, recent).action ==
         Action::None);
  assert(tracker.update(600'000, false, 120, false, recent).action ==
         Action::ShutdownDue);
}

void testDisplayHeldWhileMovingThenIdles() {
  display_inactivity::Policy policy;
  display_inactivity::Context context;
  policy.begin(0);
  // Parked: dims and turns off as before.
  assert(policy.update(15'000, context).current ==
         display_inactivity::Mode::Dimmed);
  assert(policy.update(45'000, context).current ==
         display_inactivity::Mode::DisplayOff);
  // The rider sets off without a phone: the screen wakes and stays on.
  context.gnssMoving = true;
  const auto woke = policy.update(60'000, context);
  assert(woke.current == display_inactivity::Mode::Active);
  assert(woke.displayWakeRequired);
  assert(policy.update(600'000, context).current ==
         display_inactivity::Mode::Active);
  // Movement ends: a fresh idle interval, then the usual dim and off.
  context.gnssMoving = false;
  assert(policy.update(600'100, context).current ==
         display_inactivity::Mode::Active);
  assert(policy.update(615'099, context).current ==
         display_inactivity::Mode::Active);
  assert(policy.update(615'100, context).current ==
         display_inactivity::Mode::Dimmed);
  assert(policy.update(645'100, context).current ==
         display_inactivity::Mode::DisplayOff);
}

void testDisplayWithoutMovementIsUnchanged() {
  display_inactivity::Policy withField;
  display_inactivity::Policy reference;
  display_inactivity::Context context;
  withField.begin(0);
  reference.begin(0);
  for (uint32_t now = 0; now <= 120'000; now += 500) {
    context.gnssMoving = false;
    assert(withField.update(now, context).current ==
           reference.update(now, display_inactivity::Context{}).current);
  }
  // Automatic display-off disabled stays on regardless.
  display_inactivity::Policy manual;
  display_inactivity::Context alwaysOn;
  alwaysOn.automaticDisplayOffEnabled = false;
  manual.begin(0);
  assert(manual.update(3'600'000, alwaysOn).current ==
         display_inactivity::Mode::Active);
}

} // namespace

int main() {
  testDistance();
  testStationaryJitterNeverMoves();
  testFastSpeedWithoutDisplacementIsJitter();
  testRidingStartsAfterConsecutiveSamplesAndDisplacement();
  testGapsBreakTheStartSequence();
  testHysteresisKeepsSlowRidingMoving();
  testStoppingEndsMovementAfterStopWindow();
  testStaleOrInvalidFixEndsMovement();
  testSpeedWithoutProgressCannotHoldForever();
  testTickBeforeCaptureKeepsMoving();
  testFutureMovementTimeHolds();
  testNonGnssShutdownIsUnchanged();
  testNeverAndConnectedAlwaysWin();
  testMovingRideNeverShutsDown();
  testParkedAfterRideSleepsAfterBoundedHold();
  testStaleFixHoldIsBounded();
  testLongerConfiguredTimeoutWins();
  testReconnectThenDisconnectWhileMoving();
  testAnnouncedShutdownIsNotWithdrawn();
  testRegistrationGraceStillApplies();
  testDisplayHeldWhileMovingThenIdles();
  testDisplayWithoutMovementIsUnchanged();
  return 0;
}
