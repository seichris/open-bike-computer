#pragma once

#include <cstdint>

// Waveshare ESP32-S3 3.97-inch e-paper: data only, no logic. Pin numbers are
// GPIO numbers from the vendor schematic. The values used to live in
// include/board_traits.hpp, which now aliases this file. The panel is a
// 480x800 SSD1677 over SPI; no touch controller and no brightness control
// are fitted, and the AXP2101 is written only for the panel's ALDO3 rail.
namespace board {

// Value of an optional pin that this board does not route to a GPIO.
constexpr uint8_t noPin = 0xFF;

namespace identity {
constexpr const char *target = "WAVESHARE_EPAPER_397";
constexpr bool amoled = false;
constexpr bool epaper = true;
}  // namespace identity

namespace epd {
// SSD1677 panel over SPI.
constexpr uint8_t clock = 11;
constexpr uint8_t mosi = 12;
constexpr uint8_t cs = 10;
constexpr uint8_t dc = 9;
constexpr uint8_t reset = 46;
constexpr uint8_t busy = 3;
}  // namespace epd

namespace display {
constexpr uint16_t width = 480;
constexpr uint16_t height = 800;
constexpr bool round = false;
constexpr bool touch = false;
constexpr bool brightness = false;
// The shared pin names expect the CO5300 QSPI set; only the SPI subset exists
// here, and the AMOLED panel driver is never compiled for this target.
constexpr uint8_t cs = epd::cs;
constexpr uint8_t clk = epd::clock;
constexpr uint8_t reset = epd::reset;
constexpr uint8_t d0 = epd::mosi;
constexpr uint8_t d1 = noPin;
constexpr uint8_t d2 = noPin;
constexpr uint8_t d3 = noPin;
// No CO5300 panel gap, and the firmware starts unrotated without offering the
// 90-degree rotation.
constexpr uint8_t columnOffset = 0;
constexpr uint8_t defaultRotation = 0;
constexpr bool rotation90Enabled = false;
// 1-bit panel: map features draw black on white and areas are hatched; a
// waveform takes seconds, so nothing animates.
constexpr bool monochrome = true;
constexpr bool animations = false;
}  // namespace display

namespace i2c {
// Shared by the AXP2101, RTC and IMU.
constexpr uint8_t sda = 41;
constexpr uint8_t scl = 42;
// Register reads use a repeated start between the address write and the read,
// and a failed transaction never resets or reconfigures the bus.
constexpr bool stopBetweenWriteAndRead = false;
constexpr bool recoverOnFailure = false;
// Configure Wire directly at boot; the bus is never bit-banged.
constexpr bool recoverAtBoot = false;
}  // namespace i2c

namespace touch {
// No touch controller is fitted.
constexpr uint8_t address = 0x00;
constexpr uint8_t interrupt = noPin;
constexpr bool resetOnGpio = false;
constexpr uint8_t reset = noPin;
constexpr bool ext1WakeSource = false;
constexpr bool wakePolling = false;
constexpr bool multiTouch = false;
}  // namespace touch

namespace buttons {
constexpr uint8_t boot = 0;
// The three side keys read by lib/board_input.
constexpr uint8_t up = 4;
constexpr uint8_t center = 5;
constexpr uint8_t down = 6;
}  // namespace buttons

namespace sd {
// Vendor-native one-bit SDMMC.
constexpr uint8_t clk = 16;
constexpr uint8_t cmd = 17;
constexpr uint8_t d0 = 15;
// This board never carried the former HSPI layout: with no chip select the
// migration-only SPI compatibility path in lib/storage is skipped.
constexpr uint8_t legacySpiCs = noPin;
constexpr uint8_t legacySpiMosi = cmd;
constexpr uint8_t legacySpiMiso = d0;
constexpr uint8_t legacySpiClk = clk;
}  // namespace sd

namespace power {
constexpr bool axp2101 = true;
// The PMIC policy is e-paper-ALDO3-only (see axp2101.cpp); the AMOLED
// read-only and display-enable gates of capture_boot.py do not apply, and
// whole-board sleep/wake (the disconnected shutdown) stays behind the
// physical hardware gate.
constexpr bool qualifiedPowerControl = false;
constexpr bool displayEnableRecovery = false;
}  // namespace power

namespace audio {
// ES8311 codec over I2S with the amplifier enable.
constexpr uint8_t mclk = 13;
constexpr uint8_t bclk = 14;
constexpr uint8_t lrck = 47;
constexpr uint8_t out = 48;
constexpr uint8_t in = 21;
constexpr uint8_t enable = 39;
}  // namespace audio

namespace wifi {
// Transfer Wi-Fi is prepared on first use, not before BLE.
constexpr bool prepareBeforeBle = false;
}  // namespace wifi

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

namespace layout {
// The settings defaults the e-paper used before this file existed (the
// 1.75-inch values). Presentation data; M4 may move it with the screens.
constexpr uint16_t compassY = 80;
constexpr uint16_t coordY = 30;
constexpr uint16_t altitudeX = 8;
constexpr uint16_t altitudeBottomInset = 170;
constexpr uint16_t speedX = 1;
constexpr uint16_t speedBottomInset = 130;
constexpr uint16_t sunX = 170;
constexpr uint16_t sunBottomInset = 170;
// Map screen geometry read by gui_layout: the UI space reserved below a
// non-fullscreen map, the anchor of the rider inside the map viewport, and
// the toolbar button offsets.
constexpr uint16_t mapNonFullscreenReservedHeight = 100;
constexpr uint8_t mapAnchorXPercent = 50;
constexpr uint8_t mapAnchorYPercent = 50;
constexpr uint8_t mapToolbarOffset = 80;
constexpr uint8_t mapToolbarSpace = 50;
constexpr uint8_t mapToolbarInset = 10;
constexpr uint8_t mapToolbarFullscreenBottomMargin = 24;
}  // namespace layout

}  // namespace board

// Preprocessor-visible capability for code that must not exist on boards
// without it (PMIC write paths). Keep it equal to board::power.
#define BOARD_PMIC_DISPLAY_ENABLE_RECOVERY 0
static_assert(BOARD_PMIC_DISPLAY_ENABLE_RECOVERY == board::power::displayEnableRecovery,
              "capability macro and board data disagree");
