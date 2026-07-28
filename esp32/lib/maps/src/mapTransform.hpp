/**
 * @file mapTransform.hpp
 * @brief Shared, host-testable map zoom and coordinate transforms.
 */

#pragma once

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
