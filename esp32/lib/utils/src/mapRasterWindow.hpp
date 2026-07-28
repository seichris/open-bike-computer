/**
 * @file mapRasterWindow.hpp
 * @brief Pure geometry for the standalone Map's rolling raster window.
 */

#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace map_raster_window {

constexpr uint8_t kWideGridRadius = 2;
constexpr uint8_t kWideGridSpan = (2 * kWideGridRadius) + 1;
constexpr uint8_t kCompactGridRadius = 3;
constexpr uint8_t kCompactGridSpan = (2 * kCompactGridRadius) + 1;
// Keep the original names as aliases for the maximum-zoom layout. They also
// describe the largest individual cell. Scratch storage must cover either
// layout's complete incoming edge.
constexpr uint8_t kGridRadius = kWideGridRadius;
constexpr uint8_t kGridSpan = kWideGridSpan;
constexpr uint8_t kScratchTileCount = kCompactGridSpan;
// A 192 px cell keeps a full screen of prepared pixels around both supported
// viewports while leaving enough PSRAM for the vector block currently being
// rasterized. Larger cells made the front buffer compete with dense map
// blocks during the first zoom-5 build.
constexpr uint16_t kCellExtentPx = 192;
// Zooms 1...4 use a 7x7 grid of smaller cells. Its 896 px square raster keeps
// 215 px prepared around a 466 px viewport. More importantly, recycling starts
// at 64 px, leaving another 151 px before the hard edge, and an incoming edge
// contains 42% fewer pixels than the old 3x3-of-256 layout. That gives rapid
// consecutive drags time to recycle without trading the gap for black pixels.
constexpr uint16_t kCompactCellExtentPx = 128;
constexpr double kRotationReuseToleranceRad = 0.08726646259971647; // 5 deg

struct Layout {
  uint8_t radius;
  uint8_t span;
  uint16_t cellExtent;
};

constexpr Layout layoutForZoom(uint8_t zoom, uint8_t maximumZoom = 5) {
  return zoom >= maximumZoom
             ? Layout{kWideGridRadius, kWideGridSpan, kCellExtentPx}
             : Layout{kCompactGridRadius, kCompactGridSpan,
                      kCompactCellExtentPx};
}

struct Extent {
  uint16_t width;
  uint16_t height;
};

constexpr Extent gridExtent(uint16_t cellWidth = kCellExtentPx,
                            uint16_t cellHeight = kCellExtentPx,
                            uint8_t gridSpan = kGridSpan) {
  return {static_cast<uint16_t>(cellWidth * gridSpan),
          static_cast<uint16_t>(cellHeight * gridSpan)};
}

constexpr Extent gridExtent(Layout layout) {
  return gridExtent(layout.cellExtent, layout.cellExtent, layout.span);
}

constexpr int32_t centerLimit(uint16_t viewportExtent,
                              uint16_t cellExtent = kCellExtentPx,
                              uint8_t gridSpan = kGridSpan) {
  // Keeping the requested viewport center inside this range guarantees that
  // no display pixel can move beyond the prepared raster.
  return static_cast<int32_t>(cellExtent * gridSpan - viewportExtent) / 2;
}

constexpr int32_t clampCenterOffset(int32_t offset, uint16_t viewportExtent,
                                    uint16_t cellExtent = kCellExtentPx,
                                    uint8_t gridSpan = kGridSpan) {
  const int32_t limit = centerLimit(viewportExtent, cellExtent, gridSpan);
  return offset < -limit ? -limit : (offset > limit ? limit : offset);
}

constexpr int32_t clampDragOffset(int32_t baseCenterOffset,
                                  int32_t requestedDragOffset,
                                  uint16_t viewportExtent,
                                  uint16_t cellExtent = kCellExtentPx,
                                  uint8_t gridSpan = kGridSpan) {
  return clampCenterOffset(baseCenterOffset + requestedDragOffset,
                           viewportExtent, cellExtent, gridSpan) -
         baseCenterOffset;
}

constexpr int8_t recycleDirection(double centerOffset,
                                  uint16_t cellExtent = kCellExtentPx) {
  const double threshold = static_cast<double>(cellExtent) / 2.0;
  return centerOffset > threshold ? 1 : (centerOffset < -threshold ? -1 : 0);
}

constexpr int8_t replacementCellOffset(int8_t direction,
                                       uint8_t gridRadius = kGridRadius) {
  return direction < 0 ? -static_cast<int8_t>(gridRadius)
                       : (direction > 0 ? static_cast<int8_t>(gridRadius)
                                        : 0);
}

inline double angularDistance(double first, double second) {
  return std::fabs(std::atan2(std::sin(first - second),
                             std::cos(first - second)));
}

inline bool rotationIsCompatible(double prepared, double requested) {
  return angularDistance(prepared, requested) <= kRotationReuseToleranceRad;
}

constexpr bool centerIsCovered(int32_t x, int32_t y, uint16_t viewportWidth,
                               uint16_t viewportHeight,
                               uint16_t cellWidth = kCellExtentPx,
                               uint16_t cellHeight = kCellExtentPx,
                               uint8_t gridSpan = kGridSpan) {
  return x >= -centerLimit(viewportWidth, cellWidth, gridSpan) &&
         x <= centerLimit(viewportWidth, cellWidth, gridSpan) &&
         y >= -centerLimit(viewportHeight, cellHeight, gridSpan) &&
         y <= centerLimit(viewportHeight, cellHeight, gridSpan);
}

inline void shiftPixelsHorizontal(uint16_t *grid, const uint16_t *scratch,
                                  uint16_t cellWidth, uint16_t cellHeight,
                                  int8_t direction,
                                  uint8_t gridSpan = kGridSpan) {
  if (grid == nullptr || scratch == nullptr || direction == 0)
    return;
  const size_t gridWidth = static_cast<size_t>(cellWidth) * gridSpan;
  const size_t cellPixels = static_cast<size_t>(cellWidth) * cellHeight;
  for (size_t y = 0; y < static_cast<size_t>(cellHeight) * gridSpan; ++y) {
    uint16_t *row = grid + (y * gridWidth);
    const size_t scratchIndex = y / cellHeight;
    const size_t scratchY = y % cellHeight;
    const uint16_t *source = scratch + (scratchIndex * cellPixels) +
                             (scratchY * cellWidth);
    if (direction > 0) {
      std::memmove(row, row + cellWidth,
                   sizeof(uint16_t) * cellWidth * (gridSpan - 1));
      std::memcpy(row + (cellWidth * (gridSpan - 1)), source,
                  sizeof(uint16_t) * cellWidth);
    } else {
      std::memmove(row + cellWidth, row,
                   sizeof(uint16_t) * cellWidth * (gridSpan - 1));
      std::memcpy(row, source, sizeof(uint16_t) * cellWidth);
    }
  }
}

inline void shiftPixelsVertical(uint16_t *grid, const uint16_t *scratch,
                                uint16_t cellWidth, uint16_t cellHeight,
                                int8_t direction,
                                uint8_t gridSpan = kGridSpan) {
  if (grid == nullptr || scratch == nullptr || direction == 0)
    return;
  const size_t gridWidth = static_cast<size_t>(cellWidth) * gridSpan;
  const size_t gridRowPixels = gridWidth * cellHeight;
  uint16_t *newRow =
      direction > 0 ? grid + (gridRowPixels * (gridSpan - 1)) : grid;
  if (direction > 0) {
    std::memmove(grid, grid + gridRowPixels,
                 sizeof(uint16_t) * gridRowPixels * (gridSpan - 1));
  } else {
    std::memmove(grid + gridRowPixels, grid,
                 sizeof(uint16_t) * gridRowPixels * (gridSpan - 1));
  }

  const size_t cellPixels = static_cast<size_t>(cellWidth) * cellHeight;
  for (size_t column = 0; column < gridSpan; ++column) {
    const uint16_t *cell = scratch + (column * cellPixels);
    for (size_t y = 0; y < cellHeight; ++y) {
      std::memcpy(newRow + (y * gridWidth) + (column * cellWidth),
                  cell + (y * cellWidth), sizeof(uint16_t) * cellWidth);
    }
  }
}

} // namespace map_raster_window
