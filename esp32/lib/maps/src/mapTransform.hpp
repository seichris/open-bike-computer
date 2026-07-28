/**
 * @file mapTransform.hpp
 * @brief Shared, host-testable map zoom and coordinate transforms.
 */

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace map_transform {

constexpr uint8_t kMinimumRuntimeZoom = 1;
constexpr uint8_t kMaximumRuntimeZoom = 5;

struct ScreenDelta {
  double x = 0.0;
  double y = 0.0;
};

struct WorldPoint {
  double x = 0.0;
  double y = 0.0;
};

struct WorldBounds {
  WorldPoint min;
  WorldPoint max;
};

struct PixelOffset {
  int32_t x = 0;
  int32_t y = 0;
};

struct RollingDragRebase {
  PixelOffset center;
  PixelOffset rasterCenterOffset;
  PixelOffset canvasOffset;
};

inline int32_t quantizePixel(double value) {
  // floor(x + 0.5) is invariant under integer translations, including at
  // half-pixel ties. std::round() changes tie direction across zero, which
  // makes neighboring independently rendered raster cells disagree.
  return static_cast<int32_t>(std::floor(value + 0.5));
}

inline uint8_t clampRuntimeZoom(uint8_t zoom) {
  if (zoom < kMinimumRuntimeZoom)
    return kMinimumRuntimeZoom;
  if (zoom > kMaximumRuntimeZoom)
    return kMaximumRuntimeZoom;
  return zoom;
}

inline double worldToScreenScale(uint8_t zoom) {
  // Zoom 0 remains supported for legacy renderer calculations, while runtime
  // Map controls and pinch settlement are deliberately bounded to 1...5.
  if (zoom == 0)
    return 2.0;
  if (zoom == 1)
    return 1.5;
  return 1.0 / static_cast<double>(zoom - 1);
}

inline double screenToWorldScale(uint8_t zoom) {
  return 1.0 / worldToScreenScale(zoom);
}

inline double clampPreviewRatio(double ratio, uint8_t baseZoom) {
  const double baseScale = worldToScreenScale(clampRuntimeZoom(baseZoom));
  const double minimumRatio =
      worldToScreenScale(kMaximumRuntimeZoom) / baseScale;
  const double maximumRatio =
      worldToScreenScale(kMinimumRuntimeZoom) / baseScale;
  if (ratio < minimumRatio)
    return minimumRatio;
  if (ratio > maximumRatio)
    return maximumRatio;
  return ratio;
}

inline double backdropPresentationRatio(double previewRatio, uint8_t baseZoom,
                                        uint8_t backdropZoom) {
  const double baseScale = worldToScreenScale(clampRuntimeZoom(baseZoom));
  const double backdropScale =
      worldToScreenScale(clampRuntimeZoom(backdropZoom));
  return clampPreviewRatio(previewRatio, baseZoom) /
         (backdropScale / baseScale);
}

inline uint8_t nearestRuntimeZoom(double effectiveWorldScale) {
  if (!(effectiveWorldScale > 0.0))
    return kMaximumRuntimeZoom;
  uint8_t nearest = kMinimumRuntimeZoom;
  double nearestDistance = std::fabs(
      std::log(effectiveWorldScale / worldToScreenScale(nearest)));
  for (uint8_t zoom = kMinimumRuntimeZoom + 1;
       zoom <= kMaximumRuntimeZoom; ++zoom) {
    const double distance = std::fabs(
        std::log(effectiveWorldScale / worldToScreenScale(zoom)));
    if (distance < nearestDistance) {
      nearest = zoom;
      nearestDistance = distance;
    }
  }
  return nearest;
}

inline ScreenDelta worldToScreen(WorldPoint worldDelta, uint8_t zoom,
                                 double rotationRad) {
  const double scale = worldToScreenScale(zoom);
  const double unrotatedX = worldDelta.x * scale;
  const double unrotatedY = -worldDelta.y * scale;
  const double cosA = std::cos(rotationRad);
  const double sinA = std::sin(rotationRad);
  return {unrotatedX * cosA - unrotatedY * sinA,
          unrotatedX * sinA + unrotatedY * cosA};
}

inline WorldPoint screenToWorld(ScreenDelta screenDelta, uint8_t zoom,
                                double rotationRad) {
  const double cosA = std::cos(rotationRad);
  const double sinA = std::sin(rotationRad);
  const double unrotatedX = screenDelta.x * cosA + screenDelta.y * sinA;
  const double unrotatedY = -screenDelta.x * sinA + screenDelta.y * cosA;
  const double inverseScale = screenToWorldScale(zoom);
  return {unrotatedX * inverseScale, -unrotatedY * inverseScale};
}

inline WorldPoint centerAfterScreenDrag(WorldPoint baseCenter,
                                        ScreenDelta dragOffset, uint8_t zoom,
                                        double rotationRad) {
  const WorldPoint worldDelta =
      screenToWorld(dragOffset, zoom, rotationRad);
  return {baseCenter.x + worldDelta.x, baseCenter.y + worldDelta.y};
}

inline PixelOffset rasterCenterOffset(WorldPoint center, WorldPoint origin,
                                      uint8_t zoom, double rotationRad) {
  const ScreenDelta offset = worldToScreen(
      {center.x - origin.x, center.y - origin.y}, zoom, rotationRad);
  return {quantizePixel(offset.x), quantizePixel(offset.y)};
}

inline PixelOffset rasterCellPixel(WorldPoint feature, WorldPoint rasterOrigin,
                                   PixelOffset cellOffset, uint8_t zoom,
                                   double rotationRad) {
  // Quantize once in the shared raster coordinate system, then translate into
  // a cell by its exact integer offset. Deriving a cell center with
  // screenToWorld() and projecting it back can cross a half-pixel tie because
  // of floating-point error, even with an otherwise invariant quantizer.
  const ScreenDelta common = worldToScreen(
      {feature.x - rasterOrigin.x, feature.y - rasterOrigin.y}, zoom,
      rotationRad);
  return {quantizePixel(common.x) - cellOffset.x,
          quantizePixel(common.y) - cellOffset.y};
}

inline RollingDragRebase rollingDragRebase(WorldPoint baseCenter,
                                           ScreenDelta presentedOffset,
                                           uint8_t zoom, double rotationRad,
                                           WorldPoint rasterPhaseOrigin,
                                           PixelOffset rasterOriginOffset =
                                               {0, 0}) {
  const WorldPoint endpoint = centerAfterScreenDrag(
      baseCenter, presentedOffset, zoom, rotationRad);
  RollingDragRebase result;
  result.center = {static_cast<int32_t>(std::round(endpoint.x)),
                   static_cast<int32_t>(std::round(endpoint.y))};
  result.rasterCenterOffset = rasterCellPixel(
      {static_cast<double>(result.center.x),
       static_cast<double>(result.center.y)},
      rasterPhaseOrigin, rasterOriginOffset, zoom, rotationRad);
  result.canvasOffset = {-result.rasterCenterOffset.x,
                         -result.rasterCenterOffset.y};
  return result;
}

inline double renderRotationForSettlement(bool settlementPending,
                                          double frozenRotation,
                                          double currentRotation) {
  return settlementPending ? frozenRotation : currentRotation;
}

inline bool rotationNeedsRefresh(double renderedRotation,
                                 double currentRotation) {
  return std::fabs(std::atan2(std::sin(renderedRotation - currentRotation),
                             std::cos(renderedRotation - currentRotation))) >
         1e-9;
}

inline WorldBounds canvasWorldBounds(WorldPoint center, double canvasWidth,
                                     double canvasHeight, uint8_t zoom,
                                     double rotationRad) {
  const double halfWidth = canvasWidth / 2.0;
  const double halfHeight = canvasHeight / 2.0;
  WorldBounds bounds;
  bool first = true;
  for (const double screenX : {-halfWidth, halfWidth}) {
    for (const double screenY : {-halfHeight, halfHeight}) {
      const WorldPoint delta =
          screenToWorld({screenX, screenY}, zoom, rotationRad);
      const WorldPoint corner = {center.x + delta.x, center.y + delta.y};
      if (first) {
        bounds.min = corner;
        bounds.max = corner;
        first = false;
      } else {
        bounds.min.x = std::min(bounds.min.x, corner.x);
        bounds.min.y = std::min(bounds.min.y, corner.y);
        bounds.max.x = std::max(bounds.max.x, corner.x);
        bounds.max.y = std::max(bounds.max.y, corner.y);
      }
    }
  }
  return bounds;
}

inline WorldPoint focalPreservingCenter(
    WorldPoint initialCenter, ScreenDelta initialFocalFromAnchor,
    ScreenDelta finalFocalFromAnchor, uint8_t initialZoom, uint8_t finalZoom,
    double rotationRad) {
  const WorldPoint initialOffset =
      screenToWorld(initialFocalFromAnchor, initialZoom, rotationRad);
  const WorldPoint focal = {initialCenter.x + initialOffset.x,
                            initialCenter.y + initialOffset.y};
  const WorldPoint finalOffset =
      screenToWorld(finalFocalFromAnchor, finalZoom, rotationRad);
  return {focal.x - finalOffset.x, focal.y - finalOffset.y};
}

} // namespace map_transform
