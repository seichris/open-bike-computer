/**
 * @file hal.hpp
 * @brief Board pin names kept for existing code.
 *
 * The values live in the selected board definition under lib/board/boards/.
 * New code reads board:: directly; these names remain until their users move.
 */

#pragma once

#include "../lib/board/board.hpp"

// I2C bus shared by the PMIC, touch controller, RTC and IMU.
#define I2C_SDA_PIN (static_cast<gpio_num_t>(board::i2c::sda))
#define I2C_SCL_PIN (static_cast<gpio_num_t>(board::i2c::scl))

// GPS UART pads; the values are defined beside the panel driver.
extern uint8_t GPS_TX;
extern uint8_t GPS_RX;

constexpr uint8_t BOARD_BOOT_PIN = board::buttons::boot;

// Display pins (CO5300 QSPI driver).
constexpr uint8_t TFT_QSPI_CS = board::display::cs;
constexpr uint8_t TFT_QSPI_CLK = board::display::clk;
constexpr uint8_t TFT_QSPI_RST = board::display::reset;
constexpr uint8_t TFT_QSPI_D0 = board::display::d0;
constexpr uint8_t TFT_QSPI_D1 = board::display::d1;
constexpr uint8_t TFT_QSPI_D2 = board::display::d2;
constexpr uint8_t TFT_QSPI_D3 = board::display::d3;

// Touch controller on the shared I2C bus.
constexpr uint8_t TCH_I2C_SDA = board::i2c::sda;
constexpr uint8_t TCH_I2C_SCL = board::i2c::scl;
constexpr uint8_t TCH_I2C_INT = board::touch::interrupt;
constexpr uint8_t TCH_I2C_ADDR = board::touch::address;
// A GPIO only where board::touch::resetOnGpio is true; the 1.75 resets its
// controller through the TCA9554 expander and routes no pin here.
constexpr uint8_t TCH_I2C_RST = board::touch::reset;

// microSD in vendor-native one-bit SDMMC mode.
constexpr uint8_t WAVESHARE_SDMMC_CLK = board::sd::clk;
constexpr uint8_t WAVESHARE_SDMMC_CMD = board::sd::cmd;
constexpr uint8_t WAVESHARE_SDMMC_D0 = board::sd::d0;

// Migration-only SPI compatibility path on the former HSPI pins.
constexpr uint8_t WAVESHARE_LEGACY_SD_CS = board::sd::legacySpiCs;
constexpr uint8_t WAVESHARE_LEGACY_SD_MOSI = board::sd::legacySpiMosi;
constexpr uint8_t WAVESHARE_LEGACY_SD_MISO = board::sd::legacySpiMiso;
constexpr uint8_t WAVESHARE_LEGACY_SD_CLK = board::sd::legacySpiClk;
