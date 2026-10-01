/**
 * @file power.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ESP32 Power Management functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include <atomic>
#include "shutdown_barrier_policy.hpp"
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
#include "../gui/src/globalGuiDef.h"
#include "lvgl.h"
#include "../tft/tft.hpp"
#include <esp_wifi.h>

class Power {
private:
  void powerDeepSleep();
  std::atomic<bool> shutdownRequested_{false};
  std::atomic<bool> restartRequested_{false};
  shutdown_barrier::Barrier shutdownBarrier_;
  bool (*beginShutdown_)() = nullptr;
  bool (*drainShutdown_)() = nullptr;
  bool (*stopRenderer_)() = nullptr;
  bool (*acceptedWork_)() = nullptr;
  bool (*stopStorage_)() = nullptr;
  uint64_t (*progress_)() = nullptr;
  uint64_t lastProgress_ = 0;
  void powerLightSleepTimer(int millis);
  void powerLightSleep();
  void powerOffPeripherals();

public:
  Power() = default;

  void begin();

  void deviceSuspend();
  // Request-only: safe in callbacks, never waits for the calling worker.
  void deviceShutdown();
  void deviceRestart();
  void configureShutdown(bool (*begin)(), bool (*drain)(),
                         bool (*renderer)(), bool (*accepted)(),
                         bool (*storage)(), uint64_t (*progress)());
  // Main-loop only, bounded polling; returns true when normal work must pause.
  bool processShutdown();
  bool shutdownPending() const { return shutdownRequested_.load(); }
};
