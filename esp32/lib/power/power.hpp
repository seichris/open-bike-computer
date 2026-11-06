/**
 * @file power.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ESP32 Power Management functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

// Declarations only. The radio, bus and display headers the implementation
// needs stay in power.cpp so that including this header does not make a
// library depend on WiFi, SPI, Wire or LVGL.
#include <atomic>
#include <cstdint>
#include "shutdown_barrier_policy.hpp"

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
  void (*deferredNotice_)(uint8_t) = nullptr;
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
  // Invoked once on the UI thread after a terminal deferral; must not reopen
  // storage or retry a stopped owner. Registration performs no IO.
  void setShutdownDeferredCallback(void (*notice)(uint8_t)) { deferredNotice_ = notice; }
  // Main-loop only, bounded polling; returns true when normal work must pause.
  bool processShutdown();
  bool shutdownPending() const { return shutdownRequested_.load(); }
};
