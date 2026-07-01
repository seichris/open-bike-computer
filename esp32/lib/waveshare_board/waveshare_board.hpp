/**
 * @file waveshare_board.hpp
 * @brief Waveshare ESP32-S3 Touch AMOLED 1.75 board helpers.
 */

#pragma once

#ifdef WAVESHARE_AMOLED_175

#include <Arduino.h>

namespace waveshare_board {

constexpr uint8_t AXP2101_ADDR = 0x34;
constexpr uint8_t TCA9554_ADDR = 0x20;
constexpr uint8_t CST9217_ADDR = 0x5A;
constexpr uint8_t PCF85063_ADDR = 0x51;
constexpr uint8_t QMI8658_ADDR_PRIMARY = 0x6B;
constexpr uint8_t QMI8658_ADDR_FALLBACK = 0x6A;

constexpr uint8_t AXP2101_DLDO1_REG = 0x90;
constexpr uint8_t AXP2101_ALDO1_REG = 0x92;
constexpr uint8_t AXP2101_ALDO2_REG = 0x93;
constexpr uint8_t AXP2101_ALDO3_REG = 0x94;
constexpr uint8_t AXP2101_ALDO4_REG = 0x95;
constexpr uint8_t AXP2101_BLDO1_REG = 0x96;
constexpr uint8_t AXP2101_BLDO2_REG = 0x97;
constexpr uint8_t AXP2101_LDO_3V3 = 0x1C;
constexpr uint8_t AXP2101_LDO_3V3_ENABLED = 0x9C;

void recoverI2CBus();
void enablePowerRails();

} // namespace waveshare_board

#endif // WAVESHARE_AMOLED_175
