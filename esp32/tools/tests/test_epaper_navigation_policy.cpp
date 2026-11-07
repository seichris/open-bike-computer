#include "../../lib/gui/src/epaperNavigationPolicy.hpp"

#include <cassert>
#include <cmath>
#include <cstdint>

int main() {
  using namespace epaper_navigation_policy;

  assert(std::fabs(headingDeltaDegrees(359.0, 1.0) - 2.0) < 1e-9);
  assert(quantizeDistanceMeters(104) == 100);
  assert(quantizeDistanceMeters(106) == 110);
  assert(quantizeDistanceMeters(96) == 95);

  HeadingFilter heading;
  auto filtered = heading.observe({1, 1000, 12.0, 359.0, true});
  assert(filtered.valid && filtered.courseDriven);
  assert(headingDeltaDegrees(filtered.degrees, 359.0) < 0.01);
  filtered = heading.observe({2, 2500, 12.0, 1.0, true});
  assert(filtered.valid && filtered.courseDriven);
  assert(headingDeltaDegrees(filtered.degrees, 0.0) < 1.0);
  const double movingHeading = filtered.degrees;
  filtered = heading.observe({3, 3000, 3.9, 90.0, true});
  assert(filtered.valid && !filtered.courseDriven);
  assert(headingDeltaDegrees(filtered.degrees, movingHeading) < 0.01);
  filtered = heading.observe({4, 4000, 5.0, 120.0, true});
  assert(!filtered.courseDriven);
  assert(headingDeltaDegrees(filtered.degrees, movingHeading) < 0.01);
  filtered = heading.observe({5, 5000, 6.0, 90.0, true});
  assert(filtered.courseDriven);
  assert(headingDeltaDegrees(filtered.degrees, 90.0) < 0.01);
  filtered = heading.observe({6, 4500, 18.0, 180.0, true});
  assert(filtered.courseDriven);
  assert(headingDeltaDegrees(filtered.degrees, 90.0) < 0.01);

  Fix fix{10, 1000, 18.0, filtered.degrees, true};
  CameraState camera;
  Scheduler scheduler;
  scheduler.observe(fix);
  auto first = scheduler.evaluate(1000, camera, true, true);
  assert(first.updateForeground && first.submitBase);
  assert((first.reasons & reasonMask(Reason::Position)) != 0);
  scheduler.markSubmitted(1000, fix, first.reasons);

  camera.hasBase = true;
  camera.baseCompatible = true;
  camera.mapCoverageAvailable = true;
  camera.riderProjected = true;
  camera.riderInsideViewport = true;
  camera.baseAcceptedAtMs = 1200;
  camera.baseFixSequence = 10;
  camera.baseCameraSequence = 1;
  scheduler.markPublished(1200, fix);

  // Foreground movement is always serviced, but sub-deadband drift does not
  // schedule geometry or hide a compatible base.
  fix.sequence = 11;
  scheduler.observe(fix);
  camera.riderOffsetPixels = 1.9;
  auto small = scheduler.evaluate(1800, camera, true, true);
  assert(small.updateForeground && !small.submitBase);
  assert(visibility(camera, false) == Visibility::Compatible);

  // Projected displacement, not a fixed metre threshold, admits a refresh.
  camera.riderOffsetPixels = kRecenterThresholdPixels;
  auto recenter = scheduler.evaluate(2000, camera, true, true);
  assert(recenter.submitBase);
  assert((recenter.reasons & reasonMask(Reason::Position)) != 0);
  scheduler.markSubmitted(2000, fix, recenter.reasons);

  // A compatible running job finishes. Exactly one latest successor is
  // retained, and a newer fix replaces that pending successor at cadence.
  camera.renderRunning = true;
  camera.successorPending = false;
  fix.sequence = 12;
  scheduler.observe(fix);
  auto queued = scheduler.evaluate(3000, camera, true, true);
  assert(queued.keepRunning && queued.submitBase && !queued.replacePending);
  scheduler.markSubmitted(3000, fix, queued.reasons);
  camera.successorPending = true;
  camera.latestRequestedFixSequence = 12;
  assert(!scheduler.evaluate(3500, camera, true, true).submitBase);
  fix.sequence = 13;
  scheduler.observe(fix);
  auto replacement = scheduler.evaluate(4000, camera, true, true);
  assert(replacement.keepRunning && replacement.submitBase &&
         replacement.replacePending);

  // The two-second moving deadline raises urgency without making the old map
  // invisible. Camera lag by itself is not a visibility deadline.
  CameraState delayed = camera;
  delayed.renderRunning = false;
  delayed.successorPending = false;
  delayed.baseAcceptedAtMs = 1000;
  delayed.riderOffsetPixels = kMarkerDeadbandPixels;
  fix.sequence = 14;
  scheduler.observe(fix);
  auto deadline = scheduler.evaluate(4001, delayed, true, true);
  assert(deadline.submitBase);
  assert((deadline.reasons & reasonMask(Reason::MaximumDeferral)) != 0);
  assert(visibility(delayed, true) == Visibility::Recentering);
  delayed.mapCoverageAvailable = false;
  assert(visibility(delayed, true) == Visibility::NoCoverage);
  delayed.mapCoverageAvailable = true;
  delayed.baseCompatible = false;
  assert(visibility(delayed, true) == Visibility::Incompatible);

  // Hard changes supersede incompatible work immediately and stay distinct
  // from ordinary position/heading coalescing.
  Scheduler hard;
  hard.observe(fix);
  hard.request(Reason::Screen);
  camera.renderRunning = true;
  camera.successorPending = true;
  auto screen = hard.evaluate(10, camera, true, true);
  assert(screen.submitBase && screen.hardInvalidation && !screen.keepRunning);

  // Deterministic render-duration fixtures: 200 ms, 800 ms and multi-second
  // jobs all retain one running request plus at most one latest successor.
  for (uint32_t renderMs : {200U, 800U, 3200U}) {
    Scheduler replay;
    CameraState state;
    Fix moving{1, 0, 18.0, 0.0, true};
    uint32_t runningUntil = 0;
    uint32_t pendingSequence = 0;
    uint32_t maximumPending = 0;
    for (uint32_t now = 100; now <= 10000; now += 100) {
      moving.sequence = now / 100;
      replay.observe(moving);
      state.hasBase = now > 100;
      state.baseCompatible = state.hasBase;
      state.mapCoverageAvailable = state.hasBase;
      state.riderProjected = state.hasBase;
      state.riderInsideViewport = state.hasBase;
      state.riderOffsetPixels = state.hasBase ? 7.0 : 0.0;
      state.baseAcceptedAtMs = state.hasBase ? 100 : 0;
      state.renderRunning = runningUntil > now;
      state.successorPending = pendingSequence != 0;
      state.latestRequestedFixSequence = pendingSequence;
      const auto decision = replay.evaluate(now, state, true, false);
      if (decision.submitBase) {
        replay.markSubmitted(now, moving, decision.reasons);
        if (state.renderRunning)
          pendingSequence = moving.sequence;
        else
          runningUntil = now + renderMs;
      }
      if (runningUntil != 0 && now >= runningUntil) {
        runningUntil = pendingSequence ? now + renderMs : 0;
        pendingSequence = 0;
      }
      maximumPending = std::max(maximumPending, pendingSequence ? 1U : 0U);
    }
    assert(maximumPending <= 1);
  }

  DispositionLedger ledger;
  assert(ledger.accept(1).disposition == Disposition::None);
  auto coalesced = ledger.accept(2);
  assert(coalesced.sequence == 1 && coalesced.newerSequence == 2 &&
         coalesced.disposition == Disposition::Coalesced);
  auto foreground = ledger.foreground(2);
  assert(foreground.disposition == Disposition::Foreground);
  assert(ledger.base(2).disposition == Disposition::None);
  assert(ledger.accept(3).disposition == Disposition::None);
  assert(ledger.ignore(3, Disposition::Deadband).disposition ==
         Disposition::Deadband);
  const auto counters = ledger.counters();
  assert(counters.accepted == 3 && counters.coalesced == 1 &&
         counters.foreground == 1 && counters.ignored == 1);

  return 0;
}
