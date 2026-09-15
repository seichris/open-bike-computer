#pragma once

#include <cstdint>

#include "../bicino_style/bicino_visual_style.hpp"

namespace navigation_visual_style {

// Compatibility aliases keep map/route call sites focused while the color is
// owned by the shared Bicino visual system.
#ifdef WAVESHARE_EPAPER_397
constexpr uint32_t ROUTE_BLUE_RGB888 = 0x000000;
constexpr uint16_t ROUTE_BLUE_RGB565 = 0x0000;
#else
constexpr uint32_t ROUTE_BLUE_RGB888 =
    bicino_visual_style::NAVIGATION_BLUE_RGB888;
constexpr uint16_t ROUTE_BLUE_RGB565 =
    bicino_visual_style::NAVIGATION_BLUE_RGB565;

#endif

constexpr int16_t POSITION_MARKER_BASE_SIZE = 48;

} // namespace navigation_visual_style
