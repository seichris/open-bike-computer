/**
 * @file mapSchedulerFamily.hpp
 * @brief The main screen's map scheduler contract, implemented per display
 *        family (docs/plans/board-support-architecture-plan.md, layer 3).
 *
 * mainScr.cpp owns the LVGL tick, the render pipeline calls and the shared
 * decision effects (recentre, redraw, power metrics); the family decides when
 * a base render is wanted and tracks what was submitted, rendered or
 * published. mapSchedulerAmoled.cpp wraps map_render_policy::Scheduler;
 * mapSchedulerEpaper.cpp wraps epaper_navigation_policy with its heading
 * filter and disposition ledger, and keeps the panel's frame provenance.
 */

#pragma once

#include "mapRenderPolicy.hpp"

#include <cstdint>

namespace map_scheduler {

struct Decision {
  bool render = false;
  // In map_render_policy::Reason terms, for the power metrics.
  uint32_t reasons = 0;
};

// Packet identity that the UI change tracker must hash when a family treats
// it as presentation provenance (the e-paper); untracked otherwise.
struct FixProvenance {
  bool tracked = false;
  uint32_t sequence = 0;
  uint32_t capturedAtMs = 0;
};

void request(map_render_policy::Reason reason);
FixProvenance fixProvenance();
// Feeds the latest course fix once a GPS or route change was observed.
void observe(uint32_t nowMs, bool gpsChanged, bool routeChanged,
             const map_render_policy::Fix &course);
// Decides whether a base render is wanted now and logs the family's reasons.
Decision evaluate(uint32_t nowMs, bool followPosition, bool courseUp);
// A vector render job was accepted for the visible screen.
void markSubmitted(uint32_t nowMs, const map_render_policy::Fix &course);
// A render-ahead job for the next map screen was accepted.
void markSubmittedForRenderAhead(uint32_t nowMs,
                                 const map_render_policy::Fix &course);
// A synchronous raster render completed on the UI task.
void markRendered(uint32_t nowMs, const map_render_policy::Fix &course);
// A render job failed; returns the forced reasons now pending.
uint32_t markInterrupted();
// The render pipeline published a worker frame; consumes mapView's
// publication record.
void markFramePublished(uint32_t nowMs, const map_render_policy::Fix &course);
// Distance as the family presents it on the guidance labels.
uint16_t presentedDistanceMeters(uint16_t distanceMeters);
// Before LVGL draws the frame: snapshot the logical state it represents.
void captureFrameProvenance();
// The active screen instance changed.
void screenInstanceChanged();

}  // namespace map_scheduler
