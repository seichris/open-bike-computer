/**
 * @file power.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ESP32 Power Management functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "power.hpp"
#ifdef USE_ARDUINO_GFX
#include "../display_power/display_power.hpp"
#endif
#include "power_metrics.hpp"
#ifdef USE_ARDUINO_GFX
#include <Arduino_GFX_Library.h>
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "axp2101.hpp"
#include "hal.hpp"
#else
extern const uint8_t BOARD_BOOT_PIN;
#endif

void Power::begin() {
  // Radio shutdown touches Arduino/IDF subsystems and must not run from the
  // global Power object's constructor before framework initialization.
#ifdef DISABLE_RADIO
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
#ifndef DISABLE_BLUETOOTH
  btStop();
  esp_bt_controller_disable();
#endif
  esp_wifi_stop();
#endif
}

/**
 * @brief Deep Sleep Mode
 *
 */
void Power::powerDeepSleep() {
#ifndef DISABLE_BLUETOOTH
#ifndef CONFIG_BT_NIMBLE_ENABLED
  esp_bluedroid_disable();
#endif
  esp_bt_controller_disable();
#endif
  esp_wifi_stop();
  esp_deep_sleep_disable_rom_logging();
  delay(10);

#ifdef ICENAV_BOARD
  // If you need other peripherals to maintain power, please set the IO port to
  // hold
  gpio_hold_en(GPIO_NUM_46);
  gpio_hold_en((gpio_num_t)BOARD_BOOT_PIN);
  gpio_deep_sleep_hold_en();
#endif

  esp_sleep_enable_ext1_wakeup(1ull << BOARD_BOOT_PIN, ESP_EXT1_WAKEUP_ANY_LOW);
  esp_deep_sleep_start();
}

/**
 * @brief Sleep Mode Timer
 *
 * @param millis
 */
void Power::powerLightSleepTimer(int millis) {
  esp_sleep_enable_timer_wakeup(millis * 1000);
  esp_light_sleep_start();
}

/**
 * @brief Sleep Mode
 *
 */
void Power::powerLightSleep() {
  esp_sleep_enable_ext1_wakeup(1ull << BOARD_BOOT_PIN, ESP_EXT1_WAKEUP_ANY_LOW);
  esp_light_sleep_start();
}

/**
 * @brief Power off peripherals devices
 */
void Power::powerOffPeripherals() {
#ifndef USE_ARDUINO_GFX
  tftOff();
  tft.fillScreen(TFT_BLACK);
#else
  displayPowerManager.requestState(display_power::State::Off);
  displayPowerManager.applyPendingPanelChange();
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  waveshare_board::axp2101::setDisplayPower(false);
  waveshare_board::axp2101::setPeripheralPower(false);
#endif
  SPI.end();
  Wire.end();
}

/**
 * @brief Core light suspend and TFT off
 */
void Power::deviceSuspend() {
#ifndef USE_ARDUINO_GFX
  int brightness = tft.getBrightness();
  lv_msgbox_close(powerMsg);
  lv_refr_now(display);
  tftOff();
  powerLightSleep();
  tftOn(brightness);
#else
  const display_power::State resumeState = displayPowerManager.state();
  lv_msgbox_close(powerMsg);
  lv_refr_now(display);
  displayPowerManager.requestState(display_power::State::Off);
  displayPowerManager.applyPendingPanelChange();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  waveshare_board::axp2101::setDisplayPower(false);
#endif
  powerLightSleep();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  waveshare_board::axp2101::setDisplayPower(true);
  delay(50);
#endif
  displayPowerManager.requestState(resumeState);
  displayPowerManager.applyPendingPanelChange();
#endif
  while (digitalRead(BOARD_BOOT_PIN) != 1) {
    delay(5);
  };
  log_v("Exited sleep mode");
}

/**
 * @brief Power off peripherals and deep sleep
 *
 */
void Power::deviceShutdown() {
  powerOffPeripherals();
  powerDeepSleep();
}
