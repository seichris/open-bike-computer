#pragma once

#include <cstdint>

#include "../board_gnss.hpp"

// Waveshare ESP32-S3-Touch-AMOLED-1.75, the data shared by the plain board
// and its GNSS variant: no logic. Pin numbers are
// GPIO numbers from the vendor schematic; hardware/README.md is the source.
// Values here must stay identical to the pins that include/hal.hpp exposed
// before this file existed; tools/tests/test_board_touch_wake_pins.cpp and
// tools/tests/test_ride_diagnostics_storage_contract.py check the wake and
// storage pins.
namespace board {

// Value of an optional pin that this board does not route to a GPIO.
constexpr uint8_t noPin = 0xFF;

namespace display {
constexpr uint16_t width = 466;
constexpr uint16_t height = 466;
constexpr bool round = true;
constexpr bool touch = true;
constexpr bool brightness = true;
// CO5300 over QSPI.
constexpr uint8_t cs = 12;
constexpr uint8_t clk = 38;
constexpr uint8_t reset = 39;
constexpr uint8_t d0 = 4;
constexpr uint8_t d1 = 5;
constexpr uint8_t d2 = 6;
constexpr uint8_t d3 = 7;
// Arduino_CO5300 panel gap (column offset 1) from the vendor examples.
constexpr uint8_t columnOffset = 6;
// waveshare_board::display rotation index the firmware starts with, and
// whether the 90-degree rotation is offered on this panel.
constexpr uint8_t defaultRotation = 1;
constexpr bool rotation90Enabled = true;
// RGB565 colour panel that animates at the LVGL frame rate.
constexpr bool monochrome = false;
constexpr bool animations = true;
}  // namespace display

namespace i2c {
// Shared by the AXP2101, CST9217, TCA9554, RTC and IMU.
constexpr uint8_t sda = 15;
constexpr uint8_t scl = 14;
// Whether a register read sends a stop condition between the address write
// and the read (the CST9217 path) or uses a repeated start (the FT3168 path),
// and whether a failed transaction resets and reconfigures the bus.
constexpr bool stopBetweenWriteAndRead = true;
constexpr bool recoverOnFailure = false;
// Configure Wire directly at boot; never preemptively bit-bang the shared bus
// before PMIC inspection (the 2.06 does).
constexpr bool recoverAtBoot = false;
}  // namespace i2c

namespace touch {
// CST9217. The vendor schematic routes TP_INT to GPIO11; GPIO21 is the
// QMI8658 INT2 net and would silently lose touch events when idle polling is
// disabled. Reset runs through the TCA9554 expander (0x20), not a GPIO.
constexpr uint8_t address = 0x5A;
constexpr uint8_t interrupt = 11;
constexpr bool resetOnGpio = false;
constexpr uint8_t reset = noPin;
// GPIO11 is an RTC GPIO, so TP_INT joins BOOT in the EXT1 light-sleep wake
// mask. While the display is dimmed or off the CST9217 reader keeps polling
// and a low TP_INT level counts as a wake request, because the latched edge
// alone cannot restore the UI.
constexpr bool ext1WakeSource = true;
constexpr bool wakePolling = true;
// The CST9217 reports two contacts; the standalone Map uses the second one
// for pinch zoom and the idle zoom-out backdrop.
constexpr bool multiTouch = true;
}  // namespace touch

namespace buttons {
constexpr uint8_t boot = 0;
// No side keys: BOOT and the PMIC PWR key confirm pairing.
constexpr uint8_t up = noPin;
constexpr uint8_t center = noPin;
constexpr uint8_t down = noPin;
}  // namespace buttons

namespace sd {
// Vendor-native one-bit SDMMC; the SPI CS/D3 traces are unused in that mode.
constexpr uint8_t clk = 2;
constexpr uint8_t cmd = 1;
constexpr uint8_t d0 = 3;
// Former HSPI pins, kept only for the migration-only SPI compatibility path.
constexpr uint8_t legacySpiCs = 41;
constexpr uint8_t legacySpiMosi = 1;
constexpr uint8_t legacySpiMiso = 3;
constexpr uint8_t legacySpiClk = 2;
}  // namespace sd

namespace power {
constexpr bool axp2101 = true;
// This board's PMIC policy is read-only; capture_boot.py gates it with
// --require-pmic-read-only.
constexpr bool qualifiedPowerControl = true;
// One-way display-enable recovery (AXP2101 register 0x90 bit 0x80) is
// qualified on the 2.06 only; see BOARD_PMIC_DISPLAY_ENABLE_RECOVERY below.
constexpr bool displayEnableRecovery = false;
}  // namespace power

namespace wifi {
// Allocate the resident transfer Wi-Fi resources before BLE: a first transfer
// after a ride found enough total RAM but no 32 KiB contiguous block on this
// board. The 2.06 keeps its original startup order until qualified.
constexpr bool prepareBeforeBle = true;
}  // namespace wifi

namespace memory {
constexpr uint32_t flashBytes = 16u * 1024u * 1024u;
constexpr uint32_t psramBytes = 8u * 1024u * 1024u;
}  // namespace memory

namespace layout {
// Default positions of the stock main-screen widgets on this panel, read by
// the settings defaults. Presentation data; M4 may move it with the screens.
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
