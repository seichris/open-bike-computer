#pragma once

#include "mapSurface.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace map_building_workspace {

struct Region {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;

  constexpr bool valid() const { return width > 0 && height > 0; }
  constexpr size_t pixels() const {
    return valid() ? static_cast<size_t>(width) * static_cast<size_t>(height)
                   : 0U;
  }
};

template <typename Points>
Region clippedRegion(const Points &points, int32_t width, int32_t height) {
  if (points.empty() || width <= 0 || height <= 0)
    return {};
  int32_t minX = points.front().x;
  int32_t maxX = points.front().x;
  int32_t minY = points.front().y;
  int32_t maxY = points.front().y;
  for (const auto &point : points) {
    minX = std::min<int32_t>(minX, point.x);
    maxX = std::max<int32_t>(maxX, point.x);
    minY = std::min<int32_t>(minY, point.y);
    maxY = std::max<int32_t>(maxY, point.y);
  }
  minX = std::max<int32_t>(0, minX);
  minY = std::max<int32_t>(0, minY);
  maxX = std::min<int32_t>(width - 1, maxX);
  maxY = std::min<int32_t>(height - 1, maxY);
  if (minX > maxX || minY > maxY)
    return {};
  return {minX, minY, maxX - minX + 1, maxY - minY + 1};
}

template <typename PixelVector>
bool captureRegion(map_surface::Rgb565Surface surface, Region region,
                   PixelVector &pixels, size_t maximumPixels) {
  if (!surface.valid() || !region.valid() ||
      region.x < 0 || region.y < 0 ||
      region.x + region.width > surface.width ||
      region.y + region.height > surface.height ||
      region.pixels() > maximumPixels) {
    return false;
  }
  pixels.resize(region.pixels());
  for (int32_t row = 0; row < region.height; ++row) {
    const uint16_t *source = surface.row(region.y + row) + region.x;
    uint16_t *destination = pixels.data() +
                            static_cast<size_t>(row) * region.width;
    std::memcpy(destination, source,
                static_cast<size_t>(region.width) * sizeof(uint16_t));
  }
  return true;
}

template <typename Points, typename PixelVector, typename NodeVector,
          typename ShouldStop>
bool restorePolygon(const Points &points, map_surface::Rgb565Surface surface,
                    Region region, const PixelVector &underlay,
                    NodeVector &nodes, ShouldStop shouldStop) {
  if (points.size() < 3)
    return true;
  if (!surface.valid() || !region.valid() ||
      underlay.size() < region.pixels()) {
    return false;
  }
  if (nodes.size() < points.size())
    nodes.resize(points.size());

  const int32_t minY = region.y;
  const int32_t maxY = region.y + region.height - 1;
  for (int32_t y = minY; y <= maxY; ++y) {
    if ((y & 0x0f) == 0 && shouldStop())
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
    uint16_t *destination = surface.row(y);
    const uint16_t *source =
        underlay.data() + static_cast<size_t>(y - region.y) * region.width;
    for (size_t index = 0; index + 1U < count; index += 2U) {
      const int32_t startX =
          std::max<int32_t>(region.x, std::max<int32_t>(0, nodes[index]));
      const int32_t endX = std::min<int32_t>(
          region.x + region.width,
          std::min<int32_t>(surface.width, nodes[index + 1U]));
      if (startX >= endX)
        continue;
      std::memcpy(destination + startX, source + (startX - region.x),
                  static_cast<size_t>(endX - startX) * sizeof(uint16_t));
    }
  }
  return true;
}

} // namespace map_building_workspace
