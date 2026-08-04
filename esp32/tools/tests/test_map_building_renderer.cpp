#include "../../lib/maps/src/mapBuildingRenderer.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <utility>
#include <vector>

namespace {

using map_building_renderer::ScreenPoint;
using map_building_renderer::Surface;

struct Command {
  Surface surface;
  std::vector<ScreenPoint> points;
};

map_projection::Projection makeProjection(uint16_t width, uint16_t height,
                                          map_projection::Mode mode,
                                          uint8_t zoom = 3,
                                          double rotationRad = 0.0,
                                          map_projection::BirdsEyePerspective
                                              perspective =
                                                  map_projection::
                                                      BirdsEyePerspective::
                                                          Standard) {
  map_projection::Config config;
  config.viewportWidth = width;
  config.viewportHeight = height;
  config.worldOrigin = {100000.0, 200000.0};
  config.zoom = zoom;
  config.rotationRad = rotationRad;
  config.anchorX = width / 2;
  config.anchorY = mode == map_projection::Mode::BirdsEye
                       ? map_projection::birdsEyeAnchorY(height)
                       : height / 2;
  config.mode = mode;
  config.topEdgeScale = map_projection::birdsEyeTopEdgeScale(perspective);
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

  map_building_renderer::ExtrusionBudget budget;
  assert(budget.reserve(0, 12));
  assert(budget.records == 1 && budget.points == 12);
  assert(!budget.reserve(map_building_renderer::kBuildingFlagFlatBase, 12));
  assert(budget.records == 1 && budget.points == 12);
  assert(!budget.reserve(
      0, map_building_renderer::kMaximumExtrudedBuildingPoints));

  map_building_renderer::ExtrusionBudget recordBudget;
  for (size_t index = 0;
       index < map_building_renderer::kMaximumExtrudedBuildingRecords;
       ++index) {
    assert(recordBudget.reserve(0, 1));
  }
  assert(!recordBudget.reserve(0, 1));

  struct Candidate {
    OrderKey key;
    size_t points;
    bool selected = false;
  };
  std::vector<Candidate> dense = {
      {{40.0, 0, 0, 0}, 8192, false},
      {{30.0, 0, 0, 1}, 8192, false},
      {{20.0, 0, 0, 2}, 8192, false},
      {{10.0, 0, 0, 3}, 8192, false},
  };
  std::sort(dense.begin(), dense.end(), [](const Candidate &left,
                                            const Candidate &right) {
    return map_building_renderer::rendersBefore(left.key, right.key);
  });
  map_building_renderer::ExtrusionBudget denseBudget;
  for (auto item = dense.rbegin(); item != dense.rend(); ++item)
    item->selected = denseBudget.reserve(0, item->points);
  assert(!dense[0].selected);
  assert(dense[1].selected && dense[2].selected && dense[3].selected);
  assert(denseBudget.records == 3);
  assert(denseBudget.points ==
         map_building_renderer::kMaximumExtrudedBuildingPoints);
}

map_building_block::Building buildingCrossingNearPlane(
    const map_projection::Projection &projection, int32_t blockX,
    int32_t blockY) {
  map_building_block::Building building;
  building.heightDm = 300;
  building.minimumHeightDm = 30;
  map_building_block::Ring ring;
  const double near = projection.nearPlaneForward();
  for (const auto &ground :
       {map_projection::GroundPoint{-45.0, near - 30.0},
        map_projection::GroundPoint{45.0, near - 30.0},
        map_projection::GroundPoint{45.0, near + 45.0},
        map_projection::GroundPoint{-45.0, near + 45.0}}) {
    const auto world = projection.worldForGround(ground);
    ring.points.push_back(
        {static_cast<int16_t>(
             map_transform::quantizePixel(world.x - blockX)),
         static_cast<int16_t>(
             map_transform::quantizePixel(world.y - blockY))});
  }
  ring.walls = {1, 1, 1, 1};
  building.rings.push_back(ring);
  building.minX = building.maxX = ring.points.front().x;
  building.minY = building.maxY = ring.points.front().y;
  for (const auto &point : ring.points) {
    building.minX = std::min(building.minX, point.x);
    building.minY = std::min(building.minY, point.y);
    building.maxX = std::max(building.maxX, point.x);
    building.maxY = std::max(building.maxY, point.y);
  }
  return building;
}

void assertNearPlaneMatrix() {
  constexpr double pi = 3.14159265358979323846;
  const map_projection::BirdsEyePerspective perspectives[] = {
      map_projection::BirdsEyePerspective::Gentle,
      map_projection::BirdsEyePerspective::Standard,
      map_projection::BirdsEyePerspective::Strong,
      map_projection::BirdsEyePerspective::VeryStrong,
      map_projection::BirdsEyePerspective::Maximum,
  };
  for (const auto [width, height] :
       {std::pair<uint16_t, uint16_t>{466, 366}, {410, 430}}) {
    for (uint8_t zoom = map_transform::kMinimumRuntimeZoom;
         zoom <= map_transform::kMaximumRuntimeZoom; ++zoom) {
      for (double heading : {0.0, pi / 4.0, pi / 2.0, pi, 3.0 * pi / 2.0}) {
        for (const auto perspective : perspectives) {
          const auto projection = makeProjection(
              width, height, map_projection::Mode::BirdsEye, zoom, heading,
              perspective);
          const auto building =
              buildingCrossingNearPlane(projection, 100000, 200000);
          std::vector<Command> commands;
          const bool completed = map_building_renderer::renderSurfaces(
              building, 100000, 200000, 1.0, projection, true,
              [&](Surface surface, const auto &points) {
                commands.push_back({surface, {points.begin(), points.end()}});
                return true;
              });
          assert(completed);
          assert(!commands.empty());
          assert(std::any_of(commands.begin(), commands.end(),
                             [](const Command &command) {
                               return command.surface == Surface::Roof;
                             }));
          assert(std::any_of(commands.begin(), commands.end(),
                             [](const Command &command) {
                               return command.surface != Surface::Roof &&
                                      command.surface != Surface::Courtyard;
                             }));
          for (const auto &command : commands) {
            assert(command.points.size() >= 3);
            for (const auto &point : command.points) {
              assert(std::abs(point.x) <= static_cast<int32_t>(width) * 8);
              assert(std::abs(point.y) <= static_cast<int32_t>(height) * 8);
            }
          }
        }
      }
    }
  }
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
  assertNearPlaneMatrix();
  assertInterruptionPropagates();
  return 0;
}
