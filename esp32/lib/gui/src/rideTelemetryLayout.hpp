#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace ride_telemetry_layout {

constexpr int32_t kMetricTitleLineHeight = 21;
constexpr int32_t kMetricTitleValueGap = 1;
constexpr int32_t kMetricValueOffsetY =
    kMetricTitleLineHeight + kMetricTitleValueGap;
constexpr int32_t kMetricRowGap = 8;

constexpr bool useLargeMetricValueFont(int32_t screenWidth) {
  // The 466 px display fits the compact 64 px values; the 410 px display
  // needs 42 px values so elapsed times and distances remain unclipped.
  return screenWidth >= 440;
}

constexpr int32_t metricValueLineHeight(int32_t screenWidth) {
  // LVGL line heights for the compact 64 px font and Montserrat 42.
  return useLargeMetricValueFont(screenWidth) ? 60 : 46;
}

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
  const int32_t metricCellHeight =
      kMetricValueOffsetY + metricValueLineHeight(width);
  const int32_t metricRowSpacing = metricCellHeight + kMetricRowGap;
  const int32_t columnWidth = (width - 36 - columnGap) / 2;
  const int32_t leftX = 12;
  const int32_t rightX = leftX + columnWidth + columnGap;

  Layout layout{};
  layout.screenWidth = width;
  layout.screenHeight = height;
  layout.page = {0, 0, width, height};
  layout.status = {16, 8, width - 32, 24};
  layout.hero = {0, 45, width, 61};
  layout.heroUnit = {0, 112, width, 24};
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
  for (std::size_t row = 0; row + 1 < 3; ++row) {
    if (layout.metrics[row * 2].bottom() >
        layout.metrics[(row + 1) * 2].y) {
      return false;
    }
  }
  return true;
}

} // namespace ride_telemetry_layout
