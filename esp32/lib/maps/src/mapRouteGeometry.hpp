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
  for (size_t index = match.index + 1; index < count; ++index) {
    const auto next = pointAt(index);
    if (next.x == current.x && next.y == current.y)
      continue;
    emit(next);
    ++emitted;
  }
  return emitted;
}

} // namespace map_route_geometry
