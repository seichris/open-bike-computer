#include "../../lib/maps/src/mapRouteGeometry.hpp"

#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>

int main() {
  using map_transform::WorldPoint;
  const std::vector<WorldPoint> route = {
      {0.0, 0.0}, {10.0, 0.0}, {20.0, 0.0}, {30.0, 10.0}};
  const WorldPoint current{15.0, 2.0};
  const auto match = map_route_geometry::closestSegment(
      current, route.size(), [&](size_t index) { return route[index]; });
  assert(match.valid);
  assert(match.index == 1);
  assert(std::fabs(match.fraction - 0.5) < 1e-9);
  assert(std::fabs(match.projected.x - 15.0) < 1e-9);
  assert(std::fabs(match.projected.y) < 1e-9);

  std::vector<WorldPoint> anchored;
  const size_t emitted = map_route_geometry::emitAnchored(
      current, route.size(), [&](size_t index) { return route[index]; },
      [&](WorldPoint point) { anchored.push_back(point); });
  assert(emitted == 3);
  assert(anchored.front().x == current.x && anchored.front().y == current.y);
  assert(anchored[1].x == 20.0 && anchored[1].y == 0.0);
  assert(anchored[2].x == 30.0 && anchored[2].y == 10.0);

  assert(!map_route_geometry::closestSegment(
              current, 1, [&](size_t index) { return route[index]; })
              .valid);
  std::cout << "map route geometry tests passed\n";
  return 0;
}
