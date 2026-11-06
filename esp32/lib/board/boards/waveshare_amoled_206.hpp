#pragma once

#include <cstdint>

// Waveshare ESP32-S3-Touch-AMOLED-2.06: data only, no logic. Pin numbers are
// GPIO numbers from the vendor schematic; hardware/README.md is the source.
// Values here must stay identical to the pins that include/hal.hpp exposed
// before this file existed; tools/tests/test_board_touch_wake_pins.cpp and
// tools/tests/test_ride_diagnostics_storage_contract.py check the wake and
// storage pins.
namespace board {

// Value of an optional pin that this board does not route to a GPIO.
constexpr uint8_t noPin = 0xFF;

namespace identity {
constexpr const char *target = "WAVESHARE_AMOLED_206";
constexpr bool amoled = true;
constexpr bool epaper = false;
}  // namespace identity

namespace display {
constexpr uint16_t width = 410;
constexpr uint16_t height = 502;
constexpr bool round = false;
constexpr bool touch = true;
constexpr bool brightness = true;
// CO5300 over QSPI.
constexpr uint8_t cs = 12;
constexpr uint8_t clk = 11;
constexpr uint8_t reset = 8;
constexpr uint8_t d0 = 4;
constexpr uint8_t d1 = 5;
constexpr uint8_t d2 = 6;
constexpr uint8_t d3 = 7;
}  // namespace display

namespace i2c {
// Shared by the AXP2101, FT3168, RTC and IMU.
constexpr uint8_t sda = 15;
constexpr uint8_t scl = 14;
}  // namespace i2c

namespace touch {
// FT3168.
constexpr uint8_t address = 0x38;
constexpr uint8_t interrupt = 38;
constexpr bool resetOnGpio = true;
constexpr uint8_t reset = 9;
}  // namespace touch

namespace buttons {
constexpr uint8_t boot = 0;
}  // namespace buttons

namespace sd {
// Vendor-native one-bit SDMMC; the SPI CS/D3 traces are unused in that mode.
constexpr uint8_t clk = 2;
constexpr uint8_t cmd = 1;
constexpr uint8_t d0 = 3;
// Former HSPI pins, kept only for the migration-only SPI compatibility path.
constexpr uint8_t legacySpiCs = 17;
constexpr uint8_t legacySpiMosi = 1;
constexpr uint8_t legacySpiMiso = 3;
constexpr uint8_t legacySpiClk = 2;
}  // namespace sd

namespace power {
constexpr bool axp2101 = true;
// This board's PMIC policy allows only the display-enable recovery bit;
// capture_boot.py gates it with --require-pmic-display-enable-only.
constexpr bool qualifiedPowerControl = true;
}  // namespace power

namespace gnss {
// UART pads only; no module is populated on this model.
constexpr bool fitted = false;
constexpr uint8_t tx = 43;
constexpr uint8_t rx = 44;
}  // namespace gnss

namespace memory {
constexpr uint32_t flashBytes = 16u * 1024u * 1024u;
constexpr uint32_t psramBytes = 8u * 1024u * 1024u;
}  // namespace memory

}  // namespace board
