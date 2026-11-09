/**
 * @file guiLayout.hpp
 * @brief Board-specific GUI geometry that keeps shared UI code portable.
 */

#pragma once

#include <stdint.h>

#include "../../board/board.hpp"

namespace gui_layout {

// Map screen geometry comes from the board definition (board::layout).
constexpr uint16_t MAP_NONFULLSCREEN_RESERVED_HEIGHT =
    board::layout::mapNonFullscreenReservedHeight;
constexpr uint8_t MAP_ANCHOR_X_PERCENT = board::layout::mapAnchorXPercent;
constexpr uint8_t MAP_ANCHOR_Y_PERCENT = board::layout::mapAnchorYPercent;
constexpr uint8_t MAP_TOOLBAR_OFFSET = board::layout::mapToolbarOffset;
constexpr uint8_t MAP_TOOLBAR_SPACE = board::layout::mapToolbarSpace;
constexpr uint8_t MAP_TOOLBAR_INSET = board::layout::mapToolbarInset;
constexpr uint8_t MAP_TOOLBAR_FULLSCREEN_BOTTOM_MARGIN =
    board::layout::mapToolbarFullscreenBottomMargin;

// Drag preview shifts the map canvas by the inverse of mapDragDelta(). Both
// touch controllers report display-calibrated coordinates; a board without
// touch never drags.
constexpr int8_t MAP_DRAG_DELTA_SIGN = board::display::touch ? -1 : 1;

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

inline int16_t centeredViewportOrigin(uint16_t containerExtent,
                                      uint16_t viewportExtent) {
  return (static_cast<int32_t>(containerExtent) - viewportExtent) / 2;
}

/**
 * Return the LVGL x/y style offset that places a point inside a center-aligned
 * object at a target coordinate in its parent. LVGL keeps the object's CENTER
 * alignment after lv_obj_center(), so lv_obj_set_pos() is relative to the
 * resolved centered origin rather than an absolute top-left coordinate.
 */
inline int32_t centerAlignedOffsetForPoint(uint16_t containerExtent,
                                           uint16_t objectExtent,
                                           int32_t objectPoint,
                                           int32_t targetPoint) {
  return targetPoint - objectPoint -
         centeredViewportOrigin(containerExtent, objectExtent);
}

inline int16_t mapScreenAnchorX(uint16_t containerWidth,
                                uint16_t mapWidth) {
  return centeredViewportOrigin(containerWidth, mapWidth) +
         mapAnchorX(mapWidth);
}

inline int16_t mapScreenAnchorY(uint16_t containerHeight,
                                uint16_t mapHeight) {
  return centeredViewportOrigin(containerHeight, mapHeight) +
         mapAnchorY(mapHeight);
}

inline int16_t mapDragDelta(int16_t delta) {
  return delta * MAP_DRAG_DELTA_SIGN;
}

} // namespace gui_layout
