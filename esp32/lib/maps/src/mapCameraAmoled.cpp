#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
/**
 * @file mapCameraAmoled.cpp
 * @brief The AMOLED family's stable camera: refresh requests when the
 *        presented rider or bearing drifts from the visible frame.
 */

#include "maps.hpp"
#include "mapCamera.hpp"
#include "mapPresentation.hpp"
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../gui/src/mainScr.hpp"
#include "../../renderer_diagnostics/renderer_diagnostics.hpp"

#include <cmath>

extern Gps gps;

void Maps::serviceStableCamera(uint32_t nowMs) {
  if (!map_profile_protocol::STABLE_CAMERA_ENABLED ||
      !publishedMapFrame || !hasVisibleProjection)
    return;
  const bool current = renderResultStillCurrent(visibleRenderResult);
  const auto target = visibleRenderResult.followPosition && hasPresentedPose
      ? map_transform::WorldPoint{presentedPose.position.x, presentedPose.position.y}
      : visibleRenderResult.center;
  double bearing = visibleRenderResult.rotationRad;
  if (rotationMode == ROT_NORTH_UP)
    bearing = 0;
  else if (hasPresentedPose && presentedPose.headingValid)
    bearing = -presentedPose.headingDegrees * map_presentation::kPi / 180.0;
  const bool required = !current ||
      map_camera::needsRefresh(visibleProjection, target, bearing);
  cameraLag.observe(required, nowMs);
  renderer_diagnostics::CameraSample sample;
  sample.enabled = true;
  sample.hidden = false;
  sample.updateRequired = required;
  sample.frameSequence = visibleRenderResult.version.sequence;
  sample.sceneGeneration = visibleRenderResult.sceneGeneration;
  sample.sceneReused = visibleRenderResult.sceneReused;
  sample.requestedAtMs = visibleRenderResult.requestedAtMs;
  sample.observedAtMs = nowMs;
  sample.lagMs = cameraLag.age(nowMs);
  sample.displayedBearingTenths = static_cast<int16_t>(std::lround(
      visibleRenderResult.rotationRad * 1800 / map_presentation::kPi));
  sample.targetBearingTenths = static_cast<int16_t>(std::lround(
      bearing * 1800 / map_presentation::kPi));
  sample.markerAngleTenths = hasPresentedPose && presentedPose.headingValid
      ? static_cast<uint16_t>(std::lround(map_camera::markerAngle(
            visibleProjection, {presentedPose.position.x, presentedPose.position.y},
            presentedPose.headingDegrees) * 10)) % 3600
      : 0;
  sample.effectiveTopScalePermille = visibleProjection.isBirdsEye()
      ? static_cast<uint16_t>(std::lround(visibleProjection.config().topEdgeScale * 1000))
      : 1000;
  sample.requestedMode = isMapGuidanceScreenActive()
      ? mapRenderSettings.mapNavigationRotationMode : mapRenderSettings.mapRotationMode;
  sample.effectiveMode = visibleRenderResult.effectiveRotationMode;
  sample.labelDensity = visibleRenderResult.labelDensity;
  sample.labelOrientation = visibleRenderResult.labelOrientation;
  renderer_diagnostics::noteCameraForWindow(
      visibleRenderResult.version.diagnosticsWindowId, sample);
  cameraEvidence = sample;
  if (required && uint32_t(nowMs - lastCameraRequestMs) >= map_camera::kRefreshIntervalMs) {
    RenderRequest request;
    if (buildRenderRequest(zoom, nowMs, request) && submitRenderRequest(request))
      lastCameraRequestMs = nowMs;
  }
}

bool Maps::readyFrameCovered(const RenderResult &ready, bool projectedValid,
                             double projectedX, double projectedY,
                             double rotationDelta) const {
  return map_profile_protocol::STABLE_CAMERA_ENABLED
      ? map_camera::cropCovered(
          ready.renderWidth, ready.renderHeight,
          ready.viewportWidth, ready.viewportHeight,
          ready.overscanPixels, MAP_RENDER_SAFETY_PIXELS,
          MAP_RENDER_ROUND_VIEWPORT)
      : projectedValid && map_presentation::frameCoversViewport(
          ready.renderWidth, ready.renderHeight,
          ready.viewportWidth, ready.viewportHeight,
          {projectedX, projectedY},
          {ready.projection.anchorX() - ready.overscanPixels,
           ready.projection.anchorY() - ready.overscanPixels},
          rotationDelta, MAP_RENDER_SAFETY_PIXELS,
          MAP_RENDER_ROUND_VIEWPORT);
}

void Maps::captureRequestProvenance(RenderRequest &request) const {
  // The AMOLED scheduler keys its base frames on the course fix alone.
  (void)request;
}
#endif
