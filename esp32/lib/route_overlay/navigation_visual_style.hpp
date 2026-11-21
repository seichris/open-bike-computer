#pragma once

#include <cstdint>

#include "../bicino_style/bicino_visual_style.hpp"

namespace navigation_visual_style {

// Compatibility aliases keep map/route call sites focused while the color is
// owned by the shared Bicino visual system.
#ifdef WAVESHARE_EPAPER_397
constexpr uint32_t ROUTE_BLUE_RGB888 = 0x000000;
constexpr uint16_t ROUTE_BLUE_RGB565 = 0x0000;
// One-bit panel: the saved route under a detour is a thin black line; the
// guidance line's white halo separates the two where they meet.
constexpr uint16_t REFERENCE_TRACK_RGB565 = 0x0000;
#else
constexpr uint32_t ROUTE_BLUE_RGB888 =
    bicino_visual_style::NAVIGATION_BLUE_RGB888;
constexpr uint16_t ROUTE_BLUE_RGB565 =
    bicino_visual_style::NAVIGATION_BLUE_RGB565;
// Muted blue-grey for the saved route under a detour: same family as the
// guidance line, clearly secondary to it.
constexpr uint32_t REFERENCE_TRACK_RGB888 = 0x7A9CC6;
constexpr uint16_t REFERENCE_TRACK_RGB565 =
    bicino_visual_style::rgb888ToRgb565(REFERENCE_TRACK_RGB888);

#endif

constexpr int16_t POSITION_MARKER_BASE_SIZE = 48;

} // namespace navigation_visual_style
