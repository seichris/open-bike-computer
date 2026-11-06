/**
 * @file display.hpp
 * @brief CO5300 display constants for the Waveshare AMOLED board.
 */

#pragma once

#include <Arduino.h>
#include "../board/board.hpp"

namespace waveshare_board::display {

constexpr uint16_t LOGICAL_WIDTH = board::display::width;
constexpr uint16_t LOGICAL_HEIGHT = board::display::height;
constexpr uint16_t ACTIVE_WIDTH = board::display::width;
constexpr uint16_t ACTIVE_HEIGHT = board::display::height;

// Arduino_CO5300(..., width, height, columnOffset, 0, 0, 0): the vendor
// examples use 6 on the 1.75 and 22 on the 2.06, and the ESP-IDF BSP applies
// the same panel gap with esp_lcd_panel_set_gap().
constexpr uint8_t ARDUINO_CO5300_COL_OFFSET1 = board::display::columnOffset;
constexpr uint8_t ARDUINO_CO5300_ROW_OFFSET1 = 0;
constexpr uint8_t ARDUINO_CO5300_COL_OFFSET2 = 0;
constexpr uint8_t ARDUINO_CO5300_ROW_OFFSET2 = 0;

constexpr uint8_t ROTATION_0 = 0;
constexpr uint8_t ROTATION_90 = 1;
constexpr uint8_t MAX_SUPPORTED_ROTATION = ROTATION_90;

constexpr uint8_t DEFAULT_ROTATION = board::display::defaultRotation;
constexpr bool ROTATION_90_ENABLED = board::display::rotation90Enabled;
static_assert(DEFAULT_ROTATION <= MAX_SUPPORTED_ROTATION,
              "the board's default rotation is not supported");
static_assert(ROTATION_90_ENABLED || DEFAULT_ROTATION != ROTATION_90,
              "the board starts rotated but does not offer that rotation");

} // namespace waveshare_board::display
