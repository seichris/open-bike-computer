#if defined(WAVESHARE_EPAPER_397)
/**
 * @file mapSchedulerEpaper.cpp
 * @brief The 3.97-inch e-paper's map scheduler: fix provenance, the filtered
 *        camera heading, base-render admission against the visible camera and
 *        the disposition ledger, over epaper_navigation_policy.
 */

#include "mapSchedulerFamily.hpp"

#include "../../ble_navigation/ble_navigation.hpp"
#include "../../epaper_display/epaper_display.hpp"
#include "../../maps/src/maps.hpp"
#include "epaperNavigationPolicy.hpp"
#include "gps.hpp"

#include <Arduino.h>

extern Gps gps;
extern Maps mapView;

namespace map_scheduler {
namespace {

epaper_navigation_policy::Scheduler epaperNavigationScheduler;
epaper_navigation_policy::HeadingFilter epaperHeadingFilter;
epaper_navigation_policy::DispositionLedger epaperDispositionLedger;
uint32_t epaperArmedRenderReasons = 0;

epaper_navigation_policy::Reason
epaperReasonForMapReason(map_render_policy::Reason reason) {
  using EpaperReason = epaper_navigation_policy::Reason;
  switch (reason) {
  case map_render_policy::Reason::Position:
    return EpaperReason::Position;
  case map_render_policy::Reason::Heading:
    return EpaperReason::Heading;
  case map_render_policy::Reason::Route:
    return EpaperReason::RouteSession;
  case map_render_policy::Reason::Style:
  case map_render_policy::Reason::Zoom:
    return EpaperReason::MapContext;
  case map_render_policy::Reason::Screen:
    return EpaperReason::Screen;
  case map_render_policy::Reason::Recovery:
  case map_render_policy::Reason::Other:
  default:
    return EpaperReason::Recovery;
  }
}

uint32_t mapReasonsForEpaperReasons(uint32_t reasons) {
  uint32_t mapped = 0;
  using EpaperReason = epaper_navigation_policy::Reason;
  using MapReason = map_render_policy::Reason;
  if (reasons & epaper_navigation_policy::reasonMask(EpaperReason::Position))
    mapped |= map_render_policy::reasonMask(MapReason::Position);
  if (reasons & epaper_navigation_policy::reasonMask(EpaperReason::Heading))
    mapped |= map_render_policy::reasonMask(MapReason::Heading);
  if (reasons & epaper_navigation_policy::reasonMask(
                    EpaperReason::MaximumDeferral))
    mapped |= map_render_policy::reasonMask(MapReason::Position);
  if (reasons & epaper_navigation_policy::reasonMask(EpaperReason::Screen))
    mapped |= map_render_policy::reasonMask(MapReason::Screen);
  if (reasons & epaper_navigation_policy::reasonMask(EpaperReason::MapContext))
    mapped |= map_render_policy::reasonMask(MapReason::Style);
  if (reasons & epaper_navigation_policy::reasonMask(
                    EpaperReason::RouteSession))
    mapped |= map_render_policy::reasonMask(MapReason::Route);
  if (reasons & epaper_navigation_policy::reasonMask(EpaperReason::Recovery))
    mapped |= map_render_policy::reasonMask(MapReason::Recovery);
  return mapped;
}

epaper_navigation_policy::Fix currentEpaperFix(uint32_t nowMs) {
  const BLEDebugStats ble = bleNavServer.getDebugStats();
  const auto filtered = epaperHeadingFilter.current();
  return {
      ble.gpsPacketCount,
      ble.lastGpsCapturedAtMs != 0 ? ble.lastGpsCapturedAtMs : nowMs,
      static_cast<double>(gps.gpsData.speed),
      filtered.degrees,
      filtered.valid,
  };
}

epaper_navigation_policy::CameraState currentEpaperCameraState() {
  const Maps::CameraState source = mapView.captureCameraState();
  return {
      source.hasBase,
      source.baseCompatible,
      source.mapCoverageAvailable,
      source.riderProjected,
      source.riderInsideViewport,
      source.riderOffsetPixels,
      source.headingDeltaDegrees,
      source.baseAcceptedAtMs,
      source.baseFixSequence,
      source.baseCameraSequence,
      source.renderRunning,
      source.successorPending,
      source.latestRequestedFixSequence,
  };
}

#if FIRMWARE_DIAGNOSTICS
const char *dispositionName(
    epaper_navigation_policy::Disposition disposition) {
  using Disposition = epaper_navigation_policy::Disposition;
  switch (disposition) {
  case Disposition::Foreground: return "foreground";
  case Disposition::Base: return "base";
  case Disposition::Coalesced: return "coalesced";
  case Disposition::Duplicate: return "duplicate";
  case Disposition::Invalid: return "invalid";
  case Disposition::Stale: return "stale";
  case Disposition::Deadband: return "deadband";
  case Disposition::Incompatible: return "incompatible";
  case Disposition::None:
  default: return "none";
  }
}
#endif

void logDisposition(
    const epaper_navigation_policy::DispositionEvent &event) {
#if FIRMWARE_DIAGNOSTICS
  if (event.disposition != epaper_navigation_policy::Disposition::None) {
    Serial.printf("EPAPER_NAV_DISPOSITION fix=%lu disposition=%s newer=%lu\n",
                  static_cast<unsigned long>(event.sequence),
                  dispositionName(event.disposition),
                  static_cast<unsigned long>(event.newerSequence));
  }
#else
  (void)event;
#endif
}

uint32_t currentEpaperAcceptedGpsSequence() {
  return bleNavServer.getDebugStats().gpsPacketCount;
}

uint32_t currentEpaperBaseCameraSequence() {
  return mapView.visibleCameraSequence();
}

}  // namespace

void request(map_render_policy::Reason reason) {
  epaperNavigationScheduler.request(epaperReasonForMapReason(reason));
}

FixProvenance fixProvenance() {
  const BLEDebugStats ble = bleNavServer.getDebugStats();
  return {true, ble.gpsPacketCount, ble.lastGpsCapturedAtMs};
}

void observe(uint32_t nowMs, bool gpsChanged, bool routeChanged,
             CourseFix courseFix) {
  if (!(gpsChanged || routeChanged)) {
    return;
  }
  const BLEDebugStats ble = bleNavServer.getDebugStats();
  const map_render_policy::Fix course = courseFix();
  const uint32_t capturedAtMs =
      gpsChanged && ble.lastGpsCapturedAtMs != 0
          ? ble.lastGpsCapturedAtMs
          : nowMs;
  const auto filtered = epaperHeadingFilter.observe(
      {ble.gpsPacketCount, capturedAtMs,
       static_cast<double>(gps.gpsData.speed),
       static_cast<double>(course.headingDegrees), course.headingValid});
  mapView.setCameraHeading(filtered.degrees, filtered.valid);
  const epaper_navigation_policy::Fix fix = currentEpaperFix(nowMs);
  epaperNavigationScheduler.observe(fix);
  if (gpsChanged)
    logDisposition(epaperDispositionLedger.accept(fix.sequence));
}

Decision evaluate(uint32_t nowMs, bool followPosition, bool courseUp) {
  const epaper_navigation_policy::CameraState camera =
      currentEpaperCameraState();
  if (camera.hasBase && camera.baseCompatible &&
      camera.mapCoverageAvailable && camera.riderProjected &&
      camera.riderInsideViewport) {
    logDisposition(epaperDispositionLedger.foreground(
        epaperNavigationScheduler.latestFix().sequence));
  }

  Decision result;
  if (epaperArmedRenderReasons == 0 &&
      epaperNavigationScheduler.hasPendingWork()) {
    const epaper_navigation_policy::Decision decision =
        epaperNavigationScheduler.evaluate(nowMs, camera, followPosition,
                                           courseUp);
    if (decision.submitBase) {
      epaperArmedRenderReasons = decision.reasons;
      result.render = true;
      result.reasons = mapReasonsForEpaperReasons(decision.reasons);
      if (decision.urgent)
        epaper::prioritize();
      log_i("E-paper map scheduler: request reasons=0x%02lx pixels=%.1f "
            "heading=%.1f running=%u replace=%u",
            static_cast<unsigned long>(decision.reasons),
            camera.riderOffsetPixels, camera.headingDeltaDegrees,
            decision.keepRunning ? 1U : 0U,
            decision.replacePending ? 1U : 0U);
    }
  }

#if FIRMWARE_DIAGNOSTICS
  static uint32_t lastDispositionSummaryMs = 0;
  if (lastDispositionSummaryMs == 0 ||
      static_cast<uint32_t>(nowMs - lastDispositionSummaryMs) >= 30000U) {
    lastDispositionSummaryMs = nowMs;
    const auto &counters = epaperDispositionLedger.counters();
    Serial.printf("EPAPER_NAV_COUNTER accepted=%lu foreground=%lu base=%lu "
                  "coalesced=%lu ignored=%lu pending=%lu\n",
                  static_cast<unsigned long>(counters.accepted),
                  static_cast<unsigned long>(counters.foreground),
                  static_cast<unsigned long>(counters.base),
                  static_cast<unsigned long>(counters.coalesced),
                  static_cast<unsigned long>(counters.ignored),
                  static_cast<unsigned long>(
                      epaperDispositionLedger.pendingSequence()));
  }
#endif
  return result;
}

void markSubmitted(uint32_t nowMs, CourseFix) {
  const epaper_navigation_policy::Fix submittedFix = currentEpaperFix(nowMs);
  epaperNavigationScheduler.markSubmitted(nowMs, submittedFix,
                                          epaperArmedRenderReasons);
  epaperArmedRenderReasons = 0;
}

void markSubmittedForRenderAhead(uint32_t nowMs, CourseFix) {
  const epaper_navigation_policy::Fix submittedFix = currentEpaperFix(nowMs);
  epaperNavigationScheduler.markSubmitted(
      nowMs, submittedFix,
      epaper_navigation_policy::reasonMask(
          epaper_navigation_policy::Reason::Screen));
  epaperArmedRenderReasons = 0;
}

void markRendered(uint32_t nowMs, CourseFix) {
  epaperNavigationScheduler.markPublished(nowMs, currentEpaperFix(nowMs));
  epaperArmedRenderReasons = 0;
}

uint32_t markInterrupted() {
  epaperNavigationScheduler.markInterrupted();
  return mapReasonsForEpaperReasons(
      epaperNavigationScheduler.pendingForcedReasons());
}

void markFramePublished(uint32_t nowMs, CourseFix) {
  Maps::FramePublication publication;
  if (mapView.takeFramePublication(publication)) {
    const epaper_navigation_policy::Fix captured{
        publication.capturedFixSequence,
        publication.capturedFixAtMs,
        publication.capturedSpeedKmh,
        publication.capturedHeadingDegrees,
        publication.capturedHeadingValid,
    };
    epaperNavigationScheduler.markPublished(nowMs, captured);
    logDisposition(
        epaperDispositionLedger.base(publication.capturedFixSequence));
  }
}

uint16_t presentedDistanceMeters(uint16_t distanceMeters) {
  return epaper_navigation_policy::quantizeDistanceMeters(distanceMeters);
}

void captureFrameProvenance() {
  // The display library owns the snapshot and never reaches back into GUI or
  // map state.
  epaper::setFrameProvenance(currentEpaperAcceptedGpsSequence(),
                             currentEpaperBaseCameraSequence());
}

void screenInstanceChanged() { epaper::invalidateContext(); }

}  // namespace map_scheduler
#endif
