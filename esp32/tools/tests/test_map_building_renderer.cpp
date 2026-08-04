#include "../../lib/maps/src/mapBuildingRenderer.hpp"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <vector>

namespace {

using map_building_renderer::ScreenPoint;
using map_building_renderer::Surface;

struct Command {
  Surface surface;
  std::vector<ScreenPoint> points;
};

map_projection::Projection makeProjection(uint16_t width, uint16_t height,
                                          map_projection::Mode mode) {
  map_projection::Config config;
  config.viewportWidth = width;
  config.viewportHeight = height;
  config.worldOrigin = {100000.0, 200000.0};
  config.zoom = 3;
  config.anchorX = width / 2;
  config.anchorY = mode == map_projection::Mode::BirdsEye
                       ? map_projection::birdsEyeAnchorY(height)
                       : height / 2;
  config.mode = mode;
  return map_projection::Projection(config);
}

map_building_block::Building buildingWithCourtyard() {
  map_building_block::Building building;
  building.heightDm = 120;
  building.minimumHeightDm = 20;
  building.minX = -40;
  building.minY = -40;
  building.maxX = 40;
  building.maxY = 40;

  map_building_block::Ring outer;
  outer.points = {{-40, -40}, {40, -40}, {40, 40}, {-40, 40}};
  outer.walls = {1, 0, 1, 0};
  building.rings.push_back(outer);

  map_building_block::Ring courtyard;
  courtyard.hole = true;
  courtyard.points = {{-12, -12}, {-12, 12}, {12, 12}, {12, -12}};
  courtyard.walls = {0, 0, 0, 0};
  building.rings.push_back(courtyard);
  return building;
}

std::vector<Command> render(const map_building_block::Building &building,
                            uint16_t width, uint16_t height,
                            map_projection::Mode mode,
                            bool extrusionRequested) {
  const auto projection = makeProjection(width, height, mode);
  std::vector<Command> commands;
  const bool completed = map_building_renderer::renderSurfaces(
      building, 100000, 200000, 1.0, projection, extrusionRequested,
      [&](Surface surface, const auto &points) {
        commands.push_back({surface, {points.begin(), points.end()}});
        return true;
      });
  assert(completed);
  return commands;
}

void assertExtrudedCourtyard(uint16_t width, uint16_t height) {
  const auto commands = render(buildingWithCourtyard(), width, height,
                               map_projection::Mode::BirdsEye, true);
  assert(commands.size() == 4);
  assert(commands[0].surface != Surface::Roof &&
         commands[0].surface != Surface::Courtyard);
  assert(commands[1].surface != Surface::Roof &&
         commands[1].surface != Surface::Courtyard);
  assert(commands[2].surface == Surface::Roof);
  assert(commands[3].surface == Surface::Courtyard);
  assert(commands[0].points.size() == 4);
  assert(commands[1].points.size() == 4);
  assert(commands[2].points.size() >= 3);
  assert(commands[3].points.size() >= 3);
}

void assertFlatFallbacks() {
  auto building = buildingWithCourtyard();
  auto commands = render(building, 466, 466, map_projection::Mode::Flat,
                         false);
  assert(commands.size() == 2);
  assert(commands[0].surface == Surface::Roof);
  assert(commands[1].surface == Surface::Courtyard);

  building.flags = map_building_renderer::kBuildingFlagFlatBase;
  commands = render(building, 466, 466, map_projection::Mode::BirdsEye, true);
  assert(commands.size() == 2);
  assert(commands[0].surface == Surface::Roof);
  assert(commands[1].surface == Surface::Courtyard);
}

void assertOrderingAndBudget() {
  using map_building_renderer::OrderKey;
  std::vector<OrderKey> keys = {
      {20.0, 10, 10, 1}, {30.0, 50, 50, 2}, {20.0, 5, 10, 3},
      {20.0, 5, 9, 4},   {20.0, 5, 9, 1},
  };
  std::sort(keys.begin(), keys.end(), map_building_renderer::rendersBefore);
  assert(keys[0].depth == 30.0);
  assert(keys[1].blockY == 9 && keys[1].blockX == 5 &&
         keys[1].recordIndex == 1);
  assert(keys[2].blockY == 9 && keys[2].blockX == 5 &&
         keys[2].recordIndex == 4);
  assert(keys[3].blockY == 10 && keys[3].blockX == 5);
  assert(keys[4].blockY == 10 && keys[4].blockX == 10);

  assert(!map_building_renderer::exceedsExtrusionBudget(1024, 24576));
  assert(map_building_renderer::exceedsExtrusionBudget(1025, 1));
  assert(map_building_renderer::exceedsExtrusionBudget(1, 24577));
}

void assertInterruptionPropagates() {
  const auto building = buildingWithCourtyard();
  const auto projection =
      makeProjection(466, 466, map_projection::Mode::BirdsEye);
  size_t emitted = 0;
  const bool completed = map_building_renderer::renderSurfaces(
      building, 100000, 200000, 1.0, projection, true,
      [&](Surface, const auto &) {
        ++emitted;
        return false;
      });
  assert(!completed);
  assert(emitted == 1);
}

} // namespace

int main() {
  // Native render extents for the 1.75-inch and 2.06-inch layouts.
  assertExtrudedCourtyard(466, 366);
  assertExtrudedCourtyard(410, 430);
  assertFlatFallbacks();
  assertOrderingAndBudget();
  assertInterruptionPropagates();
  return 0;
}
