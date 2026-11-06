/**
 * @file hal.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Boards Pin definitions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

/**
 * @brief TFT Invert color
 *
 */
constexpr bool TFT_INVERT = true;

/**
 * @brief WAVESHARE ESP32-S3 AMOLED pin definitions.
 * Corrected from official Waveshare schematics/examples.
 */
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
// I2C Bus (Shared by AXP2101, CST9217, TCA9554, RTC, IMU)
#define I2C_SDA_PIN GPIO_NUM_15
#define I2C_SCL_PIN GPIO_NUM_14

// GPS UART
extern uint8_t GPS_TX;
extern uint8_t GPS_RX;

constexpr uint8_t BOARD_BOOT_PIN = GPIO_NUM_0;

// Display Pins (CO5300 QSPI Driver)
constexpr uint8_t TFT_QSPI_CS = GPIO_NUM_12;
#ifdef WAVESHARE_AMOLED_206
constexpr uint8_t TFT_QSPI_CLK = GPIO_NUM_11;
constexpr uint8_t TFT_QSPI_RST = GPIO_NUM_8;
#else
constexpr uint8_t TFT_QSPI_CLK = GPIO_NUM_38;
constexpr uint8_t TFT_QSPI_RST = GPIO_NUM_39;
#endif
constexpr uint8_t TFT_QSPI_D0 = GPIO_NUM_4;
constexpr uint8_t TFT_QSPI_D1 = GPIO_NUM_5;
constexpr uint8_t TFT_QSPI_D2 = GPIO_NUM_6;
constexpr uint8_t TFT_QSPI_D3 = GPIO_NUM_7;

// Touch Pins on shared I2C bus.
constexpr uint8_t TCH_I2C_SDA = GPIO_NUM_15;
constexpr uint8_t TCH_I2C_SCL = GPIO_NUM_14; // Same as main I2C bus
#ifdef WAVESHARE_AMOLED_206
constexpr uint8_t TCH_I2C_INT = GPIO_NUM_38;
constexpr uint8_t TCH_I2C_RST = GPIO_NUM_9;
constexpr uint8_t TCH_I2C_ADDR = 0x38; // FT3168 Address
#else
// Vendor schematic: TP_INT is GPIO11. GPIO21 is the QMI8658 INT2 net;
// using it here silently loses touch events when idle polling is disabled.
constexpr uint8_t TCH_I2C_INT = GPIO_NUM_11;
// NOTE: Touch Reset is controlled by TCA9554 I/O Expander (0x20), NOT a GPIO!
// Do NOT use GPIO 20 - it is USB D+ and will break serial monitor.
constexpr uint8_t TCH_I2C_ADDR = 0x5A; // CST9217 Address (verified)
#endif

// microSD in vendor-native one-bit SDMMC mode. Both Waveshare boards route
// the same CLK/CMD/D0 pins; their SPI CS/D3 traces are unused in one-bit mode.
constexpr uint8_t WAVESHARE_SDMMC_CLK = GPIO_NUM_2;
constexpr uint8_t WAVESHARE_SDMMC_CMD = GPIO_NUM_1;
constexpr uint8_t WAVESHARE_SDMMC_D0 = GPIO_NUM_3;

// Temporary migration-only SPI compatibility path. These are the former HSPI
// pins; normal steady-state storage must use the native SDMMC constants above.
#ifdef WAVESHARE_AMOLED_206
constexpr uint8_t WAVESHARE_LEGACY_SD_CS = GPIO_NUM_17;
#else
constexpr uint8_t WAVESHARE_LEGACY_SD_CS = GPIO_NUM_41;
#endif
constexpr uint8_t WAVESHARE_LEGACY_SD_MOSI = GPIO_NUM_1;
constexpr uint8_t WAVESHARE_LEGACY_SD_MISO = GPIO_NUM_3;
constexpr uint8_t WAVESHARE_LEGACY_SD_CLK = GPIO_NUM_2;
#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
