#pragma once

#include <cstdint>

namespace map_line_style {

constexpr uint16_t kWhiteRgb565 = 0xFFFF;

constexpr bool isStreet(uint8_t typeId, uint16_t color, uint8_t width) {
  if (typeId != 0) {
    // Map format v2 reserves 1-49 for major, local, and service roads.
    return typeId >= 1 && typeId < 50;
  }

  // Legacy map blocks have no type IDs, so retain the renderer's existing
  // road classification based on style color and width.
  const bool majorRoad =
      (color == 0xFFF1 || color == 0xFF36 || color == 0xFCC2 ||
       color == 0xF567) &&
      width >= 5;
  const bool localStreet = color == kWhiteRgb565 && width >= 3;
  return majorRoad || localStreet;
}

constexpr uint16_t displayColor(uint8_t typeId, uint16_t color, uint8_t width,
                                bool mapNavigationActive) {
  return mapNavigationActive && isStreet(typeId, color, width)
             ? kWhiteRgb565
             : color;
}

} // namespace map_line_style
