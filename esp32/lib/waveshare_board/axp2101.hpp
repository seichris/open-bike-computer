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

bool begin();
bool isAvailable();
bool readRegister(uint8_t reg, uint8_t &value);
bool writeRegister(uint8_t reg, uint8_t value);
bool readPowerStatus(PowerStatus &status);
bool readBatteryStatus(uint8_t &percentage, bool &charging);
bool readBatteryPercentage(uint8_t &percentage);
bool setPowerButtonEventMonitoring(bool enabled);
bool readAndClearPowerButtonEvents(PowerButtonEvents &events);

bool enableDisplayRails();
bool enablePeripheralRails();
bool setDisplayPower(bool enabled);
bool setPeripheralPower(bool enabled);
bool restoreDefaultRails();

} // namespace waveshare_board::axp2101

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
