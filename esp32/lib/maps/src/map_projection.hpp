/**
 * @file map_projection.hpp
 * @brief Shared, host-testable flat and bird's-eye map projection.
 */

#pragma once

#include "mapTransform.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace map_projection {

enum class Mode : uint8_t { Flat = 0, BirdsEye = 1 };

enum class BirdsEyePerspective : uint8_t {
  Gentle = 0,
  Standard = 1,
  Strong = 2,
  VeryStrong = 3,
  Maximum = 4,
};

inline BirdsEyePerspective birdsEyePerspectiveForValue(uint8_t value) {
  switch (value) {
  case static_cast<uint8_t>(BirdsEyePerspective::Gentle):
    return BirdsEyePerspective::Gentle;
  case static_cast<uint8_t>(BirdsEyePerspective::Strong):
    return BirdsEyePerspective::Strong;
  case static_cast<uint8_t>(BirdsEyePerspective::VeryStrong):
    return BirdsEyePerspective::VeryStrong;
  case static_cast<uint8_t>(BirdsEyePerspective::Maximum):
    return BirdsEyePerspective::Maximum;
  default:
    return BirdsEyePerspective::Standard;
  }
}

inline double birdsEyeTopEdgeScale(BirdsEyePerspective perspective) {
  switch (perspective) {
  case BirdsEyePerspective::Gentle:
    return 0.75;
  case BirdsEyePerspective::Strong:
    return 0.48;
  case BirdsEyePerspective::VeryStrong:
    return 0.36;
  case BirdsEyePerspective::Maximum:
    return 0.24;
  case BirdsEyePerspective::Standard:
  default:
    return 0.60;
  }
}

struct Config {
  uint16_t viewportWidth = 0;
  uint16_t viewportHeight = 0;
  map_transform::WorldPoint worldOrigin{};
  uint8_t zoom = map_transform::kMinimumRuntimeZoom;
  double rotationRad = 0.0;
  double anchorX = 0.0;
  double anchorY = 0.0;
  map_transform::PixelOffset rasterCellOffset{};
  Mode mode = Mode::Flat;
  double topEdgeScale =
      birdsEyeTopEdgeScale(BirdsEyePerspective::Standard);
  double maximumDepthScale = 1.35;
  double nearPlaneMarginPixels = 8.0;
  // Keep the inverse-projected viewport narrower than one 4096-coordinate map
  // block per axis so the existing four-block cache remains sufficient.
  double maximumWorldSpan = 4095.0;
  double worldBoundsMarginPixels = 4.0;
};

struct GroundPoint {
  double lateral = 0.0;
  double forward = 0.0;
};

struct ProjectedPoint {
  double x = 0.0;
  double y = 0.0;
  double depthScale = 1.0;
  bool valid = false;
};

inline double birdsEyeAnchorY(uint16_t viewportHeight) {
  return std::floor((static_cast<double>(viewportHeight) * 56.0) / 100.0);
}

inline double mercatorScaleForLatitude(double latitudeDegrees) {
  constexpr double kMaximumWebMercatorLatitude = 85.05112878;
  constexpr double kDegreesToRadians =
      3.14159265358979323846 / 180.0;
  const double latitude = std::max(
      -kMaximumWebMercatorLatitude,
      std::min(kMaximumWebMercatorLatitude, latitudeDegrees));
  return 1.0 / std::cos(latitude * kDegreesToRadians);
}

class Projection {
public:
  Projection() = default;
  explicit Projection(const Config &config) : config_(config) {
    const auto applyTopScale = [this](double topScale) {
      config_.topEdgeScale = topScale;
      focalDistance_ = config_.anchorY / (1.0 - topScale);
      if (!(focalDistance_ > config_.anchorY)) {
        focalDistance_ = std::max(1.0, config_.viewportHeight * 1.4);
      }
    };
    const double requestedTopScale =
        std::max(0.05, std::min(0.95, config_.topEdgeScale));
    applyTopScale(requestedTopScale);
    if (isBirdsEye() && config_.maximumWorldSpan > 0.0) {
      const auto worldSpanFits = [this]() {
        const auto bounds = worldBounds(config_.worldBoundsMarginPixels);
        return bounds.max.x - bounds.min.x <= config_.maximumWorldSpan &&
               bounds.max.y - bounds.min.y <= config_.maximumWorldSpan;
      };
      if (!worldSpanFits()) {
        double unsafeTopScale = requestedTopScale;
        double safeTopScale = 0.95;
        applyTopScale(safeTopScale);
        for (uint8_t iteration = 0; iteration < 32; ++iteration) {
          const double candidate = (unsafeTopScale + safeTopScale) / 2.0;
          applyTopScale(candidate);
          if (worldSpanFits())
            safeTopScale = candidate;
          else
            unsafeTopScale = candidate;
        }
        applyTopScale(safeTopScale);
      }
    }
    nearPlaneForward_ =
        inverseForward(config_.viewportHeight + config_.nearPlaneMarginPixels);
  }

  const Config &config() const { return config_; }
  Mode mode() const { return config_.mode; }
  bool isBirdsEye() const { return config_.mode == Mode::BirdsEye; }
  double anchorX() const { return config_.anchorX; }
  double anchorY() const { return config_.anchorY; }
  double nearPlaneForward() const { return nearPlaneForward_; }

  GroundPoint groundForWorld(map_transform::WorldPoint world) const {
    const map_transform::ScreenDelta rotated = map_transform::worldToScreen(
        {world.x - config_.worldOrigin.x, world.y - config_.worldOrigin.y},
        config_.zoom, config_.rotationRad);
    return {rotated.x - config_.rasterCellOffset.x,
            -rotated.y + config_.rasterCellOffset.y};
  }

  map_transform::WorldPoint worldForGround(GroundPoint ground) const {
    const map_transform::WorldPoint delta = map_transform::screenToWorld(
        {ground.lateral + config_.rasterCellOffset.x,
         -ground.forward + config_.rasterCellOffset.y},
        config_.zoom, config_.rotationRad);
    return {config_.worldOrigin.x + delta.x,
            config_.worldOrigin.y + delta.y};
  }

  ProjectedPoint projectGround(GroundPoint ground) const {
    if (!isBirdsEye()) {
      return {config_.anchorX + ground.lateral,
              config_.anchorY - ground.forward, 1.0, true};
    }
    if (ground.forward < nearPlaneForward_) {
      return {};
    }
    const double denominator = focalDistance_ + ground.forward;
    if (!(denominator > 0.0)) {
      return {};
    }
    const double depthScale = std::min(
        effectiveMaximumDepthScale(), focalDistance_ / denominator);
    return {config_.anchorX + ground.lateral * depthScale,
            config_.anchorY - ground.forward * depthScale, depthScale, true};
  }

  ProjectedPoint projectElevatedGround(
      GroundPoint ground, double physicalHeightMeters,
      double blockMercatorScale = 1.0) const {
    ProjectedPoint projected = projectGround(ground);
    if (!projected.valid || !(physicalHeightMeters > 0.0))
      return projected;
    const double correctedHeight =
        physicalHeightMeters * std::max(1.0, blockMercatorScale);
    projected.y -= correctedHeight *
                   map_transform::worldToScreenScale(config_.zoom) *
                   projected.depthScale;
    return projected;
  }

  ProjectedPoint projectWorld(map_transform::WorldPoint world) const {
    return projectGround(groundForWorld(world));
  }

  GroundPoint groundForScreen(double screenX, double screenY) const {
    if (!isBirdsEye()) {
      return {screenX - config_.anchorX, config_.anchorY - screenY};
    }
    const double screenForward = config_.anchorY - screenY;
    const double maximumDepthScale = effectiveMaximumDepthScale();
    const double cappedScreenForward =
        focalDistance_ * (1.0 - maximumDepthScale);
    if (screenForward < cappedScreenForward) {
      return {(screenX - config_.anchorX) / maximumDepthScale,
              screenForward / maximumDepthScale};
    }
    const double denominator = focalDistance_ - screenForward;
    if (!(denominator > 0.0)) {
      return {0.0, nearPlaneForward_};
    }
    const double forward = screenForward * focalDistance_ / denominator;
    const double depthScale = focalDistance_ / (focalDistance_ + forward);
    return {(screenX - config_.anchorX) / depthScale, forward};
  }

  bool clipSegmentToNearPlane(GroundPoint &start, GroundPoint &end) const {
    if (!isBirdsEye())
      return true;
    const bool startInside = start.forward >= nearPlaneForward_;
    const bool endInside = end.forward >= nearPlaneForward_;
    if (!startInside && !endInside)
      return false;
    if (startInside && endInside)
      return true;
    const double delta = end.forward - start.forward;
    if (std::fabs(delta) < 1e-12)
      return false;
    const double t = (nearPlaneForward_ - start.forward) / delta;
    const GroundPoint intersection = {
        start.lateral + (end.lateral - start.lateral) * t,
        nearPlaneForward_};
    if (!startInside)
      start = intersection;
    else
      end = intersection;
    return true;
  }

  map_transform::WorldBounds worldBounds(double strokeMarginPixels = 0.0) const {
    const double minX = -strokeMarginPixels;
    const double maxX = config_.viewportWidth + strokeMarginPixels;
    const double minY = -strokeMarginPixels;
    const double maxY = config_.viewportHeight + strokeMarginPixels;
    map_transform::WorldBounds bounds{};
    bool first = true;
    for (const double x : {minX, maxX}) {
      for (const double y : {minY, maxY}) {
        const map_transform::WorldPoint world =
            worldForGround(groundForScreen(x, y));
        if (first) {
          bounds.min = world;
          bounds.max = world;
          first = false;
        } else {
          bounds.min.x = std::min(bounds.min.x, world.x);
          bounds.min.y = std::min(bounds.min.y, world.y);
          bounds.max.x = std::max(bounds.max.x, world.x);
          bounds.max.y = std::max(bounds.max.y, world.y);
        }
      }
    }
    return bounds;
  }

  uint8_t scaledLineWidth(uint8_t baseWidth, double depthScale,
                          uint8_t maximumWidth) const {
    const double effectiveScale = isBirdsEye() ? depthScale : 1.0;
    const int32_t scaled = static_cast<int32_t>(
        std::floor(static_cast<double>(baseWidth) * effectiveScale + 0.5));
    return static_cast<uint8_t>(
        std::max<int32_t>(1, std::min<int32_t>(maximumWidth, scaled)));
  }

private:
  double effectiveMaximumDepthScale() const {
    return std::max(1.0, config_.maximumDepthScale);
  }

  double inverseForward(double screenY) const {
    const double screenForward = config_.anchorY - screenY;
    const double maximumDepthScale = effectiveMaximumDepthScale();
    const double cappedScreenForward =
        focalDistance_ * (1.0 - maximumDepthScale);
    if (screenForward < cappedScreenForward)
      return screenForward / maximumDepthScale;
    const double denominator = focalDistance_ - screenForward;
    return denominator > 0.0
               ? screenForward * focalDistance_ / denominator
               : -focalDistance_;
  }

  Config config_{};
  double focalDistance_ = 1.0;
  double nearPlaneForward_ = -1.0;
};

template <typename InputContainer, typename OutputContainer>
inline void clipPolygonToNearPlane(const Projection &projection,
                                   const InputContainer &input,
                                   OutputContainer &output) {
  output.clear();
  if (input.empty())
    return;
  if (!projection.isBirdsEye()) {
    output = input;
    return;
  }
  const double nearPlane = projection.nearPlaneForward();
  GroundPoint previous = input.back();
  bool previousInside = previous.forward >= nearPlane;
  for (const auto &current : input) {
    const bool currentInside = current.forward >= nearPlane;
    if (currentInside != previousInside) {
      const double delta = current.forward - previous.forward;
      if (std::fabs(delta) > 1e-12) {
        const double t = (nearPlane - previous.forward) / delta;
        output.push_back({
            previous.lateral + (current.lateral - previous.lateral) * t,
            nearPlane});
      }
    }
    if (currentInside)
      output.push_back(current);
    previous = current;
    previousInside = currentInside;
  }
}

} // namespace map_projection
