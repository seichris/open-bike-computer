/**
 * @file battery.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Battery monitor definition and functions
 * @version 0.2.2
 * @date 2025-05
 */


#include "battery.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "axp2101.hpp"
#endif

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

/**
 * @brief Read battery charge and return %.
 *
 * @return float -> % Charge
 */
float Battery::readLegacyBattery()
{
  long sum = 0;        // Sum of samples taken
  float voltage = 0.0; // Calculated voltage
  float output = 0.0;  // Output value

  for (int i = 0; i < 100; i++)
  {
    #ifdef ADC1
      sum += static_cast<long>(adc1_get_raw(BATT_PIN));
    #endif

    #ifdef ADC2
      int readRaw;
      esp_err_t r = adc2_get_raw(BATT_PIN, ADC_WIDTH_BIT_12, &readRaw);
      if (r == ESP_OK)
        sum += static_cast<long>(readRaw);
    #endif

    delayMicroseconds(150);
  }

  voltage = sum / 100.0;
  // Custom board has a divider circuit
  constexpr float R1 = 100000.0; // Resistance of R1 (100K)
  constexpr float R2 = 100000.0; // Resistance of R2 (100K)
  voltage = (voltage * V_REF) / 4096.0;
  voltage = voltage / (R2 / (R1 + R2));
  voltage = roundf(voltage * 100) / 100;

  output = ((voltage - batteryMin) / (batteryMax - batteryMin)) * 100;
  return (output <= 160) ? output : 0.0f;
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

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  readSucceeded = waveshare_board::axp2101::readBatteryStatus(
      latestPercentage, latestCharging);
#elif defined(ADC1) || defined(ADC2)
  const float rawLevel = readLegacyBattery();
  if (isfinite(rawLevel)) {
    latestPercentage =
        static_cast<uint8_t>(constrain(lroundf(rawLevel), 0L, 100L));
    readSucceeded = true;
  }
#endif

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
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  uint8_t percentage = 0;
  return readBatteryPercent(percentage) ? static_cast<float>(percentage)
                                        : 0.0f;
#else
  return readLegacyBattery();
#endif
}
