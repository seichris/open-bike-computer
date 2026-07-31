/**
 * @file waveshare_board.hpp
 * @brief Waveshare ESP32-S3 Touch AMOLED 1.75 board helpers.
 */

#pragma once

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include <Arduino.h>

namespace waveshare_board {

constexpr uint8_t AXP2101_ADDR = 0x34;
constexpr uint8_t TCA9554_ADDR = 0x20;
constexpr uint8_t CST9217_ADDR = 0x5A;
constexpr uint8_t FT3168_ADDR = 0x38;
constexpr uint8_t PCF85063_ADDR = 0x51;
constexpr uint8_t QMI8658_ADDR_PRIMARY = 0x6B;
constexpr uint8_t QMI8658_ADDR_FALLBACK = 0x6A;

void recoverI2CBus();
void initializePowerManagement();

} // namespace waveshare_board

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
