#pragma once

#include "mapPoiBlock.hpp"
#include "mapSurface.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdlib>

namespace map_poi_icon {

constexpr int32_t kSize = 14;

inline void pixel(map_surface::Rgb565Surface surface, int32_t x, int32_t y,
                  uint16_t color) {
  if (surface.contains(x, y))
    surface.row(y)[x] = color;
}

inline void line(map_surface::Rgb565Surface surface, int32_t x0, int32_t y0,
                 int32_t x1, int32_t y1, uint16_t color) {
  const int32_t dx = std::abs(x1 - x0);
  const int32_t sx = x0 < x1 ? 1 : -1;
  const int32_t dy = -std::abs(y1 - y0);
  const int32_t sy = y0 < y1 ? 1 : -1;
  int32_t error = dx + dy;
  while (true) {
    pixel(surface, x0, y0, color);
    if (x0 == x1 && y0 == y1)
      break;
    const int32_t doubled = error * 2;
    if (doubled >= dy) {
      error += dy;
      x0 += sx;
    }
    if (doubled <= dx) {
      error += dx;
      y0 += sy;
    }
  }
}

inline uint16_t categoryColor(map_poi_block::Category category) {
  switch (category) {
  case map_poi_block::Category::Shops:
    return 0xF81FU;
  case map_poi_block::Category::RestaurantsAndCafes:
    return 0xFD20U;
  case map_poi_block::Category::PublicToilets:
    return 0x041FU;
  case map_poi_block::Category::GasStations:
    return 0xF800U;
  case map_poi_block::Category::BicycleServices:
    return 0x07E0U;
  }
  return 0xFFFFU;
}

inline void draw(map_surface::Rgb565Surface surface, int32_t centerX,
                 int32_t centerY, map_poi_block::Category category) {
  if (!surface.valid())
    return;
  constexpr uint16_t border = 0xFFFFU;
  constexpr uint16_t symbol = 0x0000U;
  const uint16_t fill = categoryColor(category);
  const int32_t left = centerX - kSize / 2;
  const int32_t top = centerY - kSize / 2;
  for (int32_t y = 0; y < kSize; ++y) {
    for (int32_t x = 0; x < kSize; ++x) {
      const bool edge = x == 0 || y == 0 || x == kSize - 1 ||
                        y == kSize - 1;
      pixel(surface, left + x, top + y, edge ? border : fill);
    }
  }
  switch (category) {
  case map_poi_block::Category::Shops:
    line(surface, left + 4, top + 5, left + 4, top + 10, symbol);
    line(surface, left + 4, top + 10, left + 9, top + 10, symbol);
    line(surface, left + 9, top + 10, left + 9, top + 5, symbol);
    line(surface, left + 5, top + 5, left + 8, top + 5, symbol);
    line(surface, left + 5, top + 5, left + 6, top + 3, symbol);
    line(surface, left + 8, top + 5, left + 7, top + 3, symbol);
    break;
  case map_poi_block::Category::RestaurantsAndCafes:
    line(surface, left + 3, top + 4, left + 3, top + 10, symbol);
    line(surface, left + 2, top + 6, left + 5, top + 6, symbol);
    line(surface, left + 9, top + 3, left + 9, top + 10, symbol);
    break;
  case map_poi_block::Category::PublicToilets:
    pixel(surface, left + 4, top + 3, symbol);
    pixel(surface, left + 9, top + 3, symbol);
    line(surface, left + 4, top + 5, left + 4, top + 10, symbol);
    line(surface, left + 9, top + 5, left + 9, top + 10, symbol);
    break;
  case map_poi_block::Category::GasStations:
    for (int32_t y = 4; y <= 10; ++y) {
      pixel(surface, left + 3, top + y, symbol);
      pixel(surface, left + 8, top + y, symbol);
    }
    line(surface, left + 3, top + 4, left + 8, top + 4, symbol);
    line(surface, left + 3, top + 10, left + 8, top + 10, symbol);
    line(surface, left + 8, top + 6, left + 10, top + 8, symbol);
    break;
  case map_poi_block::Category::BicycleServices:
    pixel(surface, left + 3, top + 9, symbol);
    pixel(surface, left + 4, top + 8, symbol);
    pixel(surface, left + 4, top + 10, symbol);
    pixel(surface, left + 10, top + 9, symbol);
    pixel(surface, left + 9, top + 8, symbol);
    pixel(surface, left + 9, top + 10, symbol);
    line(surface, left + 4, top + 9, left + 7, top + 6, symbol);
    line(surface, left + 7, top + 6, left + 10, top + 9, symbol);
    line(surface, left + 5, top + 9, left + 9, top + 9, symbol);
    break;
  }
}

} // namespace map_poi_icon
