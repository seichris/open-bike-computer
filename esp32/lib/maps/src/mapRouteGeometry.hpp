/**
 * @file mapRouteGeometry.hpp
 * @brief Pure helpers for anchoring a live route at the presented rider pose.
 */

#pragma once

#include "mapTransform.hpp"

#include <algorithm>
#include <cstddef>
#include <limits>

namespace map_route_geometry {

struct SegmentMatch {
  bool valid = false;
  size_t index = 0;
  double fraction = 0.0;
  map_transform::WorldPoint projected{};
  double distanceSquared = std::numeric_limits<double>::max();
};

template <typename PointAt>
SegmentMatch closestSegment(map_transform::WorldPoint current, size_t count,
                            PointAt pointAt) {
  SegmentMatch best;
  if (count < 2)
    return best;
  for (size_t index = 0; index + 1 < count; ++index) {
    const auto start = pointAt(index);
    const auto end = pointAt(index + 1);
    const double dx = end.x - start.x;
    const double dy = end.y - start.y;
    const double lengthSquared = dx * dx + dy * dy;
    if (!(lengthSquared > 0.0))
      continue;
    const double fraction = std::max(
        0.0, std::min(1.0, ((current.x - start.x) * dx +
                            (current.y - start.y) * dy) /
                               lengthSquared));
    const map_transform::WorldPoint projected = {
        start.x + fraction * dx, start.y + fraction * dy};
    const double offsetX = current.x - projected.x;
    const double offsetY = current.y - projected.y;
    const double distanceSquared = offsetX * offsetX + offsetY * offsetY;
    if (!best.valid || distanceSquared < best.distanceSquared) {
      best = {true, index, fraction, projected, distanceSquared};
    }
  }
  return best;
}

/**
 * Emits a route whose first point is exactly the current presented position,
 * followed by the forward geometry after the nearest segment.  The current
 * point is intentionally not snapped to a stale coarse vertex: it is the same
 * world coordinate used by the marker and presentation transform.
 */
template <typename PointAt, typename Emit>
size_t emitAnchored(map_transform::WorldPoint current, size_t count,
                    PointAt pointAt, Emit emit) {
  const SegmentMatch match = closestSegment(current, count, pointAt);
  if (!match.valid)
    return 0;
  size_t emitted = 0;
  emit(current);
  ++emitted;

  // Keep the live rider attached to the route even when the GPS fix is a
  // little off the polyline (which is common after a coordinate-space
  // conversion or during a fresh fix).  Omitting this point makes the first
  // segment run directly from the off-route rider to the next vertex, which
  // visibly skews the blue line across nearby roads.  The projection is in
  // the same Web-Mercator world space as the route, so inserting it preserves
  // the route's actual direction before continuing with forward vertices.
  constexpr double kProjectionEqualitySquared = 1e-12;
  const double projectionDeltaX = match.projected.x - current.x;
  const double projectionDeltaY = match.projected.y - current.y;
  if (projectionDeltaX * projectionDeltaX +
          projectionDeltaY * projectionDeltaY >
      kProjectionEqualitySquared) {
    emit(match.projected);
    ++emitted;
  }

  for (size_t index = match.index + 1; index < count; ++index) {
    const auto next = pointAt(index);
    const double deltaX = next.x - match.projected.x;
    const double deltaY = next.y - match.projected.y;
    if (deltaX * deltaX + deltaY * deltaY <=
        kProjectionEqualitySquared)
      continue;
    emit(next);
    ++emitted;
  }
  return emitted;
}

} // namespace map_route_geometry
