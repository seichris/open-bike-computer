#pragma once

#include <cstdint>

namespace battery_status_layout {

struct Layout {
  int32_t diameter = 0;
  int32_t deviceY = 0;
  int32_t phoneY = 0;
  int32_t gap = 0;
  int32_t topMargin = 0;
  int32_t bottomMargin = 0;
};

constexpr Layout makeLayout(int32_t width, int32_t height) {
  const int32_t shortestSide = width < height ? width : height;
  const int32_t displayDifference =
      width > height ? width - height : height - width;
  const bool squareDisplay = displayDifference < 24;
  int32_t diameter =
      squareDisplay ? (shortestSide * 36) / 100 : (shortestSide * 46) / 100;
  const bool hasLargeDeviceChrome = height >= 400;
  const int32_t edgeInset = hasLargeDeviceChrome ? 32 : 6;
  const int32_t minimumGap = hasLargeDeviceChrome ? 16 : 6;
  const int32_t maximumDiameter =
      (height - (edgeInset * 2) - minimumGap) / 2;
  if (diameter > maximumDiameter) {
    diameter = maximumDiameter;
  }

  const int32_t gap = height - (edgeInset * 2) - (diameter * 2);
  const int32_t phoneY = edgeInset + diameter + gap;
  return {
      diameter,
      edgeInset,
      phoneY,
      gap,
      edgeInset,
      height - (phoneY + diameter),
  };
}

} // namespace battery_status_layout
