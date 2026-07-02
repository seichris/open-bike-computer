/**
 * @file pcf85063.cpp
 * @brief PCF85063 RTC helper for the Waveshare AMOLED board.
 */

#include "pcf85063.hpp"

#ifdef WAVESHARE_AMOLED_175

#include "i2c_bus.hpp"
#include "waveshare_board.hpp"
#include <sys/time.h>

namespace waveshare_board::rtc {

namespace {

constexpr uint8_t REG_CONTROL_1 = 0x00;
constexpr uint8_t REG_SECONDS = 0x04;
constexpr uint8_t REG_YEARS = 0x0A;
constexpr uint8_t CONTROL_1_STOP_BIT = 0x20;
constexpr uint8_t CONTROL_1_EXT_TEST_BIT = 0x80;
constexpr uint8_t SECONDS_VL_BIT = 0x80;
constexpr int64_t MIN_VALID_UNIX_TIME = 1704067200; // 2024-01-01T00:00:00Z
constexpr int64_t MAX_VALID_UNIX_TIME = 4102444800; // 2100-01-01T00:00:00Z

Status rtcStatus;

uint8_t bcdToDec(uint8_t value) {
  return ((value >> 4) * 10) + (value & 0x0F);
}

uint8_t decToBcd(uint8_t value) {
  return static_cast<uint8_t>(((value / 10) << 4) | (value % 10));
}

bool isLeapYear(int year) {
  return ((year % 4 == 0) && (year % 100 != 0)) || (year % 400 == 0);
}

uint8_t daysInMonth(int year, uint8_t month) {
  static const uint8_t days[] = {31, 28, 31, 30, 31, 30,
                                 31, 31, 30, 31, 30, 31};
  if (month == 2 && isLeapYear(year)) {
    return 29;
  }
  return days[month - 1];
}

// Howard Hinnant's civil calendar conversion, returning days since Unix epoch.
int64_t daysFromCivil(int year, unsigned month, unsigned day) {
  year -= month <= 2;
  const int era = (year >= 0 ? year : year - 399) / 400;
  const unsigned yoe = static_cast<unsigned>(year - era * 400);
  const unsigned doy =
      (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + static_cast<int>(doe) - 719468;
}

bool buildUnixTime(uint8_t yearOffset, uint8_t month, uint8_t day,
                   uint8_t hour, uint8_t minute, uint8_t second,
                   time_t &unixTime) {
  const int year = 2000 + yearOffset;
  if (year < 2024 || year >= 2100 || month < 1 || month > 12 || day < 1 ||
      day > daysInMonth(year, month) || hour > 23 || minute > 59 ||
      second > 59) {
    return false;
  }

  int64_t days = daysFromCivil(year, month, day);
  int64_t seconds = days * 86400LL + hour * 3600LL + minute * 60LL + second;
  if (seconds < MIN_VALID_UNIX_TIME || seconds >= MAX_VALID_UNIX_TIME) {
    return false;
  }

  unixTime = static_cast<time_t>(seconds);
  return true;
}

bool readRtcUnixTime(time_t &unixTime) {
  uint8_t regs[7] = {};
  if (!i2c::readRegisterBlock8(waveshare_board::PCF85063_ADDR, REG_SECONDS,
                               regs, sizeof(regs), "PCF85063 time")) {
    return false;
  }

  if (regs[0] & SECONDS_VL_BIT) {
    Serial.println("PCF85063: voltage-low flag set; RTC time invalid");
    return false;
  }

  const uint8_t second = bcdToDec(regs[0] & 0x7F);
  const uint8_t minute = bcdToDec(regs[1] & 0x7F);
  const uint8_t hour = bcdToDec(regs[2] & 0x3F);
  const uint8_t day = bcdToDec(regs[3] & 0x3F);
  const uint8_t month = bcdToDec(regs[5] & 0x1F);
  const uint8_t year = bcdToDec(regs[6]);

  bool valid = buildUnixTime(year, month, day, hour, minute, second, unixTime);
  if (!valid) {
    Serial.printf("PCF85063: invalid RTC registers %02X %02X %02X %02X %02X "
                  "%02X %02X\n",
                  regs[0], regs[1], regs[2], regs[3], regs[4], regs[5],
                  regs[6]);
  }
  return valid;
}

void setSystemTime(time_t unixTime) {
  timeval tv = {.tv_sec = unixTime, .tv_usec = 0};
  settimeofday(&tv, nullptr);
}

void logUtcTime(const char *prefix, time_t unixTime) {
  tm utc;
  gmtime_r(&unixTime, &utc);
  char buffer[24];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
  Serial.printf("PCF85063: %s %s\n", prefix, buffer);
}

bool setStopBit(bool stopped) {
  uint8_t control1 = 0;
  if (!i2c::readRegister8(waveshare_board::PCF85063_ADDR, REG_CONTROL_1,
                          control1, "PCF85063 ctrl1")) {
    return false;
  }

  uint8_t next = control1 & ~CONTROL_1_EXT_TEST_BIT;
  if (stopped) {
    next |= CONTROL_1_STOP_BIT;
  } else {
    next &= ~CONTROL_1_STOP_BIT;
  }

  if (next == control1) {
    return true;
  }

  return i2c::writeRegister8(waveshare_board::PCF85063_ADDR, REG_CONTROL_1,
                             next,
                             stopped ? "PCF85063 stop" : "PCF85063 start", 3);
}

bool writeRtcRegisters(const uint8_t regs[7]) {
  bool stopped = setStopBit(true);
  bool wroteTime =
      stopped &&
      i2c::writeRegisterBlock8(waveshare_board::PCF85063_ADDR, REG_SECONDS,
                               regs, 7, "PCF85063 time set", 3);
  if (wroteTime) {
    // Defensive write for the final calendar byte. The connected Waveshare
    // board accepted seconds through month while leaving year at 0x07 unless
    // the year register was written explicitly.
    wroteTime = i2c::writeRegister8(waveshare_board::PCF85063_ADDR, REG_YEARS,
                                    regs[6], "PCF85063 year set", 3);
  }
  bool restarted = setStopBit(false);

  return stopped && wroteTime && restarted;
}

} // namespace

const char *sourceName(TimeSource source) {
  switch (source) {
  case TimeSource::RTC:
    return "rtc";
  case TimeSource::BLE:
    return "ble";
  case TimeSource::Unknown:
  default:
    return "unknown";
  }
}

const Status &status() { return rtcStatus; }

bool begin() {
  rtcStatus.present =
      i2c::probe(waveshare_board::PCF85063_ADDR, "PCF85063", 3);
  if (!rtcStatus.present) {
    Serial.println("PCF85063: not found");
    return false;
  }

  uint8_t control1 = 0;
  if (i2c::readRegister8(waveshare_board::PCF85063_ADDR, REG_CONTROL_1,
                         control1, "PCF85063 ctrl1")) {
    if (control1 & CONTROL_1_STOP_BIT) {
      uint8_t running = control1 & ~CONTROL_1_STOP_BIT;
      i2c::writeRegister8(waveshare_board::PCF85063_ADDR, REG_CONTROL_1,
                          running, "PCF85063 start");
    }
  }

  Serial.println("PCF85063: found");
  return true;
}

bool restoreSystemTimeFromRtc() {
  if (!begin()) {
    return false;
  }

  time_t rtcTime = 0;
  constexpr uint8_t RESTORE_ATTEMPTS = 3;
  bool restored = false;
  for (uint8_t attempt = 1; attempt <= RESTORE_ATTEMPTS; attempt++) {
    if (readRtcUnixTime(rtcTime)) {
      restored = true;
      break;
    }

    if (attempt < RESTORE_ATTEMPTS) {
      Serial.printf("PCF85063: restore read attempt %u/%u failed\n", attempt,
                    RESTORE_ATTEMPTS);
      delay(20);
    }
  }

  if (!restored) {
    rtcStatus.timeValid = false;
    rtcStatus.source = TimeSource::Unknown;
    rtcStatus.unixTime = 0;
    Serial.println("PCF85063: no valid RTC time to restore");
    return false;
  }

  setSystemTime(rtcTime);
  rtcStatus.timeValid = true;
  rtcStatus.source = TimeSource::RTC;
  rtcStatus.unixTime = rtcTime;
  logUtcTime("restored system time from RTC:", rtcTime);
  return true;
}

bool syncFromUnixTime(time_t unixTime, const char *source) {
  int64_t unixSeconds = static_cast<int64_t>(unixTime);
  if (unixSeconds < MIN_VALID_UNIX_TIME || unixSeconds >= MAX_VALID_UNIX_TIME) {
    Serial.printf("PCF85063: rejected %s sync time %lld\n",
                  source ? source : "unknown",
                  static_cast<long long>(unixSeconds));
    return false;
  }

  if (!rtcStatus.present && !begin()) {
    return false;
  }

  tm utc;
  gmtime_r(&unixTime, &utc);
  uint8_t regs[7] = {
      decToBcd(static_cast<uint8_t>(utc.tm_sec)),
      decToBcd(static_cast<uint8_t>(utc.tm_min)),
      decToBcd(static_cast<uint8_t>(utc.tm_hour)),
      decToBcd(static_cast<uint8_t>(utc.tm_mday)),
      decToBcd(static_cast<uint8_t>(utc.tm_wday)),
      decToBcd(static_cast<uint8_t>(utc.tm_mon + 1)),
      decToBcd(static_cast<uint8_t>((utc.tm_year + 1900) - 2000)),
  };

  constexpr uint8_t SYNC_ATTEMPTS = 3;
  for (uint8_t attempt = 1; attempt <= SYNC_ATTEMPTS; attempt++) {
    if (!writeRtcRegisters(regs)) {
      Serial.printf("PCF85063: sync write attempt %u/%u failed from %s\n",
                    attempt, SYNC_ATTEMPTS, source ? source : "unknown");
      delay(20);
      continue;
    }

    delay(20);
    time_t readBack = 0;
    if (readRtcUnixTime(readBack) &&
        llabs(static_cast<long long>(readBack) -
              static_cast<long long>(unixTime)) <= 2) {
      setSystemTime(unixTime);
      rtcStatus.timeValid = true;
      rtcStatus.source = TimeSource::BLE;
      rtcStatus.unixTime = unixTime;
      char logPrefix[80];
      snprintf(logPrefix, sizeof(logPrefix), "synced RTC from %s:",
               source ? source : "unknown");
      logUtcTime(logPrefix, unixTime);
      return true;
    }

    Serial.printf("PCF85063: sync readback attempt %u/%u failed from %s\n",
                  attempt, SYNC_ATTEMPTS, source ? source : "unknown");
    delay(20);
  }

  setStopBit(false);
  Serial.printf("PCF85063: failed %s readback after sync\n",
                source ? source : "unknown");
  return false;
}

} // namespace waveshare_board::rtc

#endif // WAVESHARE_AMOLED_175
