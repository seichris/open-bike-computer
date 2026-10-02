#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace world_radio_globe {

struct Coordinate {
  int32_t latitudeE7 = 0;
  int32_t longitudeE7 = 0;
};

struct Point {
  int16_t x = 0;
  int16_t y = 0;
};

// The icon deliberately uses a compact, approximate whole-world projection.
// A tap inside the circular Earth selects a latitude/longitude without keeping
// a full raster map in flash or a decoded texture in PSRAM.
inline bool coordinateForPoint(int16_t x, int16_t y, int16_t diameter,
                               Coordinate &coordinate) {
  if (diameter < 2) {
    return false;
  }
  const int32_t radius = diameter / 2;
  const int32_t dx = x - radius;
  const int32_t dy = y - radius;
  if (dx * dx + dy * dy > radius * radius) {
    return false;
  }
  coordinate.longitudeE7 = static_cast<int32_t>(
      std::clamp<int64_t>(static_cast<int64_t>(dx) * 1800000000LL / radius,
                          -1800000000LL, 1800000000LL));
  coordinate.latitudeE7 = static_cast<int32_t>(
      std::clamp<int64_t>(-static_cast<int64_t>(dy) * 900000000LL / radius,
                          -900000000LL, 900000000LL));
  return true;
}

inline Point pointForCoordinate(int32_t latitudeE7, int32_t longitudeE7,
                                int16_t diameter, int16_t inset = 6) {
  const int32_t center = diameter / 2;
  const int32_t radius = std::max<int32_t>(1, center - inset);
  int32_t x = std::clamp<int64_t>(longitudeE7, -1800000000LL, 1800000000LL) *
              radius / 1800000000LL;
  int32_t y = -std::clamp<int64_t>(latitudeE7, -900000000LL, 900000000LL) *
              radius / 900000000LL;
  const int64_t distanceSquared =
      static_cast<int64_t>(x) * x + static_cast<int64_t>(y) * y;
  const int64_t radiusSquared = static_cast<int64_t>(radius) * radius;
  if (distanceSquared > radiusSquared) {
    const double scale = static_cast<double>(radius) /
                         std::sqrt(static_cast<double>(distanceSquared));
    // Truncation keeps the rounded point inside the visible circle. Rounding
    // each axis independently can place a diagonal point one pixel outside.
    x = static_cast<int32_t>(x * scale);
    y = static_cast<int32_t>(y * scale);
  }
  return {static_cast<int16_t>(center + x),
          static_cast<int16_t>(center + y)};
}

} // namespace world_radio_globe
