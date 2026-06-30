/**
 * @file power.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ESP32 Power Management functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include <SPI.h>
#include <WiFi.h>
#include <Wire.h>
#include <driver/rtc_io.h>
#ifndef DISABLE_BLUETOOTH
#include <esp_bt.h>
#ifndef CONFIG_BT_NIMBLE_ENABLED
#include <esp_bt_main.h>
#endif
#endif
#include "globalGuiDef.h"
#include "lvgl.h"
#include "tft.hpp"
#include <esp_wifi.h>

class Power {
private:
  void powerDeepSleep();
  void powerLightSleepTimer(int millis);
  void powerLightSleep();
  void powerOffPeripherals();

public:
  Power();

  void deviceSuspend();
  void deviceShutdown();
};