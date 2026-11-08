#pragma once

// Waveshare ESP32-S3-Touch-AMOLED-1.75 with the GNSS receiver populated: the
// shared 1.75 data from waveshare_amoled_175_common.hpp plus the receiver.
// Its own firmware target, OTA identity, CI matrix and physical gates; see
// hardware/README.md and docs/plans/board-support-architecture-plan.md (M6).
#include "waveshare_amoled_175_common.hpp"

namespace board {

namespace identity {
constexpr const char *target = "WAVESHARE_AMOLED_175_GNSS";
constexpr bool amoled = true;
constexpr bool epaper = false;
}  // namespace identity

namespace gnss {
// Quectel LC76G (LC76GABMD) populated on the vendor Q1 footprint. From the
// 1.75 schematic: the receiver's TXD1 reaches GPIO18 through R15 and its
// RXD1 GPIO17 through R16 (both links fitted on this variant), its RESET is
// expander pin EXIO7 (active low), VCC is the 3.3 V rail, V_BCKP the RTC
// rail, STANDBY and FORCE_ON are not connected. The receiver speaks NMEA
// 0183 over UART; its default rate is 115200 bps and the position-source
// part probes 9600 bps as well. No PMIC write is involved, so this variant
// keeps the 1.75 read-only PMIC policy and gate.
constexpr bool fitted = true;
constexpr GnssModule module = GnssModule::quectelLc76g;
// ESP32-S3 UART controller, and the pins as seen from the ESP32: rx is the
// receiver's TXD, tx is the receiver's RXD.
constexpr uint8_t uart = 2;
constexpr uint8_t rx = 18;
constexpr uint8_t tx = 17;
constexpr uint32_t baud = 115200;
constexpr bool resetViaExpander = true;
constexpr uint8_t resetExpanderPin = 7;
}  // namespace gnss

}  // namespace board

// Whether the position-source part compiles its GNSS receiver implementation.
// Keep it equal to board::gnss::fitted.
#define BOARD_GNSS_FITTED 1
static_assert((BOARD_GNSS_FITTED != 0) == board::gnss::fitted,
              "GNSS macro and board data disagree");
