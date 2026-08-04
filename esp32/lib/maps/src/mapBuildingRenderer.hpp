/**
 * @file mapBuildingRenderer.hpp
 * @brief Host-testable building surface composition for flat and bird's-eye maps.
 */

#pragma once

#include "mapBuildingBlock.hpp"
#include "map_projection.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace map_building_renderer {

constexpr uint8_t kBuildingFlagFlatBase = 1U << 1U;
constexpr size_t kMaximumExtrudedBuildingRecords = 1024;
constexpr size_t kMaximumExtrudedBuildingPoints = 24576;
constexpr size_t kMaximumRenderedBuildingRecords = 6144;
constexpr size_t kMaximumRenderedBuildingPoints = 49152;
constexpr size_t kMaximumRenderedBuildingPointsPerRecord = 1024;
constexpr uint8_t kMaximumBuildingExtrusionZoom = 4;
constexpr double kMinimumBuildingExtrusionAreaPixels = 6.0;
constexpr uint32_t kMaximumBuildingRenderTimeMs = 10000;

struct NeverStop {
  constexpr bool operator()() const { return false; }
};

constexpr bool eligibleExtrusionZoom(uint8_t zoom) {
  return zoom >= map_transform::kMinimumRuntimeZoom &&
         zoom <= kMaximumBuildingExtrusionZoom;
}

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

  enum class Admission : uint8_t {
    Selected,
    IneligibleFlatBase,
    RecordLimit,
    PointLimit,
  };

  constexpr Admission reserve(uint8_t buildingFlags, size_t pointCount) {
    if (!usesExtrusion(true, buildingFlags))
      return Admission::IneligibleFlatBase;
    if (records >= kMaximumExtrudedBuildingRecords)
      return Admission::RecordLimit;
    if (pointCount > kMaximumExtrudedBuildingPoints - points)
      return Admission::PointLimit;
    ++records;
    points += pointCount;
    return Admission::Selected;
  }
};

struct ExtrusionSelection {
  size_t eligibleRecords = 0;
  size_t selectedRecords = 0;
  size_t selectedPoints = 0;
  size_t recordLimitOverflow = 0;
  size_t pointLimitOverflow = 0;

  constexpr size_t flatOverflow() const {
    return recordLimitOverflow + pointLimitOverflow;
  }

  constexpr bool usedFallback() const { return flatOverflow() != 0; }
};

// Candidates must already be in reverse painter order (nearest-to-farthest).
// The candidate contract is intentionally tiny so this exact production
// admission path stays host-testable: render, pointCount, extrude,
// buildingFlags(), and eligibleForExtrusion().
template <typename ReverseIterator, typename ShouldStop = NeverStop>
ExtrusionSelection selectNearestForExtrusion(ReverseIterator nearest,
                                             ReverseIterator farthest,
                                             ShouldStop shouldStop = {}) {
  ExtrusionBudget budget;
  ExtrusionSelection selection;
  for (auto item = nearest; item != farthest; ++item) {
    if (shouldStop())
      break;
    item->extrude = false;
    if (!item->render || !item->eligibleForExtrusion())
      continue;
    const auto admission =
        budget.reserve(item->buildingFlags(), item->pointCount);
    switch (admission) {
    case ExtrusionBudget::Admission::Selected:
      item->extrude = true;
      ++selection.eligibleRecords;
      break;
    case ExtrusionBudget::Admission::RecordLimit:
      ++selection.eligibleRecords;
      ++selection.recordLimitOverflow;
      break;
    case ExtrusionBudget::Admission::PointLimit:
      ++selection.eligibleRecords;
      ++selection.pointLimitOverflow;
      break;
    case ExtrusionBudget::Admission::IneligibleFlatBase:
      break;
    }
  }
  selection.selectedRecords = budget.records;
  selection.selectedPoints = budget.points;
  return selection;
}

struct RenderSelection {
  size_t selectedRecords = 0;
  size_t selectedPoints = 0;
  size_t pointLimitOverflow = 0;
};

// Keep a bounded heap whose root is the farthest retained candidate. A nearer
// candidate replaces that root, making the retained set independent of block
// cache/input traversal order while bounding sort workspace.
template <typename Container, typename RendersBefore>
bool retainNearestCandidate(
    Container &candidates, const typename Container::value_type &candidate,
    size_t maximumRecords, RendersBefore rendersBefore) {
  const auto nearerThan = [&](const auto &left, const auto &right) {
    return rendersBefore(right, left);
  };
  if (candidates.size() < maximumRecords) {
    candidates.push_back(candidate);
    std::push_heap(candidates.begin(), candidates.end(), nearerThan);
    return true;
  }
  if (candidates.empty() || !rendersBefore(candidates.front(), candidate))
    return false;
  std::pop_heap(candidates.begin(), candidates.end(), nearerThan);
  candidates.back() = candidate;
  std::push_heap(candidates.begin(), candidates.end(), nearerThan);
  return true;
}

// The record queue is already bounded and sorted far-to-near. Select its
// nearest records within the total source-point budget, then let the caller
// draw marked candidates in the unchanged far-to-near order.
template <typename ReverseIterator, typename ShouldStop = NeverStop>
RenderSelection selectNearestForRendering(ReverseIterator nearest,
                                          ReverseIterator farthest,
                                          ShouldStop shouldStop = {}) {
  RenderSelection selection;
  for (auto item = nearest; item != farthest; ++item) {
    if (shouldStop())
      break;
    item->render = false;
    if (item->pointCount >
        kMaximumRenderedBuildingPoints - selection.selectedPoints) {
      ++selection.pointLimitOverflow;
      continue;
    }
    item->render = true;
    ++selection.selectedRecords;
    selection.selectedPoints += item->pointCount;
  }
  return selection;
}

enum class Surface : uint8_t {
  WallLight,
  WallMiddle,
  WallDark,
  CourtyardCapture,
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

template <typename GroundPoints, typename ClippedPoints,
          typename ShouldStop = NeverStop>
double projectedFootprintAreaPixels(
    const map_building_block::Building &building, int32_t blockOffsetX,
    int32_t blockOffsetY, const map_projection::Projection &projection,
    GroundPoints &ground, ClippedPoints &clipped,
    ShouldStop shouldStop = {}) {
  double area = 0.0;
  for (const auto &ring : building.rings) {
    if (shouldStop())
      return 0.0;
    ground.clear();
    ground.reserve(ring.points.size());
    for (size_t index = 0; index < ring.points.size(); ++index) {
      if ((index & 0x1FU) == 0 && shouldStop())
        return 0.0;
      const auto &point = ring.points[index];
      ground.push_back(projection.groundForWorld(
          {static_cast<double>(blockOffsetX + point.x),
           static_cast<double>(blockOffsetY + point.y)}));
    }
    const auto *footprint = &ground;
    if (projection.isBirdsEye()) {
      map_projection::clipPolygonToNearPlane(projection, ground, clipped);
      footprint = &clipped;
    }
    if (footprint->size() < 3)
      continue;

    auto previous = projection.projectGround(footprint->back());
    if (!previous.valid)
      continue;
    double twiceSignedArea = 0.0;
    bool valid = true;
    for (size_t index = 0; index < footprint->size(); ++index) {
      if ((index & 0x1FU) == 0 && shouldStop())
        return 0.0;
      const auto &point = (*footprint)[index];
      const auto projected = projection.projectGround(point);
      if (!projected.valid) {
        valid = false;
        break;
      }
      twiceSignedArea +=
          previous.x * projected.y - projected.x * previous.y;
      previous = projected;
    }
    if (!valid)
      continue;
    const double ringArea = std::fabs(twiceSignedArea) * 0.5;
    area += ring.hole ? -ringArea : ringArea;
  }
  return std::max(0.0, area);
}

struct SurfaceStats {
  size_t wallCandidates = 0;
  size_t generatedWallFaces = 0;
  size_t suppressedWallFaces = 0;
};

// Restore the pixels under a projected courtyard after the outer roof has
// been filled. The snapshot is captured after wall drawing but before roofs,
// so land use, roads, farther buildings, and courtyard walls remain visible
// through the opening instead of being replaced by a fixed background color.
template <typename Points, typename Nodes, typename ShouldInterrupt>
bool restoreCourtyardUnderlay(const Points &points, uint16_t *canvas,
                              int32_t width, int32_t height,
                              size_t stridePixels, const uint16_t *underlay,
                              size_t underlayPixels, Nodes &nodes,
                              ShouldInterrupt &&shouldInterrupt) {
  if (points.size() < 3)
    return true;
  if (canvas == nullptr || underlay == nullptr || width <= 0 || height <= 0 ||
      stridePixels < static_cast<size_t>(width) ||
      underlayPixels < stridePixels * static_cast<size_t>(height) ||
      nodes.size() < points.size()) {
    return false;
  }

  int32_t minY = points.front().y;
  int32_t maxY = points.front().y;
  for (const auto &point : points) {
    minY = std::min<int32_t>(minY, point.y);
    maxY = std::max<int32_t>(maxY, point.y);
  }
  minY = std::max<int32_t>(0, minY);
  maxY = std::min<int32_t>(height - 1, maxY);
  if (minY > maxY)
    return true;

  for (int32_t y = minY; y <= maxY; ++y) {
    if ((y & 0x0F) == 0 && shouldInterrupt())
      return false;
    size_t count = 0;
    for (size_t index = 0; index < points.size(); ++index) {
      const auto &start = points[index];
      const auto &end = points[(index + 1U) % points.size()];
      if ((start.y < y && end.y >= y) ||
          (start.y >= y && end.y < y)) {
        nodes[count++] = static_cast<int32_t>(
            start.x + static_cast<double>(y - start.y) /
                          static_cast<double>(end.y - start.y) *
                          static_cast<double>(end.x - start.x));
      }
    }
    std::sort(nodes.begin(), nodes.begin() + count);
    for (size_t index = 0; index + 1U < count; index += 2U) {
      const int32_t startX = std::max<int32_t>(0, nodes[index]);
      const int32_t endX = std::min<int32_t>(width, nodes[index + 1U]);
      if (startX >= endX)
        continue;
      const size_t offset = static_cast<size_t>(y) * stridePixels + startX;
      std::memcpy(canvas + offset, underlay + offset,
                  static_cast<size_t>(endX - startX) * sizeof(uint16_t));
    }
  }
  return true;
}

// Emits walls first, then roof/courtyard rings. The callback returns false to
// interrupt rendering, matching the firmware polygon-fill contract.
template <typename DrawSurface, typename ShouldStop = NeverStop>
bool renderSurfaces(const map_building_block::Building &building,
                    int32_t blockOffsetX, int32_t blockOffsetY,
                    double blockMercatorScale,
                    const map_projection::Projection &projection,
                    bool extrusionRequested, DrawSurface &&drawSurface,
                    SurfaceStats *stats = nullptr,
                    ShouldStop shouldStop = {}) {
  const bool extrude = usesExtrusion(extrusionRequested, building.flags);
  const double minimumHeight =
      extrude ? building.minimumHeightDm / 10.0 : 0.0;
  const double height = extrude ? building.heightDm / 10.0 : 0.0;
  MapBuildingVector<ScreenPoint> screenRing;

  if (extrude) {
    for (const auto &ring : building.rings) {
      for (size_t index = 0; index < ring.points.size(); ++index) {
        if ((index & 0x1FU) == 0 && shouldStop())
          return false;
        if (stats != nullptr)
          ++stats->wallCandidates;
        if (index >= ring.walls.size() || ring.walls[index] == 0) {
          if (stats != nullptr)
            ++stats->suppressedWallFaces;
          continue;
        }
        const auto &start = ring.points[index];
        const auto &end = ring.points[(index + 1U) % ring.points.size()];
        auto startGround = projection.groundForWorld(
            {static_cast<double>(blockOffsetX + start.x),
             static_cast<double>(blockOffsetY + start.y)});
        auto endGround = projection.groundForWorld(
            {static_cast<double>(blockOffsetX + end.x),
             static_cast<double>(blockOffsetY + end.y)});
        if (!projection.clipSegmentToNearPlane(startGround, endGround)) {
          if (stats != nullptr)
            ++stats->suppressedWallFaces;
          continue;
        }
        const auto startBase = projection.projectElevatedGround(
            startGround, minimumHeight, blockMercatorScale);
        const auto endBase = projection.projectElevatedGround(
            endGround, minimumHeight, blockMercatorScale);
        const auto endTop = projection.projectElevatedGround(
            endGround, height, blockMercatorScale);
        const auto startTop = projection.projectElevatedGround(
            startGround, height, blockMercatorScale);
        if (!startBase.valid || !endBase.valid || !endTop.valid ||
            !startTop.valid) {
          if (stats != nullptr)
            ++stats->suppressedWallFaces;
          continue;
        }
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
        if (stats != nullptr)
          ++stats->generatedWallFaces;
      }
    }
  }

  const auto emitRoofRing = [&](const auto &ring, Surface surface) {
    MapBuildingVector<map_projection::GroundPoint> ground;
    MapBuildingVector<map_projection::GroundPoint> clipped;
    ground.clear();
    ground.reserve(ring.points.size());
    for (size_t index = 0; index < ring.points.size(); ++index) {
      if ((index & 0x1FU) == 0 && shouldStop())
        return false;
      const auto &point = ring.points[index];
      ground.push_back(projection.groundForWorld(
          {static_cast<double>(blockOffsetX + point.x),
           static_cast<double>(blockOffsetY + point.y)}));
    }
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
    return drawSurface(surface, screenRing);
  };
  // Let the compositor preserve real underlay pixels before the outer roof is
  // drawn. Hole rings are projected again for restoration after the roof.
  for (const auto &ring : building.rings) {
    if (shouldStop())
      return false;
    if (ring.hole && !emitRoofRing(ring, Surface::CourtyardCapture))
      return false;
  }
  for (const auto &ring : building.rings) {
    if (shouldStop())
      return false;
    if (!emitRoofRing(ring,
                      ring.hole ? Surface::Courtyard : Surface::Roof))
      return false;
  }
  return true;
}

} // namespace map_building_renderer
