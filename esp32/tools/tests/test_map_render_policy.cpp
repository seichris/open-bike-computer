#include "../../lib/gui/src/mapRenderPolicy.hpp"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <limits>

namespace {

map_render_policy::Fix northOf(const map_render_policy::Fix &origin,
                               double meters) {
  map_render_policy::Fix result = origin;
  result.latitude += meters / 111195.0;
  return result;
}

} // namespace

int main() {
  using namespace map_render_policy;

  assert(headingDelta(355, 5) == 10);
  assert(headingDelta(5, 355) == 10);
  assert(headingDelta(20, 200) == 180);

  const Fix origin{51.5007, -0.1246, 359};
  assert(std::fabs(distanceMeters(origin, northOf(origin, 10.0)) - 10.0) <
         0.1);

  Scheduler scheduler;
  scheduler.observe(origin);
  Decision first = scheduler.evaluate(100, true, false);
  assert(first.render);
  assert((first.reasons & reasonMask(Reason::Position)) != 0);
  scheduler.commit(first);
  scheduler.markRendered(100, origin);

  // Sub-threshold movement never schedules a render, even after the cadence.
  scheduler.observe(northOf(origin, 7.9));
  Decision smallMove = scheduler.evaluate(2000, true, false);
  assert(!smallMove.render);
  assert(!smallMove.deferredByCadence);

  // Meaningful movement is retained until the minimum interval expires.
  const Fix moved = northOf(origin, 9.0);
  scheduler.observe(moved);
  Decision earlyMove = scheduler.evaluate(600, true, false);
  assert(!earlyMove.render);
  assert(earlyMove.deferredByCadence);
  Decision dueMove = scheduler.evaluate(850, true, false);
  assert(dueMove.render);
  assert((dueMove.reasons & reasonMask(Reason::Position)) != 0);
  scheduler.commit(dueMove);
  scheduler.markRendered(850, moved);

  // Stationary course noise stays below the heading threshold, including wrap.
  Fix noisy = moved;
  noisy.headingDegrees = 5;
  scheduler.observe(noisy);
  Decision noisyHeading = scheduler.evaluate(2000, true, true);
  assert(!noisyHeading.render);
  noisy.headingDegrees = 12;
  scheduler.observe(noisy);
  Decision thresholdHeading = scheduler.evaluate(2000, true, true);
  assert(thresholdHeading.render);
  assert((thresholdHeading.reasons & reasonMask(Reason::Heading)) != 0);
  scheduler.commit(thresholdHeading);
  scheduler.markRendered(2000, noisy);

  // North-up ignores heading-only changes.
  noisy.headingDegrees = 90;
  scheduler.observe(noisy);
  assert(!scheduler.evaluate(3000, true, false).render);

  // A panned map can keep its lightweight position marker fresh without
  // moving the base map; course-up rotation remains independently eligible.
  Fix pannedMovement = northOf(noisy, 100.0);
  scheduler.observe(pannedMovement);
  assert(!scheduler.evaluate(3000, false, false).render);

  // Forced semantic changes bypass movement and cadence gates and accumulate.
  scheduler.request(Reason::Route);
  scheduler.request(Reason::Style);
  Decision forced = scheduler.evaluate(3001, false, false);
  assert(forced.render);
  assert((forced.reasons & reasonMask(Reason::Route)) != 0);
  assert((forced.reasons & reasonMask(Reason::Style)) != 0);
  scheduler.commit(forced);
  scheduler.markRendered(3001, pannedMovement);

  scheduler.request(Reason::Zoom);
  assert(scheduler.evaluate(3002, true, true).render);
  scheduler.markInterrupted();
  Decision recovery = scheduler.evaluate(3003, true, true);
  assert(recovery.render);
  assert((recovery.reasons & reasonMask(Reason::Zoom)) != 0);
  assert((recovery.reasons & reasonMask(Reason::Recovery)) != 0);

  // A GPS-driven render that is interrupted also retains its semantic reason
  // so the retry is not reported as recovery-only.
  Scheduler interruptedPosition;
  interruptedPosition.observe(origin);
  interruptedPosition.markRendered(0, origin);
  interruptedPosition.observe(northOf(origin, 9.0));
  Decision attemptedPosition =
      interruptedPosition.evaluate(kMinimumRenderIntervalMs, true, false);
  assert(attemptedPosition.render);
  interruptedPosition.commit(attemptedPosition);
  interruptedPosition.markInterrupted();
  Decision retriedPosition = interruptedPosition.evaluate(
      kMinimumRenderIntervalMs + 1, true, false);
  assert(retriedPosition.render);
  assert((retriedPosition.reasons & reasonMask(Reason::Position)) != 0);
  assert((retriedPosition.reasons & reasonMask(Reason::Recovery)) != 0);

  // Unsigned elapsed-time arithmetic stays correct across millis rollover.
  Scheduler rollover;
  rollover.observe(origin);
  rollover.request(Reason::Screen);
  rollover.markRendered(std::numeric_limits<uint32_t>::max() - 400, origin);
  rollover.observe(northOf(origin, 10.0));
  assert(!rollover.evaluate(100, true, false).render);
  assert(rollover.evaluate(400, true, false).render);

  // A deterministic 60-second, 4 Hz straight-line replay keeps every fix but
  // regenerates the base map only when the cumulative 8 m threshold is met.
  Scheduler replay;
  uint32_t replayRenders = 0;
  for (uint32_t sample = 0; sample <= 240; ++sample) {
    Fix fix = northOf(origin, static_cast<double>(sample) * 0.5);
    // Representative wraparound noise must not add course-up renders.
    fix.headingDegrees = sample % 2 == 0 ? 358 : 2;
    replay.observe(fix);
    const uint32_t nowMs = sample * 250;
    const Decision decision = replay.evaluate(nowMs, true, true);
    if (decision.render) {
      replay.commit(decision);
      replay.markRendered(nowMs, fix);
      replayRenders++;
    }
  }
  assert(replayRenders >= 14);
  assert(replayRenders <= 16);
  assert(replayRenders < 241);

  return 0;
}
