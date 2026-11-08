#pragma once

// Waveshare ESP32-S3-Touch-AMOLED-1.75 as sold: the shared 1.75 data with no
// GNSS receiver fitted. The variant with the receiver populated is
// waveshare_amoled_175_gnss.hpp; everything electrical that the two share
// lives in waveshare_amoled_175_common.hpp.
#include "waveshare_amoled_175_common.hpp"

namespace board {

namespace identity {
constexpr const char *target = "WAVESHARE_AMOLED_175";
constexpr bool amoled = true;
constexpr bool epaper = false;
}  // namespace identity

namespace gnss {
// No receiver is populated on this model. The RXD/TXD pads of the H2 header
// are the ESP32-S3 UART0 pins (GPIO43/44), not a receiver footprint; the
// vendor schematic's Q1 footprint for a Quectel LC76G reaches GPIO18 and
// GPIO17 through the unfitted link resistors R15 and R16, and its RESET line
// through expander pin EXIO7. The fitted variant's board file sets these.
constexpr bool fitted = false;
constexpr GnssModule module = GnssModule::none;
// ESP32-S3 UART controller, and the pins as seen from the ESP32: rx is the
// receiver's TXD, tx is the receiver's RXD.
constexpr uint8_t uart = 2;
constexpr uint8_t rx = noPin;
constexpr uint8_t tx = noPin;
constexpr uint32_t baud = 0;
// Receiver RESET through a TCA9554 expander pin, or no reset control.
constexpr bool resetViaExpander = false;
constexpr uint8_t resetExpanderPin = 0;
}  // namespace gnss

}  // namespace board

// Whether the position-source part compiles its GNSS receiver implementation.
// Keep it equal to board::gnss::fitted.
#define BOARD_GNSS_FITTED 0
static_assert((BOARD_GNSS_FITTED != 0) == board::gnss::fitted,
              "GNSS macro and board data disagree");
