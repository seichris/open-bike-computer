#pragma once

#include <cstdint>

namespace navigation_visual_style {

// One canonical color for the route overlay and both current-position marker
// shapes. The RGB888 value is the exact expanded equivalent of the RGB565
// value written into the map canvas.
constexpr uint32_t ROUTE_BLUE_RGB888 = 0x18F3FF;

constexpr uint16_t rgb888ToRgb565(uint32_t rgb) {
  return static_cast<uint16_t>(((rgb >> 8) & 0xF800) |
                               ((rgb >> 5) & 0x07E0) |
                               ((rgb >> 3) & 0x001F));
}

constexpr uint16_t ROUTE_BLUE_RGB565 = rgb888ToRgb565(ROUTE_BLUE_RGB888);
static_assert(ROUTE_BLUE_RGB565 == 0x1F9F,
              "Route blue must remain identical in RGB888 and RGB565");

constexpr int16_t POSITION_MARKER_BASE_SIZE = 48;

} // namespace navigation_visual_style
