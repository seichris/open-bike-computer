/**
 * @file axp2101.hpp
 * @brief AXP2101 PMU helpers for the Waveshare ESP32-S3 Touch AMOLED 1.75.
 */

#pragma once

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include <Arduino.h>

namespace waveshare_board::axp2101 {

struct PowerStatus {
  uint8_t status1 = 0;
  uint8_t status2 = 0;
  bool vbusGood = false;
  bool batteryPresent = false;
  uint8_t batteryCurrentDirection = 0;
  bool systemOn = false;
  bool vindpmActive = false;
  uint8_t chargingStatus = 0;
};

struct PowerButtonEvents {
  bool shortPress = false;
  bool negativeEdge = false;
  bool positiveEdge = false;
};

enum class PowerButtonOffLevel : uint8_t {
  FourSeconds = 0,
  SixSeconds = 1,
  EightSeconds = 2,
  TenSeconds = 3,
};

bool begin();
bool isAvailable();
bool readRegister(uint8_t reg, uint8_t &value);
bool readPowerStatus(PowerStatus &status);
bool readBatteryStatus(uint8_t &percentage, bool &charging);
bool readBatteryPercentage(uint8_t &percentage);
bool setPowerButtonOffLevel(PowerButtonOffLevel level);
bool setPowerButtonEventMonitoring(bool enabled);
bool readAndClearPowerButtonEvents(PowerButtonEvents &events);
// Probe and report the PMIC state. The 1.75-inch target leaves every output
// rail unchanged. The 2.06-inch target has one boot-only compatibility
// exception: it may set the established display-enable bit while preserving
// every other bit in that register. No target rewrites rail voltages or turns
// an output off.
bool initializePowerState();

} // namespace waveshare_board::axp2101

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
