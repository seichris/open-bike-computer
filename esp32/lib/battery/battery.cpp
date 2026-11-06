/**
 * @file battery.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Battery monitor definition and functions
 * @version 0.2.2
 * @date 2025-05
 */


#include "battery.hpp"

#include "axp2101.hpp"

/**
 * @brief Battery Class constructor
 *
 */
Battery::Battery()
    : batteryMax(4.2f), batteryMin(3.6f), lastBatteryReadMs(0),
      cachedBatteryPercentage(0), cachedBatteryCharging(false),
      cachedBatteryPercentageValid(false) {}

/**
 * @brief Configure ADC Channel for battery reading
 *
 */
void Battery::initADC()
{
#ifdef ADC1
  adc1_config_width(ADC_WIDTH_BIT_12);
  adc1_config_channel_atten(BATT_PIN, ADC_ATTEN_DB_12);
#endif

#ifdef ADC2
  adc2_config_channel_atten(BATT_PIN, ADC_ATTEN_DB_12);
#endif
}

/**
 * @brief Set battery voltage levels
 *
 * @param maxVoltage -> Full Charge voltage
 * @param minVoltage -> Min Charge voltage
 */
void Battery::setBatteryLevels(float maxVoltage, float minVoltage)
{
  batteryMax = maxVoltage;
  batteryMin = minVoltage;
}

bool Battery::readBatteryStatus(uint8_t &percentage, bool &charging) {
  const uint32_t now = millis();
  if (lastBatteryReadMs != 0 &&
      now - lastBatteryReadMs < BATTERY_READ_INTERVAL_MS) {
    if (cachedBatteryPercentageValid) {
      percentage = cachedBatteryPercentage;
      charging = cachedBatteryCharging;
    }
    return cachedBatteryPercentageValid;
  }

  lastBatteryReadMs = now;
  uint8_t latestPercentage = 0;
  bool latestCharging = false;
  bool readSucceeded = false;

  readSucceeded = waveshare_board::axp2101::readBatteryStatus(
      latestPercentage, latestCharging);

  cachedBatteryPercentageValid = readSucceeded;
  if (!readSucceeded) {
    return false;
  }

  cachedBatteryPercentage = latestPercentage;
  cachedBatteryCharging = latestCharging;
  percentage = cachedBatteryPercentage;
  charging = cachedBatteryCharging;
  return true;
}

bool Battery::readBatteryPercent(uint8_t &percentage) {
  bool charging = false;
  return readBatteryStatus(percentage, charging);
}

float Battery::readBattery() {
  uint8_t percentage = 0;
  return readBatteryPercent(percentage) ? static_cast<float>(percentage)
                                        : 0.0f;
}
