/**
 * @file power.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ESP32 Power Management functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "power.hpp"
#include "sleep_audit.hpp"
#include "sleep_audit_policy.hpp"
#include "../ride_diagnostics/ride_diagnostics.hpp"
#ifdef USE_ARDUINO_GFX
#include "../display_power/display_power.hpp"
#endif
#include "power_metrics.hpp"
#ifdef USE_ARDUINO_GFX
#include <Arduino_GFX_Library.h>
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "hal.hpp"
#include "../ble_navigation/ble_navigation.hpp"
#include "../speaker/speaker.hpp"
#else
extern const uint8_t BOARD_BOOT_PIN;
#endif

void Power::begin() {
  sleep_audit::begin();
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
  if (!shutdownBarrier_.permit()) return;
  int32_t bluedroidStopResult = sleep_audit::policy::kNotAttempted;
  int32_t bluetoothStopResult = sleep_audit::policy::kNotAttempted;
#ifndef DISABLE_BLUETOOTH
#ifndef CONFIG_BT_NIMBLE_ENABLED
  bluedroidStopResult = esp_bluedroid_disable();
#endif
  bluetoothStopResult = esp_bt_controller_disable();
#endif
  // The internal network owner has already stopped Wi-Fi and drained before
  // the permit was issued. Never touch its driver from this UI stack.
  const int32_t wifiStopResult = sleep_audit::policy::kNotAttempted;
  esp_deep_sleep_disable_rom_logging();
  delay(10);

#ifdef ICENAV_BOARD
  // If you need other peripherals to maintain power, please set the IO port to
  // hold
  gpio_hold_en(GPIO_NUM_46);
  gpio_hold_en((gpio_num_t)BOARD_BOOT_PIN);
  gpio_deep_sleep_hold_en();
#endif

  const int32_t wakeConfigResult = esp_sleep_enable_ext1_wakeup(
      1ull << BOARD_BOOT_PIN, ESP_EXT1_WAKEUP_ANY_LOW);
  sleep_audit::entering(wifiStopResult, bluetoothStopResult, bluedroidStopResult,
                         wakeConfigResult, 1ull << BOARD_BOOT_PIN,
                         static_cast<uint8_t>(digitalRead(BOARD_BOOT_PIN)));
  esp_deep_sleep_start();
}

/**
 * @brief Sleep Mode Timer
 *
 * @param millis
 */
void Power::powerLightSleepTimer(int millis) {
  if (!shutdownBarrier_.permit()) return;
  esp_sleep_enable_timer_wakeup(millis * 1000);
  esp_light_sleep_start();
}

/**
 * @brief Sleep Mode
 *
 */
void Power::powerLightSleep() {
  if (!shutdownBarrier_.permit()) return;
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
  const bool panelChangeApplied = displayPowerManager.applyPendingPanelChange();
  sleep_audit::panelRequested(panelChangeApplied);
#endif
  SPI.end();
  Wire.end();
  sleep_audit::peripheralsReturned();
}

/**
 * @brief Core light suspend and TFT off
 */
void Power::deviceSuspend() {
  // Explicit suspend has no reversible storage/recorder barrier yet. Automatic
  // IDF light sleep remains managed by the existing domain locks.
  Serial.println("POWER_BARRIER: explicit suspend deferred (no resume barrier)");
}

/**
 * @brief Power off peripherals and deep sleep
 *
 */
void Power::deviceShutdown() {
  shutdownRequested_.store(true, std::memory_order_release);
}

void Power::deviceRestart() {
  restartRequested_.store(true, std::memory_order_release);
  deviceShutdown();
}

void Power::configureShutdown(bool (*begin)(), bool (*drain)(),
                              bool (*renderer)(), bool (*accepted)(),
                              bool (*storage)(), uint64_t (*progress)()) {
  beginShutdown_ = begin;
  drainShutdown_ = drain;
  stopRenderer_ = renderer;
  acceptedWork_ = accepted;
  stopStorage_ = storage;
  progress_ = progress;
}

bool Power::processShutdown() {
  if (!shutdownRequested_.load(std::memory_order_acquire)) return false;
  using shutdown_barrier::Stage;
  if (shutdownBarrier_.stage() == Stage::Idle) {
    shutdownBarrier_.request(millis());
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    sleep_audit::RequestContext context;
    context.configuredTimeoutSeconds = mapRenderSettings.disconnectedSleepTimeoutSeconds;
    context.connected = bleNavServer.isConnected();
    context.displayState = static_cast<uint8_t>(displayPowerManager.state());
    context.audioPlaying = waveshare_board::speaker::isPlaying();
    sleep_audit::requested(context);
#endif
    // No callbacks, no permit. Early/partial startup safely stays awake.
    if (beginShutdown_ != nullptr) beginShutdown_();
    if (progress_ != nullptr) lastProgress_ = progress_();
  }
  const Stage stage = shutdownBarrier_.stage();
  bool drained = false, renderer = false, sealed = false, storageStopped = false;
  if (stage == Stage::Drain && progress_ != nullptr) {
    const uint64_t progress = progress_();
    if (progress != lastProgress_) {
      lastProgress_ = progress;
      shutdownBarrier_.noteProgress(millis());
    }
  }
  if (stage == Stage::Drain && drainShutdown_ != nullptr)
    drained = drainShutdown_();
  if (stage == Stage::Renderer && stopRenderer_ != nullptr)
    renderer = stopRenderer_();
  if (stage == Stage::Diagnostics) {
    // Recorder joins an outstanding seal instead of replacing its completion.
    // A bounded failure leaves its writer paused and never permits sleep.
    if (!diagnosticsRequested_) {
      diagnosticsRequested_ = true;
      sealed = ride_diagnostics::prepareForShutdown(20);
    } else {
      sealed = ride_diagnostics::sealActiveChunk(20);
    }
  }
  if (stage == Stage::Storage && stopStorage_ != nullptr)
    storageStopped = stopStorage_();
  shutdownBarrier_.poll(millis(), drained, renderer, sealed, storageStopped,
                       acceptedWork_ != nullptr && acceptedWork_());
  if (shutdownBarrier_.stage() == Stage::Deferred && stage != Stage::Deferred) {
    Serial.printf("POWER_BARRIER: shutdown deferred stage=%u; no sleep permit\n",
                  static_cast<unsigned>(shutdownBarrier_.failedStage()));
  }
  if (shutdownBarrier_.permit()) {
    sleep_audit::recorderSealed(true);
    if (restartRequested_.load(std::memory_order_acquire)) ESP.restart();
    powerOffPeripherals();
    powerDeepSleep();
  }
  // Drain must keep servicing renderer/rollback mailboxes. Once stopped, do
  // not let ordinary UI work start readers or new storage commands again.
  return shutdownBarrier_.stage() != Stage::Drain;
}
