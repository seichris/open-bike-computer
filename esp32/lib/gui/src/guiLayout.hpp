/**
 * @file guiLayout.hpp
 * @brief Board-specific GUI geometry that keeps shared UI code portable.
 */

#pragma once

#include <stdint.h>

namespace gui_layout {

#if defined(WAVESHARE_AMOLED_206)
constexpr uint16_t MAP_NONFULLSCREEN_RESERVED_HEIGHT = 72;
constexpr uint8_t MAP_ANCHOR_X_PERCENT = 50;
constexpr uint8_t MAP_ANCHOR_Y_PERCENT = 58;
constexpr uint8_t MAP_TOOLBAR_OFFSET = 92;
constexpr uint8_t MAP_TOOLBAR_SPACE = 54;
constexpr uint8_t MAP_TOOLBAR_INSET = 12;
constexpr uint8_t MAP_TOOLBAR_FULLSCREEN_BOTTOM_MARGIN = 30;
constexpr int8_t MAP_DRAG_DELTA_SIGN = -1;
#elif defined(LARGE_SCREEN)
constexpr uint16_t MAP_NONFULLSCREEN_RESERVED_HEIGHT = 100;
constexpr uint8_t MAP_ANCHOR_X_PERCENT = 50;
constexpr uint8_t MAP_ANCHOR_Y_PERCENT = 50;
constexpr uint8_t MAP_TOOLBAR_OFFSET = 100;
constexpr uint8_t MAP_TOOLBAR_SPACE = 60;
constexpr uint8_t MAP_TOOLBAR_INSET = 10;
constexpr uint8_t MAP_TOOLBAR_FULLSCREEN_BOTTOM_MARGIN = 24;
constexpr int8_t MAP_DRAG_DELTA_SIGN = 1;
#else
constexpr uint16_t MAP_NONFULLSCREEN_RESERVED_HEIGHT = 100;
constexpr uint8_t MAP_ANCHOR_X_PERCENT = 50;
constexpr uint8_t MAP_ANCHOR_Y_PERCENT = 50;
constexpr uint8_t MAP_TOOLBAR_OFFSET = 80;
constexpr uint8_t MAP_TOOLBAR_SPACE = 50;
constexpr uint8_t MAP_TOOLBAR_INSET = 10;
constexpr uint8_t MAP_TOOLBAR_FULLSCREEN_BOTTOM_MARGIN = 24;
constexpr int8_t MAP_DRAG_DELTA_SIGN = 1;
#endif

inline uint16_t mapViewportHeight(uint16_t screenHeight) {
  if (screenHeight <= MAP_NONFULLSCREEN_RESERVED_HEIGHT) {
    return screenHeight;
  }
  return screenHeight - MAP_NONFULLSCREEN_RESERVED_HEIGHT;
}

inline int16_t mapAnchorX(uint16_t width) {
  return (width * MAP_ANCHOR_X_PERCENT) / 100;
}

inline int16_t mapAnchorY(uint16_t height) {
  return (height * MAP_ANCHOR_Y_PERCENT) / 100;
}

inline int16_t mapDragDelta(int16_t delta) {
  return delta * MAP_DRAG_DELTA_SIGN;
}

} // namespace gui_layout
