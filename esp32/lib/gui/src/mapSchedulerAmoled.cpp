#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
/**
 * @file mapSchedulerAmoled.cpp
 * @brief The AMOLED family's map scheduler: map_render_policy::Scheduler
 *        over the current course fix.
 */

#include "mapSchedulerFamily.hpp"

#include "../../maps/src/maps.hpp"

#include <Arduino.h>

extern Maps mapView;

namespace map_scheduler {
namespace {

map_render_policy::Scheduler mapRenderScheduler;

}  // namespace

void request(map_render_policy::Reason reason) {
  mapRenderScheduler.request(reason);
}

FixProvenance fixProvenance() { return {}; }

void observe(uint32_t, bool gpsChanged, bool routeChanged,
             const map_render_policy::Fix &course) {
  if (gpsChanged || routeChanged) {
    mapRenderScheduler.observe(course);
  }
}

Decision evaluate(uint32_t nowMs, bool followPosition, bool courseUp) {
  Decision result;
  if (!mapRenderScheduler.hasPendingWork()) {
    return result;
  }
  const map_render_policy::Decision decision =
      mapRenderScheduler.evaluate(nowMs, followPosition, courseUp);
  if (!decision.render) {
    return result;
  }
  mapRenderScheduler.commit(decision);
  result.render = true;
  result.reasons = decision.reasons;
  log_i("Map scheduler: request reasons=0x%02lx distance=%.1fm "
        "heading=%u",
        static_cast<unsigned long>(decision.reasons),
        decision.distanceMeters,
        static_cast<unsigned>(decision.headingDeltaDegrees));
  return result;
}

void markSubmitted(uint32_t nowMs, const map_render_policy::Fix &course) {
  mapRenderScheduler.markSubmitted(nowMs, course);
}

void markSubmittedForRenderAhead(uint32_t nowMs,
                                 const map_render_policy::Fix &course) {
  mapRenderScheduler.markSubmitted(nowMs, course);
}

void markRendered(uint32_t nowMs, const map_render_policy::Fix &course) {
  mapRenderScheduler.markRendered(nowMs, course);
}

uint32_t markInterrupted() {
  mapRenderScheduler.markInterrupted();
  return mapRenderScheduler.pendingForcedReasons();
}

void markFramePublished(uint32_t nowMs,
                        const map_render_policy::Fix &course) {
  (void)mapView.takeFramePublication();
  mapRenderScheduler.markRendered(nowMs, course);
}

uint16_t presentedDistanceMeters(uint16_t distanceMeters) {
  return distanceMeters;
}

void captureFrameProvenance() {}

void screenInstanceChanged() {}

}  // namespace map_scheduler
#endif
