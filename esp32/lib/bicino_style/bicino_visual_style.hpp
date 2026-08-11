#pragma once

#include <cstdint>

namespace bicino_visual_style {

constexpr uint16_t rgb888ToRgb565(uint32_t rgb) {
  return static_cast<uint16_t>(((rgb >> 8) & 0xF800) |
                               ((rgb >> 5) & 0x07E0) |
                               ((rgb >> 3) & 0x001F));
}

constexpr uint32_t NAVIGATION_BLUE_RGB888 = 0x0088FF;
constexpr uint16_t NAVIGATION_BLUE_RGB565 =
    rgb888ToRgb565(NAVIGATION_BLUE_RGB888);
static_assert(NAVIGATION_BLUE_RGB565 == 0x045F,
              "Navigation blue conversion must remain stable");

constexpr uint32_t BRAND_RED_RGB888 = 0xFF372E;
constexpr uint32_t SUCCESS_GREEN_RGB888 = 0x35D46F;
constexpr uint32_t PAIRING_AMBER_RGB888 = 0xF6B73C;
constexpr uint32_t WAITING_GRAY_RGB888 = 0x8B93A1;
constexpr uint32_t SECONDARY_TEXT_RGB888 = 0xAAAAAA;

} // namespace bicino_visual_style
