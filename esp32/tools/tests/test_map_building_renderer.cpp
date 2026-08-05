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

bool isWall(Surface surface) {
  return surface == Surface::WallLight ||
         surface == Surface::WallMiddle || surface == Surface::WallDark;
}

bool samePoint(const ScreenPoint &left, const ScreenPoint &right) {
  return left.x == right.x && left.y == right.y;
}

bool samePoints(const std::vector<ScreenPoint> &left,
                const std::vector<ScreenPoint> &right) {
  return left.size() == right.size() &&
         std::equal(left.begin(), left.end(), right.begin(), samePoint);
}

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
                            bool extrusionRequested,
                            double blockMercatorScale = 1.0) {
  const auto projection = makeProjection(width, height, mode);
  std::vector<Command> commands;
  const bool completed = map_building_renderer::renderSurfaces(
      building, 100000, 200000, blockMercatorScale, projection,
      extrusionRequested,
      [&](Surface surface, const auto &points) {
        commands.push_back({surface, {points.begin(), points.end()}});
        return true;
      });
  assert(completed);
  return commands;
}

void assertOSMHeightsChangeProjectedSurfaces() {
  const auto building = buildingWithCourtyard();
  const auto original = render(building, 466, 366,
                               map_projection::Mode::BirdsEye, true);

  auto groundLevel = building;
  groundLevel.minimumHeightDm = 0;
  const auto groundLevelCommands = render(
      groundLevel, 466, 366, map_projection::Mode::BirdsEye, true);
  assert(!samePoint(original[0].points[0], groundLevelCommands[0].points[0]));
  assert(samePoint(original[0].points[2], groundLevelCommands[0].points[2]));

  auto lowerRoof = building;
  lowerRoof.heightDm = 60;
  const auto lowerRoofCommands = render(
      lowerRoof, 466, 366, map_projection::Mode::BirdsEye, true);
  assert(samePoint(original[0].points[0], lowerRoofCommands[0].points[0]));
  assert(!samePoint(original[0].points[2], lowerRoofCommands[0].points[2]));
  assert(original[3].surface == Surface::Roof);
  assert(lowerRoofCommands[3].surface == Surface::Roof);
  assert(!samePoints(original[3].points, lowerRoofCommands[3].points));

  const auto scaled = render(building, 466, 366,
                             map_projection::Mode::BirdsEye, true, 2.0);
  assert(!samePoint(original[0].points[0], scaled[0].points[0]));
  assert(!samePoint(original[0].points[2], scaled[0].points[2]));
  assert(!samePoints(original[3].points, scaled[3].points));
}

void assertExtrudedCourtyard(uint16_t width, uint16_t height) {
  const auto commands = render(buildingWithCourtyard(), width, height,
                               map_projection::Mode::BirdsEye, true);
  assert(commands.size() == 5);
  assert(isWall(commands[0].surface));
  assert(isWall(commands[1].surface));
  assert(commands[2].surface == Surface::CourtyardCapture);
  assert(commands[3].surface == Surface::Roof);
  assert(commands[4].surface == Surface::Courtyard);
  assert(commands[0].points.size() == 4);
  assert(commands[1].points.size() == 4);
  assert(commands[2].points.size() >= 3);
  assert(commands[3].points.size() >= 3);
  assert(commands[4].points.size() >= 3);
}

void assertFlatFallbacks() {
  auto building = buildingWithCourtyard();
  auto commands = render(building, 466, 466, map_projection::Mode::Flat,
                         false);
  assert(commands.size() == 3);
  assert(commands[0].surface == Surface::CourtyardCapture);
  assert(commands[1].surface == Surface::Roof);
  assert(commands[2].surface == Surface::Courtyard);

  building.flags = map_building_renderer::kBuildingFlagFlatBase;
  commands = render(building, 466, 466, map_projection::Mode::BirdsEye, true);
  assert(commands.size() == 3);
  assert(commands[0].surface == Surface::CourtyardCapture);
  assert(commands[1].surface == Surface::Roof);
  assert(commands[2].surface == Surface::Courtyard);
}

void assertOrderingAndBudget() {
  using map_building_renderer::OrderKey;
  using Admission = map_building_renderer::ExtrusionBudget::Admission;
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
  assert(budget.reserve(0, 12) == Admission::Selected);
  assert(budget.records == 1 && budget.points == 12);
  assert(budget.reserve(map_building_renderer::kBuildingFlagFlatBase, 12) ==
         Admission::IneligibleFlatBase);
  assert(budget.records == 1 && budget.points == 12);
  assert(budget.reserve(
             0, map_building_renderer::kMaximumExtrudedBuildingPoints) ==
         Admission::PointLimit);
  assert(!map_building_renderer::eligibleExtrusionZoom(0));
  assert(map_building_renderer::eligibleExtrusionZoom(1));
  assert(map_building_renderer::eligibleExtrusionZoom(4));
  assert(!map_building_renderer::eligibleExtrusionZoom(5));

  map_building_renderer::ExtrusionBudget recordBudget;
  for (size_t index = 0;
       index < map_building_renderer::kMaximumExtrudedBuildingRecords;
       ++index) {
    assert(recordBudget.reserve(0, 1) == Admission::Selected);
  }
  assert(recordBudget.reserve(0, 1) == Admission::RecordLimit);

  struct Candidate {
    OrderKey key;
    size_t pointCount;
    bool render = true;
    bool extrude = false;

    uint8_t buildingFlags() const { return 0; }
    bool eligibleForExtrusion() const { return true; }
  };
  std::vector<Candidate> dense = {
      {{40.0, 0, 0, 0}, 8192, true, false},
      {{30.0, 0, 0, 1}, 8192, true, false},
      {{20.0, 0, 0, 2}, 8192, true, false},
      {{10.0, 0, 0, 3}, 8192, true, false},
  };
  std::sort(dense.begin(), dense.end(), [](const Candidate &left,
                                            const Candidate &right) {
    return map_building_renderer::rendersBefore(left.key, right.key);
  });
  const auto selection = map_building_renderer::selectNearestForExtrusion(
      dense.rbegin(), dense.rend());
  assert(!dense[0].extrude);
  assert(dense[1].extrude && dense[2].extrude && dense[3].extrude);
  assert(selection.eligibleRecords == 4);
  assert(selection.selectedRecords == 3);
  assert(selection.selectedPoints ==
         map_building_renderer::kMaximumExtrudedBuildingPoints);
  assert(selection.flatOverflow() == 1);
  assert(selection.recordLimitOverflow == 0);
  assert(selection.pointLimitOverflow == 1);

  std::vector<Candidate> recordDense;
  recordDense.reserve(
      map_building_renderer::kMaximumExtrudedBuildingRecords + 2);
  for (size_t index = 0;
       index < map_building_renderer::kMaximumExtrudedBuildingRecords + 2;
       ++index) {
    recordDense.push_back(
        {{static_cast<double>(index), 0, 0,
          static_cast<uint16_t>(index)},
         1, true, false});
  }
  const auto recordSelection =
      map_building_renderer::selectNearestForExtrusion(
          recordDense.rbegin(), recordDense.rend());
  assert(recordSelection.selectedRecords ==
         map_building_renderer::kMaximumExtrudedBuildingRecords);
  assert(recordSelection.recordLimitOverflow == 2);
  assert(recordSelection.pointLimitOverflow == 0);

  std::vector<Candidate> renderDense = {
      {{40.0, 0, 0, 0}, 16384, true, false},
      {{30.0, 0, 0, 1}, 16384, true, false},
      {{20.0, 0, 0, 2}, 16384, true, false},
      {{10.0, 0, 0, 3}, 16384, true, false},
  };
  const auto renderSelection =
      map_building_renderer::selectNearestForRendering(
          renderDense.rbegin(), renderDense.rend());
  assert(!renderDense[0].render);
  assert(renderDense[1].render && renderDense[2].render &&
         renderDense[3].render);
  assert(renderSelection.selectedRecords == 3);
  assert(renderSelection.selectedPoints ==
         map_building_renderer::kMaximumRenderedBuildingPoints);
  assert(renderSelection.pointLimitOverflow == 1);

  std::vector<Candidate> retained;
  for (const auto &candidate :
       {Candidate{{50.0, 0, 0, 0}, 1, true, false},
        Candidate{{10.0, 0, 0, 1}, 1, true, false},
        Candidate{{40.0, 0, 0, 2}, 1, true, false},
        Candidate{{20.0, 0, 0, 3}, 1, true, false},
        Candidate{{30.0, 0, 0, 4}, 1, true, false}}) {
    map_building_renderer::retainNearestCandidate(
        retained, candidate, 3,
        [](const Candidate &left, const Candidate &right) {
          return map_building_renderer::rendersBefore(left.key, right.key);
        });
  }
  std::sort(retained.begin(), retained.end(),
            [](const Candidate &left, const Candidate &right) {
              return map_building_renderer::rendersBefore(left.key, right.key);
            });
  assert(retained.size() == 3);
  assert(retained[0].key.depth == 30.0);
  assert(retained[1].key.depth == 20.0);
  assert(retained[2].key.depth == 10.0);
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
       {map_projection::GroundPoint{-45.0, near - 105.0},
        map_projection::GroundPoint{45.0, near - 105.0},
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
  for (const auto &[width, height] :
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
          const map_transform::WorldPoint center{
              100000.0 +
                  (static_cast<double>(building.minX) + building.maxX) / 2.0,
              200000.0 +
                  (static_cast<double>(building.minY) + building.maxY) / 2.0};
          assert(!projection.projectGround(projection.groundForWorld(center))
                      .valid);
          std::vector<map_projection::GroundPoint> ground;
          std::vector<map_projection::GroundPoint> clipped;
          const double projectedArea =
              map_building_renderer::projectedFootprintAreaPixels(
                  building, 100000, 200000, projection, ground, clipped);
          assert(projectedArea >= map_building_renderer::
                                      kMinimumBuildingExtrusionAreaPixels);
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
          const auto wallCount = std::count_if(
              commands.begin(), commands.end(),
              [](const Command &command) { return isWall(command.surface); });
          // One rear wall is wholly behind the near plane. Both crossing side
          // walls and the ordinary front wall must survive.
          assert(wallCount == 3);
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

void assertCourtyardRestoresRealUnderlay() {
  constexpr int32_t width = 8;
  constexpr int32_t height = 8;
  std::vector<uint16_t> underlay(width * height);
  for (size_t index = 0; index < underlay.size(); ++index)
    underlay[index] = static_cast<uint16_t>(index + 1);
  std::vector<uint16_t> canvas(width * height, 0xFFFF);
  const std::vector<ScreenPoint> courtyard = {
      {2, 2}, {6, 2}, {6, 6}, {2, 6},
  };
  std::vector<int32_t> nodes(courtyard.size());
  const bool restored = map_building_renderer::restoreCourtyardUnderlay(
      courtyard, canvas.data(), width, height, width, underlay.data(),
      underlay.size(), nodes, []() { return false; });
  assert(restored);
  assert(canvas[3 * width + 3] == underlay[3 * width + 3]);
  assert(canvas[5 * width + 5] == underlay[5 * width + 5]);
  assert(canvas[0] == 0xFFFF);
  assert(canvas[7 * width + 7] == 0xFFFF);
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

  size_t deadlineChecks = 0;
  const bool deadlineCompleted = map_building_renderer::renderSurfaces(
      building, 100000, 200000, 1.0, projection, true,
      [](Surface, const auto &) { return true; }, nullptr,
      [&]() { return ++deadlineChecks >= 2; });
  assert(!deadlineCompleted);
  assert(deadlineChecks >= 2);
}

void assertAllocationFailureFailsClosed() {
  bool allocationFailureObserved = false;
  const bool completed = map_building_renderer::runAllocationSafe(
      []() -> bool { throw std::bad_alloc(); },
      [&]() { allocationFailureObserved = true; });
  assert(!completed);
  assert(allocationFailureObserved);

  allocationFailureObserved = false;
  const bool successful = map_building_renderer::runAllocationSafe(
      []() { return true; }, [&]() { allocationFailureObserved = true; });
  assert(successful);
  assert(!allocationFailureObserved);

  assert(map_building_renderer::shouldRetryWithoutBuildings(false, true, false,
                                                             false));
  assert(map_building_renderer::shouldRetryWithoutBuildings(false, false, true,
                                                             false));
  assert(!map_building_renderer::shouldRetryWithoutBuildings(true, true, false,
                                                              false));
  assert(!map_building_renderer::shouldRetryWithoutBuildings(false, true, false,
                                                              true));
  assert(!map_building_renderer::shouldRetryWithoutBuildings(
      false, false, false, false));
}

void assertFailureRetryCooldown() {
  map_building_renderer::FailureRetryCooldown cooldown;
  constexpr uint64_t denseContext = 0x1234ULL;
  constexpr uint64_t changedContext = 0x5678ULL;
  constexpr map_building_renderer::RenderRegion denseRegion{0, 0, 100, 100};
  constexpr map_building_renderer::RenderRegion nearbyRegion{8, 0, 108, 100};
  constexpr map_building_renderer::RenderRegion disjointRegion{200, 0, 300,
                                                                100};

  assert(!cooldown.shouldSuppress(1000, denseContext, denseRegion));
  cooldown.recordFailure(1000, denseContext, denseRegion);
  assert(cooldown.shouldSuppress(1000, denseContext, denseRegion));
  assert(cooldown.shouldSuppress(1008, denseContext, nearbyRegion));
  assert(cooldown.shouldSuppress(
      1000 + map_building_renderer::kBuildingFailureRetryCooldownMs - 1,
      denseContext, denseRegion));
  assert(!cooldown.shouldSuppress(
      1000 + map_building_renderer::kBuildingFailureRetryCooldownMs,
      denseContext, denseRegion));

  cooldown.recordFailure(UINT32_MAX - 10U, denseContext, denseRegion);
  assert(cooldown.shouldSuppress(5, denseContext, denseRegion));
  assert(!cooldown.shouldSuppress(5, changedContext, denseRegion));
  assert(!cooldown.shouldSuppress(6, denseContext, denseRegion));

  cooldown.recordFailure(2000, denseContext, denseRegion);
  assert(!cooldown.shouldSuppress(2001, denseContext, disjointRegion));
  assert(!cooldown.shouldSuppress(2002, denseContext, denseRegion));
}

} // namespace

int main() {
  // Native render extents for the 1.75-inch and 2.06-inch layouts.
  assertExtrudedCourtyard(466, 366);
  assertExtrudedCourtyard(410, 430);
  assertOSMHeightsChangeProjectedSurfaces();
  assertFlatFallbacks();
  assertOrderingAndBudget();
  assertNearPlaneMatrix();
  assertCourtyardRestoresRealUnderlay();
  assertInterruptionPropagates();
  assertAllocationFailureFailsClosed();
  assertFailureRetryCooldown();
  return 0;
}
