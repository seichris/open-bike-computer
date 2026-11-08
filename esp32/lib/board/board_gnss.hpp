#pragma once

#include <cstdint>

// GNSS receivers a board may carry and how the ESP32 reaches them. The
// position-source part selects the receiver's protocol and initialization by
// these values; boards without a receiver keep board::gnss::fitted false,
// GnssModule::none and GnssTransport::none.
namespace board {

enum class GnssModule : uint8_t {
  none = 0,
  // Quectel LC76G (LC76GABMD): multi-constellation receiver speaking NMEA
  // 0183, powered from the 3.3 V rail with RTC-rail backup. It offers the
  // sentence stream on a UART and on an I2C slave; the board data says which
  // one is wired.
  quectelLc76g = 1,
};

enum class GnssTransport : uint8_t {
  none = 0,
  // The receiver's TXD/RXD reach ESP32 pins: NMEA on a UART whose rate the
  // position-source part probes.
  uart = 1,
  // The receiver's I2C slave on the shared bus: the position-source part
  // polls it with Quectel's command/answer scheme (a request written to the
  // command address, its answer read from the data address).
  i2c = 2,
};

}  // namespace board
