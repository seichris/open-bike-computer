/**
 * @file pcf85063.hpp
 * @brief PCF85063 RTC helper for the Waveshare AMOLED board.
 */

#pragma once

#ifdef WAVESHARE_AMOLED_175

#include <Arduino.h>
#include <time.h>

namespace waveshare_board::rtc {

enum class TimeSource : uint8_t {
  Unknown,
  RTC,
  BLE,
};

struct Status {
  bool present = false;
  bool timeValid = false;
  TimeSource source = TimeSource::Unknown;
  time_t unixTime = 0;
};

bool begin();
bool restoreSystemTimeFromRtc();
bool syncFromUnixTime(time_t unixTime, const char *source);
const Status &status();
const char *sourceName(TimeSource source);

} // namespace waveshare_board::rtc

#endif // WAVESHARE_AMOLED_175
