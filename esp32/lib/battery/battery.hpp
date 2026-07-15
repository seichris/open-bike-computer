/**
 * @file battery.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Battery monitor definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include <Arduino.h>
#include <driver/adc.h>
#include <esp_adc_cal.h>

class Battery
{
private:
  float batteryMax;
  float batteryMin;
  static constexpr float V_REF = 3.9; // ADC reference voltage
  static constexpr uint32_t BATTERY_READ_INTERVAL_MS = 5000;
  uint32_t lastBatteryReadMs;
  uint8_t cachedBatteryPercentage;
  bool cachedBatteryCharging;
  bool cachedBatteryPercentageValid;

  float readLegacyBattery();

public:
  Battery();

  void initADC();
  void setBatteryLevels(float maxVoltage, float minVoltage);
  float readBattery();
  bool readBatteryStatus(uint8_t &percentage, bool &charging);
  bool readBatteryPercent(uint8_t &percentage);
};
