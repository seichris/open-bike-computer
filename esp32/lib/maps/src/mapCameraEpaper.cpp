#if defined(WAVESHARE_EPAPER_397)
/**
 * @file mapCameraEpaper.cpp
 * @brief The 3.97-inch e-paper's stable camera: visibility and diagnostics
 *        only; base-render admission is owned by the e-paper scheduler in
 *        lib/gui/src/mapSchedulerEpaper.cpp.
 */

#include "maps.hpp"
#include "mapCamera.hpp"
#include "mapPresentation.hpp"
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../gui/src/mainScr.hpp"
#include "../../renderer_diagnostics/renderer_diagnostics.hpp"
#include "../../gui/src/epaperNavigationPolicy.hpp"
#include <cmath>

extern Gps gps;

void Maps::serviceStableCamera(uint32_t nowMs) {
  if (!map_profile_protocol::STABLE_CAMERA_ENABLED ||
      !publishedMapFrame || !hasVisibleProjection)
    return;
  const CameraState camera = captureCameraState();
  const bool updateRequired =
      camera.baseCompatible && camera.mapCoverageAvailable &&
      camera.riderProjected &&
      (camera.riderOffsetPixels >=
           epaper_navigation_policy::kMarkerDeadbandPixels ||
       camera.headingDeltaDegrees >=
           epaper_navigation_policy::kHeadingThresholdDegrees / 2.0);
  const epaper_navigation_policy::Visibility state =
      epaper_navigation_policy::visibility(
          {camera.hasBase,
           camera.baseCompatible,
           camera.mapCoverageAvailable,
           camera.riderProjected,
           camera.riderInsideViewport,
           camera.riderOffsetPixels,
           camera.headingDeltaDegrees,
           camera.baseAcceptedAtMs,
           camera.baseFixSequence,
           camera.baseCameraSequence,
           camera.renderRunning,
           camera.successorPending,
           camera.latestRequestedFixSequence},
          updateRequired);
  const bool hidden =
      state == epaper_navigation_policy::Visibility::NoBase ||
      state == epaper_navigation_policy::Visibility::Incompatible ||
      state == epaper_navigation_policy::Visibility::RiderOutsideCoverage;
  // Routine camera movement is not an attention state. Keep diagnostic
  // recentering in telemetry; epaper_ui owns the persistent fault/coverage line.
  renderer_diagnostics::CameraSample sample;
  sample.enabled = true;
  sample.hidden = hidden;
  sample.updateRequired = updateRequired;
  sample.frameSequence = visibleRenderResult.version.sequence;
  sample.sceneGeneration = visibleRenderResult.sceneGeneration;
  sample.sceneReused = visibleRenderResult.sceneReused;
  sample.requestedAtMs = visibleRenderResult.requestedAtMs;
  sample.observedAtMs = nowMs;
  sample.lagMs = visibleFrameAcceptedAtMs_ == 0
                     ? 0
                     : static_cast<uint32_t>(nowMs -
                                             visibleFrameAcceptedAtMs_);
  sample.displayedBearingTenths = static_cast<int16_t>(std::lround(
      visibleRenderResult.rotationRad * 1800 / map_presentation::kPi));
  const double targetBearing = cameraHeadingValid_
                                   ? -cameraHeadingDegrees_
                                   : 0.0;
  sample.targetBearingTenths = static_cast<int16_t>(std::lround(
      targetBearing * 10.0));
  sample.markerAngleTenths = hasPresentedPose && presentedPose.headingValid
      ? static_cast<uint16_t>(std::lround(map_camera::markerAngle(
            visibleProjection, {presentedPose.position.x, presentedPose.position.y},
            presentedPose.headingDegrees) * 10)) % 3600
      : 0;
  sample.effectiveTopScalePermille = visibleProjection.isBirdsEye()
      ? static_cast<uint16_t>(std::lround(visibleProjection.config().topEdgeScale * 1000))
      : 1000;
  sample.requestedMode = isMapGuidanceScreenActive()
      ? mapRenderSettings.mapNavigationRotationMode
      : mapRenderSettings.mapRotationMode;
  sample.effectiveMode = visibleRenderResult.effectiveRotationMode;
  sample.labelDensity = visibleRenderResult.labelDensity;
  sample.labelOrientation = visibleRenderResult.labelOrientation;
  renderer_diagnostics::noteCameraForWindow(
      visibleRenderResult.version.diagnosticsWindowId, sample);
  cameraEvidence = sample;
  // Base-render admission is owned exclusively by the 3.97-inch scheduler in
  // mainScr.cpp. This service only maintains visibility and diagnostics.
}

bool Maps::readyFrameCovered(const RenderResult &ready, bool projectedValid,
                             double projectedX, double projectedY,
                             double rotationDelta) const {
  // The e-paper presents a static base frame: beyond the crop, the rider
  // must sit inside the viewport's safety margin.
  const bool stableCropCovered = map_camera::cropCovered(
      ready.renderWidth, ready.renderHeight,
      ready.viewportWidth, ready.viewportHeight,
      ready.overscanPixels, MAP_RENDER_SAFETY_PIXELS,
      MAP_RENDER_ROUND_VIEWPORT);
  const double insideX = projectedX - ready.overscanPixels;
  const double insideY = projectedY - ready.overscanPixels;
  const bool riderCovered =
      projectedValid && insideX >= MAP_RENDER_SAFETY_PIXELS &&
      insideY >= MAP_RENDER_SAFETY_PIXELS &&
      insideX < ready.viewportWidth - MAP_RENDER_SAFETY_PIXELS &&
      insideY < ready.viewportHeight - MAP_RENDER_SAFETY_PIXELS;
  return map_profile_protocol::STABLE_CAMERA_ENABLED
             ? stableCropCovered && riderCovered
             : projectedValid &&
                   map_presentation::frameCoversViewport(
                       ready.renderWidth, ready.renderHeight,
                       ready.viewportWidth, ready.viewportHeight,
                       {projectedX, projectedY},
                       {ready.projection.anchorX() - ready.overscanPixels,
                        ready.projection.anchorY() - ready.overscanPixels},
                       rotationDelta, MAP_RENDER_SAFETY_PIXELS,
                       MAP_RENDER_ROUND_VIEWPORT);
}

void Maps::captureRequestProvenance(RenderRequest &request) const {
  const BLEDebugStats ble = bleNavServer.getDebugStats();
  request.capturedFixSequence = ble.gpsPacketCount;
  request.capturedFixAtMs = ble.lastGpsCapturedAtMs;
  request.capturedSpeedKmh = gps.gpsData.speed;
  request.capturedHeadingDegrees = cameraHeadingDegrees_;
  request.capturedHeadingValid = cameraHeadingValid_;
}
#endif
