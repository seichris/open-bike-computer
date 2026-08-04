/**
 * @file mapBuildingRenderer.hpp
 * @brief Host-testable building surface composition for flat and bird's-eye maps.
 */

#pragma once

#include "mapBuildingBlock.hpp"
#include "map_projection.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>

namespace map_building_renderer {

constexpr uint8_t kBuildingFlagFlatBase = 1U << 1U;
constexpr size_t kMaximumExtrudedBuildingRecords = 1024;
constexpr size_t kMaximumExtrudedBuildingPoints = 24576;

struct OrderKey {
  double depth = 0.0;
  int32_t blockX = 0;
  int32_t blockY = 0;
  uint16_t recordIndex = 0;
};

inline bool rendersBefore(const OrderKey &left, const OrderKey &right) {
  if (left.depth != right.depth)
    return left.depth > right.depth;
  if (left.blockY != right.blockY)
    return left.blockY < right.blockY;
  if (left.blockX != right.blockX)
    return left.blockX < right.blockX;
  return left.recordIndex < right.recordIndex;
}

constexpr bool usesExtrusion(bool requested, uint8_t buildingFlags) {
  return requested && (buildingFlags & kBuildingFlagFlatBase) == 0;
}

// Dense scenes are expected to contain more roofs than can be safely
// extruded in one frame. Reserve the bounded wall/roof workspace per eligible
// record so callers can keep the nearest buildings extruded while drawing
// overflow records as flat roofs. Flat-base outlines never consume the
// extrusion budget.
struct ExtrusionBudget {
  size_t records = 0;
  size_t points = 0;

  constexpr bool reserve(uint8_t buildingFlags, size_t pointCount) {
    if (!usesExtrusion(true, buildingFlags) ||
        records >= kMaximumExtrudedBuildingRecords ||
        pointCount > kMaximumExtrudedBuildingPoints - points) {
      return false;
    }
    ++records;
    points += pointCount;
    return true;
  }
};

enum class Surface : uint8_t {
  WallLight,
  WallMiddle,
  WallDark,
  Roof,
  Courtyard,
};

inline Surface wallSurfaceForEdge(double edgeX, double edgeY) {
  if (std::fabs(edgeX) <= std::fabs(edgeY))
    return Surface::WallMiddle;
  return edgeX > 0.0 ? Surface::WallLight : Surface::WallDark;
}

struct ScreenPoint {
  int32_t x = 0;
  int32_t y = 0;
};

// Emits walls first, then roof/courtyard rings. The callback returns false to
// interrupt rendering, matching the firmware polygon-fill contract.
template <typename DrawSurface>
bool renderSurfaces(const map_building_block::Building &building,
                    int32_t blockOffsetX, int32_t blockOffsetY,
                    double blockMercatorScale,
                    const map_projection::Projection &projection,
                    bool extrusionRequested, DrawSurface &&drawSurface) {
  const bool extrude = usesExtrusion(extrusionRequested, building.flags);
  const double minimumHeight =
      extrude ? building.minimumHeightDm / 10.0 : 0.0;
  const double height = extrude ? building.heightDm / 10.0 : 0.0;
  MapBuildingVector<ScreenPoint> screenRing;

  if (extrude) {
    for (const auto &ring : building.rings) {
      for (size_t index = 0; index < ring.points.size(); ++index) {
        if (index >= ring.walls.size() || ring.walls[index] == 0)
          continue;
        const auto &start = ring.points[index];
        const auto &end = ring.points[(index + 1U) % ring.points.size()];
        auto startGround = projection.groundForWorld(
            {static_cast<double>(blockOffsetX + start.x),
             static_cast<double>(blockOffsetY + start.y)});
        auto endGround = projection.groundForWorld(
            {static_cast<double>(blockOffsetX + end.x),
             static_cast<double>(blockOffsetY + end.y)});
        if (!projection.clipSegmentToNearPlane(startGround, endGround))
          continue;
        const auto startBase = projection.projectElevatedGround(
            startGround, minimumHeight, blockMercatorScale);
        const auto endBase = projection.projectElevatedGround(
            endGround, minimumHeight, blockMercatorScale);
        const auto endTop = projection.projectElevatedGround(
            endGround, height, blockMercatorScale);
        const auto startTop = projection.projectElevatedGround(
            startGround, height, blockMercatorScale);
        if (!startBase.valid || !endBase.valid || !endTop.valid ||
            !startTop.valid)
          continue;
        screenRing = {
            {map_transform::quantizePixel(startBase.x),
             map_transform::quantizePixel(startBase.y)},
            {map_transform::quantizePixel(endBase.x),
             map_transform::quantizePixel(endBase.y)},
            {map_transform::quantizePixel(endTop.x),
             map_transform::quantizePixel(endTop.y)},
            {map_transform::quantizePixel(startTop.x),
             map_transform::quantizePixel(startTop.y)},
        };
        if (!drawSurface(
                wallSurfaceForEdge(endBase.x - startBase.x,
                                   endBase.y - startBase.y),
                screenRing))
          return false;
      }
    }
  }

  MapBuildingVector<map_projection::GroundPoint> ground;
  MapBuildingVector<map_projection::GroundPoint> clipped;
  for (const auto &ring : building.rings) {
    ground.clear();
    ground.reserve(ring.points.size());
    for (const auto &point : ring.points)
      ground.push_back(projection.groundForWorld(
          {static_cast<double>(blockOffsetX + point.x),
           static_cast<double>(blockOffsetY + point.y)}));
    const auto *roof = &ground;
    if (projection.isBirdsEye()) {
      map_projection::clipPolygonToNearPlane(projection, ground, clipped);
      roof = &clipped;
    }
    screenRing.clear();
    for (const auto &point : *roof) {
      const auto projected = projection.projectElevatedGround(
          point, height, blockMercatorScale);
      if (projected.valid)
        screenRing.push_back({map_transform::quantizePixel(projected.x),
                              map_transform::quantizePixel(projected.y)});
    }
    if (!drawSurface(ring.hole ? Surface::Courtyard : Surface::Roof,
                     screenRing))
      return false;
  }
  return true;
}

} // namespace map_building_renderer
