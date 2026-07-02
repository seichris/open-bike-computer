/**
 * @file touch.hpp
 * @brief Touch constants for Waveshare AMOLED boards.
 */

#pragma once

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "waveshare_board.hpp"
#include <Arduino.h>
#include <hal.hpp>

namespace waveshare_board::touch {

constexpr uint8_t TCA9554_OUTPUT_REG = 0x01;
constexpr uint8_t TCA9554_CONFIG_REG = 0x03;
constexpr uint8_t TCA9554_TOUCH_RST_BIT = 0;

constexpr uint8_t CST9217_ADDR = waveshare_board::CST9217_ADDR;
constexpr uint8_t FT3168_ADDR = waveshare_board::FT3168_ADDR;
constexpr uint8_t CST9217_INT_PIN = TCH_I2C_INT;
constexpr uint16_t CST9217_DATA_REG = 0xD000;
constexpr uint8_t CST9217_ACK = 0xAB;
constexpr uint8_t CST9217_DATA_LENGTH = 10;

#ifdef WAVESHARE_AMOLED_206
constexpr uint8_t FT3168_INT_PIN = TCH_I2C_INT;
constexpr uint8_t FT3168_RST_PIN = TCH_I2C_RST;
constexpr uint8_t FT3168_FINGER_REG = 0x02;
constexpr uint8_t FT3168_TOUCH_DATA_LENGTH = 5;
constexpr uint8_t FT3168_POWER_MODE_REG = 0xA5;
constexpr uint8_t FT3168_MONITOR_MODE = 0x01;
constexpr uint8_t FT3168_DEVICE_ID_REG = 0xA0;
constexpr uint16_t ACTIVE_WIDTH = 410;
constexpr uint16_t ACTIVE_HEIGHT = 502;
#else
constexpr uint16_t ACTIVE_WIDTH = 466;
constexpr uint16_t ACTIVE_HEIGHT = 466;
#endif
constexpr uint16_t MAX_X = ACTIVE_WIDTH - 1;
constexpr uint16_t MAX_Y = ACTIVE_HEIGHT - 1;

constexpr uint32_t HINT_ACTIVE_READ_INTERVAL_MS = 20;
constexpr uint32_t ACTIVE_READ_INTERVAL_MS = 25;
constexpr uint32_t RECENT_HINT_READ_INTERVAL_MS = 25;
constexpr uint32_t FAST_FALLBACK_READ_INTERVAL_MS = 40;
constexpr uint32_t IDLE_FALLBACK_READ_INTERVAL_MS = 400;
constexpr uint32_t HINT_FAST_POLL_WINDOW_MS = 700;
constexpr uint32_t TOUCH_FAST_POLL_WINDOW_MS = 700;
constexpr uint32_t ACTIVE_FAILURE_GRACE_MS = 600;
constexpr uint32_t IDLE_FAILURE_BASE_RETRY_MS = 100;
constexpr uint32_t IDLE_FAILURE_MAX_RETRY_MS = 700;
constexpr uint32_t REINIT_BACKOFF_MS = 1200;

} // namespace waveshare_board::touch

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
