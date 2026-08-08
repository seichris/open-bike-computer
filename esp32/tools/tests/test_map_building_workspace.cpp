#include "../../lib/maps/src/mapBuildingWorkspace.hpp"

#include <cassert>
#include <cstdint>
#include <vector>

namespace {
struct Point {
  int32_t x;
  int32_t y;
};
}

int main() {
  using map_building_workspace::CourtyardPolicy;
  assert(map_building_workspace::courtyardPolicy(180000, 180000, 658 * 658) ==
         CourtyardPolicy::PreserveUnderlay);
  assert(map_building_workspace::courtyardPolicy(180001, 180000, 658 * 658) ==
         CourtyardPolicy::SolidRoofFallback);
  constexpr int width = 12;
  constexpr int height = 10;
  std::vector<uint16_t> frame(width * height);
  for (size_t index = 0; index < frame.size(); ++index)
    frame[index] = static_cast<uint16_t>(index);
  map_surface::Rgb565Surface surface{frame.data(), width, height, width};
  const std::vector<Point> polygon{{3, 2}, {9, 2}, {9, 7}, {3, 7}};
  const auto region = map_building_workspace::clippedRegion(
      polygon, width, height);
  assert(region.x == 3 && region.y == 2);
  assert(region.width == 7 && region.height == 6);
  assert(region.pixels() < frame.size());

  std::vector<uint16_t> snapshot;
  assert(map_building_workspace::captureRegion(surface, region, snapshot,
                                                region.pixels()));
  for (int y = region.y; y < region.y + region.height; ++y)
    for (int x = region.x; x < region.x + region.width; ++x)
      frame[static_cast<size_t>(y) * width + x] = 0xffff;

  std::vector<int32_t> nodes;
  assert(map_building_workspace::restorePolygon(
      polygon, surface, region, snapshot, nodes, [] { return false; }));
  assert(frame[3 * width + 4] == static_cast<uint16_t>(3 * width + 4));
  assert(frame[1 * width + 4] == static_cast<uint16_t>(1 * width + 4));

  std::vector<uint16_t> rejected;
  assert(!map_building_workspace::captureRegion(surface, region, rejected,
                                                 region.pixels() - 1));
  return 0;
}
