#pragma once

#include "mapPresentation.hpp"
#include "map_projection.hpp"
#include <cstring>

// Pure policy shared by the worker, presenter and host fixtures. No LVGL,
// storage ownership, dynamic allocation or platform clocks live here.
namespace map_camera {

constexpr uint32_t kRefreshIntervalMs = 100;
constexpr uint32_t kMaximumLagMs = 500;
constexpr double kPositionTolerancePixels = 1.0;
constexpr double kBearingToleranceDegrees = 0.5;

inline uint64_t projectionSignature(const map_projection::Projection &p) {
  uint64_t hash = 1469598103934665603ULL;
  const auto &c = p.config();
  for (double value : {c.worldOrigin.x, c.worldOrigin.y, c.rotationRad,
                       c.anchorX, c.anchorY, c.topEdgeScale,
                       double(c.rasterCellOffset.x), double(c.rasterCellOffset.y),
                       double(c.zoom), double(c.viewportWidth),
                       double(c.viewportHeight), double(c.mode)}) {
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    hash = (hash ^ bits) * 1099511628211ULL;
  }
  return hash;
}

inline double markerAngle(const map_projection::Projection &projection,
                          map_transform::WorldPoint rider, double heading) {
  const double radians = heading * map_presentation::kPi / 180.0;
  const auto start = projection.projectWorld(rider);
  const auto end = projection.projectWorld(
      {rider.x + std::sin(radians), rider.y + std::cos(radians)});
  if (!start.valid || !end.valid)
    return map_presentation::markerRotationDegrees(
        heading, projection.config().rotationRad);
  return map_presentation::normalizeDegrees(
      std::atan2(end.x - start.x, start.y - end.y) *
      180.0 / map_presentation::kPi);
}

struct LabelSegment {
  double x = 0, y = 0, angle = 0, length = 0;
  bool valid = false;
};

inline LabelSegment projectLabel(const map_projection::Projection &projection,
                                 map_transform::WorldPoint start,
                                 map_transform::WorldPoint end,
                                 bool followRoads) {
  auto a = projection.groundForWorld(start);
  auto b = projection.groundForWorld(end);
  if (!projection.clipSegmentToNearPlane(a, b))
    return {};
  const auto p = projection.projectGround(a);
  const auto q = projection.projectGround(b);
  if (!p.valid || !q.valid)
    return {};
  const double dx = q.x - p.x, dy = q.y - p.y;
  const double length = std::hypot(dx, dy);
  if (!std::isfinite(length) || length < 1e-6)
    return {};
  double angle = followRoads ? std::atan2(dy, dx) : 0.0;
  if (angle > map_presentation::kPi / 2.0)
    angle -= map_presentation::kPi;
  else if (angle < -map_presentation::kPi / 2.0)
    angle += map_presentation::kPi;
  return {(p.x + q.x) / 2.0, (p.y + q.y) / 2.0, angle, length, true};
}

// The accepted raster is only cropped, never transformed. Prove the physical
// crop, including the round panel's area outside a shorter toolbar viewport.
inline bool cropCovered(uint16_t renderWidth, uint16_t renderHeight,
                        uint16_t width, uint16_t height, uint16_t gutter,
                        uint16_t safety, bool round) {
  return map_presentation::frameCoversViewport(
      renderWidth, renderHeight, width, height,
      {gutter + width / 2.0, gutter + height / 2.0},
      {width / 2.0, height / 2.0}, 0.0, safety, round);
}

inline bool needsRefresh(const map_projection::Projection &camera,
                         map_transform::WorldPoint target,
                         double bearingRad) {
  const auto p = camera.projectWorld(target);
  return !p.valid ||
         std::hypot(p.x - camera.anchorX(), p.y - camera.anchorY()) >=
             kPositionTolerancePixels ||
         std::fabs(map_presentation::signedHeadingDelta(
             camera.config().rotationRad * 180.0 / map_presentation::kPi,
             bearingRad * 180.0 / map_presentation::kPi)) >=
             kBearingToleranceDegrees;
}

// A single worker owns the actual decoded blocks. This descriptor is a lease
// over that worker's current complete rectangular block set, not a second
// geometry cache. It is invalidated BEFORE any loader/evictor mutates the set.
struct PreparedScene {
  int32_t minX = 0, minY = 0, maxX = 0, maxY = 0;
  uint32_t mapEpoch = 0, generation = 0;
  bool valid = false;

  bool covers(uint32_t epoch, int32_t x0, int32_t y0,
              int32_t x1, int32_t y1) const {
    return valid && epoch == mapEpoch && x0 >= minX && y0 >= minY &&
           x1 <= maxX && y1 <= maxY;
  }
  void invalidate() { valid = false; }
  void prepared(uint32_t epoch, int32_t x0, int32_t y0,
                int32_t x1, int32_t y1) {
    mapEpoch = epoch;
    minX = x0; minY = y0; maxX = x1; maxY = y1;
    ++generation;
    valid = true;
  }
};
static_assert(sizeof(PreparedScene) <= 32, "scene metadata must remain bounded");

class Lag {
public:
  void observe(bool required, uint32_t nowMs) {
    if (!required) { pending_ = false; return; }
    if (!pending_) { since_ = nowMs; pending_ = true; }
  }
  void reflected(uint32_t requestMs) {
    if (pending_ && static_cast<int32_t>(requestMs - since_) > 0)
      since_ = requestMs;
  }
  uint32_t age(uint32_t nowMs) const { return pending_ ? nowMs - since_ : 0; }
  bool expired(uint32_t nowMs) const { return age(nowMs) > kMaximumLagMs; }
private:
  uint32_t since_ = 0;
  bool pending_ = false;
};

} // namespace map_camera
