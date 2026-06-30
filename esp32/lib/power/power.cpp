/**
 * @file power.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ESP32 Power Management functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "power.hpp"

extern const uint8_t BOARD_BOOT_PIN;

/**
 * @brief Power Class constructor
 *
 */
Power::Power() {
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
  esp_err_t rtc_gpio_hold_en(gpio_num_t GPIO_NUM_5);
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
  // Arduino_GFX: turn off display
  if (gfx) {
    gfx->displayOff();
    gfx->fillScreen(0x0000);
  }
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
  // Arduino_GFX: simplified suspend without brightness control
  lv_msgbox_close(powerMsg);
  lv_refr_now(display);
  if (gfx)
    gfx->displayOff();
  powerLightSleep();
  if (gfx) {
    gfx->displayOn();
    gfx->setBrightness(255);
  }
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
