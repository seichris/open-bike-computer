#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace ride_telemetry_layout {

struct Rect {
  int32_t x = 0;
  int32_t y = 0;
  int32_t width = 0;
  int32_t height = 0;

  constexpr int32_t right() const { return x + width; }
  constexpr int32_t bottom() const { return y + height; }
};

struct Layout {
  int32_t screenWidth = 0;
  int32_t screenHeight = 0;
  Rect page{};
  Rect status{};
  Rect hero{};
  Rect heroUnit{};
  std::array<Rect, 6> metrics{};
};

constexpr Layout makeLayout(int32_t width, int32_t height) {
  constexpr int32_t columnGap = 12;
  constexpr int32_t metricFirstY = 136;
  constexpr int32_t metricRowSpacing = 98;
  constexpr int32_t metricCellHeight = 70;
  const int32_t columnWidth = (width - 36 - columnGap) / 2;
  const int32_t leftX = 12;
  const int32_t rightX = leftX + columnWidth + columnGap;

  Layout layout{};
  layout.screenWidth = width;
  layout.screenHeight = height;
  layout.page = {0, 0, width, height};
  layout.status = {16, 8, width - 32, 24};
  layout.hero = {0, 30, width, 60};
  layout.heroUnit = {0, 92, width, 24};
  layout.metrics = {{
      {leftX, metricFirstY, columnWidth, metricCellHeight},
      {rightX, metricFirstY, columnWidth, metricCellHeight},
      {leftX, metricFirstY + metricRowSpacing, columnWidth,
       metricCellHeight},
      {rightX, metricFirstY + metricRowSpacing, columnWidth,
       metricCellHeight},
      {leftX, metricFirstY + 2 * metricRowSpacing, columnWidth,
       metricCellHeight},
      {rightX, metricFirstY + 2 * metricRowSpacing, columnWidth,
       metricCellHeight},
  }};
  return layout;
}

constexpr bool fits(const Rect &rect, int32_t width, int32_t height) {
  return rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
         rect.right() <= width && rect.bottom() <= height;
}

constexpr bool isValid(const Layout &layout) {
  if (!fits(layout.page, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.status, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.hero, layout.screenWidth, layout.screenHeight) ||
      !fits(layout.heroUnit, layout.screenWidth, layout.screenHeight)) {
    return false;
  }
  for (const Rect &metric : layout.metrics) {
    if (!fits(metric, layout.screenWidth, layout.screenHeight)) {
      return false;
    }
  }
  for (std::size_t row = 0; row < 3; ++row) {
    const Rect &left = layout.metrics[row * 2];
    const Rect &right = layout.metrics[row * 2 + 1];
    if (left.right() > right.x) {
      return false;
    }
  }
  return layout.metrics[3].bottom() <= layout.metrics[4].y;
}

} // namespace ride_telemetry_layout
