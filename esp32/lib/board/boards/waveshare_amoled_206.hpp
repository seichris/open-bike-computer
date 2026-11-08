#pragma once

#include <cstdint>

#include "../board_gnss.hpp"

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
// Arduino_CO5300 panel gap (column offset 1) from the vendor examples.
constexpr uint8_t columnOffset = 22;
// waveshare_board::display rotation index the firmware starts with, and
// whether the 90-degree rotation is offered on this panel.
constexpr uint8_t defaultRotation = 0;
constexpr bool rotation90Enabled = false;
// RGB565 colour panel that animates at the LVGL frame rate.
constexpr bool monochrome = false;
constexpr bool animations = true;
}  // namespace display

namespace i2c {
// Shared by the AXP2101, FT3168, RTC and IMU.
constexpr uint8_t sda = 15;
constexpr uint8_t scl = 14;
// Whether a register read sends a stop condition between the address write
// and the read (the CST9217 path) or uses a repeated start (the FT3168 path),
// and whether a failed transaction resets and reconfigures the bus.
constexpr bool stopBetweenWriteAndRead = false;
constexpr bool recoverOnFailure = true;
// Bit-bang the shared bus free before PMIC inspection, which may write the
// display-enable bit.
constexpr bool recoverAtBoot = true;
}  // namespace i2c

namespace touch {
// FT3168.
constexpr uint8_t address = 0x38;
constexpr uint8_t interrupt = 38;
constexpr bool resetOnGpio = true;
constexpr uint8_t reset = 9;
// GPIO38 is not an RTC GPIO, so TP_INT cannot be an EXT1 wake source; the
// FT3168 interrupt latches a wake reason while awake and idle reads stay
// interrupt-gated, with no polling while the display is dimmed or off.
constexpr bool ext1WakeSource = false;
constexpr bool wakePolling = false;
// The FT3168 path reports one contact; no pinch zoom.
constexpr bool multiTouch = false;
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
// One-way display-enable recovery (AXP2101 register 0x90 bit 0x80) is
// qualified on the 2.06 only; see BOARD_PMIC_DISPLAY_ENABLE_RECOVERY below.
constexpr bool displayEnableRecovery = true;
}  // namespace power

namespace wifi {
// The original startup order: transfer Wi-Fi is prepared on first use, not
// before BLE (the 1.75 does), until that is qualified here.
constexpr bool prepareBeforeBle = false;
}  // namespace wifi

namespace gnss {
// No receiver is populated on this model, and no receiver footprint has been
// verified against its schematic; the RXD/TXD header pads are the ESP32-S3
// UART0 pins (GPIO43/44).
constexpr bool fitted = false;
constexpr GnssModule module = GnssModule::none;
constexpr GnssTransport transport = GnssTransport::none;
constexpr uint8_t i2cCommandAddress = 0;
constexpr uint8_t i2cDataAddress = 0;
constexpr uint8_t uart = 2;
constexpr uint8_t rx = noPin;
constexpr uint8_t tx = noPin;
constexpr uint32_t baud = 0;
constexpr bool resetViaExpander = false;
constexpr uint8_t resetExpanderPin = 0;
}  // namespace gnss

namespace memory {
constexpr uint32_t flashBytes = 16u * 1024u * 1024u;
constexpr uint32_t psramBytes = 8u * 1024u * 1024u;
}  // namespace memory

namespace layout {
// Default positions of the stock main-screen widgets on this panel, read by
// the settings defaults. Presentation data; M4 may move it with the screens.
constexpr uint16_t compassY = 112;
constexpr uint16_t coordY = 42;
constexpr uint16_t altitudeX = 12;
constexpr uint16_t altitudeBottomInset = 148;
constexpr uint16_t speedX = 12;
constexpr uint16_t speedBottomInset = 104;
constexpr uint16_t sunX = 410 - 92;
constexpr uint16_t sunBottomInset = 154;
// Map screen geometry read by gui_layout: the UI space reserved below a
// non-fullscreen map, the anchor of the rider inside the map viewport, and
// the toolbar button offsets.
constexpr uint16_t mapNonFullscreenReservedHeight = 72;
constexpr uint8_t mapAnchorXPercent = 50;
constexpr uint8_t mapAnchorYPercent = 50;
constexpr uint8_t mapToolbarOffset = 92;
constexpr uint8_t mapToolbarSpace = 54;
constexpr uint8_t mapToolbarInset = 12;
constexpr uint8_t mapToolbarFullscreenBottomMargin = 30;
}  // namespace layout

}  // namespace board

// Preprocessor-visible capability for code that must not exist on boards
// without it (PMIC write paths). Keep it equal to board::power.
#define BOARD_PMIC_DISPLAY_ENABLE_RECOVERY 1
static_assert(BOARD_PMIC_DISPLAY_ENABLE_RECOVERY == board::power::displayEnableRecovery,
              "capability macro and board data disagree");
// Whether the position-source part compiles its GNSS receiver implementation.
// Keep it equal to board::gnss::fitted.
#define BOARD_GNSS_FITTED 0
static_assert((BOARD_GNSS_FITTED != 0) == board::gnss::fitted,
              "GNSS macro and board data disagree");
static_assert(board::gnss::fitted ==
                  (board::gnss::transport != board::GnssTransport::none),
              "a fitted receiver needs a transport and an unfitted one none");
