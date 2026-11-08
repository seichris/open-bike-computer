#pragma once

#include <cstdint>

// GNSS receivers a board may carry. The position-source part selects the
// receiver's serial protocol and initialization by this value; boards without
// a receiver keep board::gnss::fitted false and GnssModule::none.
namespace board {

enum class GnssModule : uint8_t {
  none = 0,
  // Quectel LC76G (LC76GABMD): multi-constellation receiver speaking NMEA
  // 0183 over UART, powered from the 3.3 V rail with RTC-rail backup.
  quectelLc76g = 1,
};

}  // namespace board
