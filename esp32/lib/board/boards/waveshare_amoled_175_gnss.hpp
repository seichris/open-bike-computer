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
// Quectel LC76G (LC76GABMD) populated on the vendor Q1 footprint: the "-G"
// model (ESP32-S3-Touch-AMOLED-1.75-G, SKU 31264) with its ceramic antenna.
// The ESP32 reaches the receiver over the shared I2C bus: Waveshare's
// hardware reference and LC76G example poll the receiver's I2C slave at
// 0x50 (requests) and 0x54 (answers), and the schematic's UART links from
// the receiver's TXD1/RXD1 to GPIO18/17 (R15/R16) stay unfitted on this
// model too; the bench unit's receive pin floats. RESET is expander pin
// EXIO7 (active low), VCC the 3.3 V rail, V_BCKP the RTC rail; 1PPS, STANDBY
// and FORCE_ON are not connected. No PMIC write is involved, so this variant
// keeps the 1.75 read-only PMIC policy and gate.
constexpr bool fitted = true;
constexpr GnssModule module = GnssModule::quectelLc76g;
constexpr GnssTransport transport = GnssTransport::i2c;
// Seven-bit addresses of the receiver's I2C slave: requests are written to
// the command address, their answers read from the data address.
constexpr uint8_t i2cCommandAddress = 0x50;
constexpr uint8_t i2cDataAddress = 0x54;
// The optional UART path, unused while R15/R16 are unfitted: the ESP32-S3
// UART controller and the pins as seen from the ESP32 (rx is the receiver's
// TXD, tx the receiver's RXD); 115200 bps is the receiver's default rate.
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
static_assert(board::gnss::fitted ==
                  (board::gnss::transport != board::GnssTransport::none),
              "a fitted receiver needs a transport and an unfitted one none");
