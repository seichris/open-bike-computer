#if defined(WAVESHARE_EPAPER_397)
/**
 * @file epaper.cpp
 * @brief Startup part of the Waveshare 3.97-inch e-paper board.
 */

#include "board_startup.hpp"

#include <Arduino.h>

#include <algorithm>

#include "ble_navigation.hpp"
#include "board.hpp"
#include "board_input.hpp"
#include "epaper_display.hpp"
#include "epaper_ui.hpp"
#include "ui_scheduler.hpp"

namespace board::startup {
namespace {

// All four active-low contacts can wake the chip from light sleep.
static_assert(board::buttons::boot <= 21 && board::buttons::up <= 21 &&
                  board::buttons::center <= 21 && board::buttons::down <= 21,
              "EXT1 wake needs RTC GPIOs");
constexpr uint64_t kButtonWakeMask =
    (1ULL << board::buttons::boot) | (1ULL << board::buttons::up) |
    (1ULL << board::buttons::center) | (1ULL << board::buttons::down);

}  // namespace

uint64_t configureWakeSources() {
  pinMode(board::buttons::up, INPUT_PULLUP);
  pinMode(board::buttons::center, INPUT_PULLUP);
  pinMode(board::buttons::down, INPUT_PULLUP);
  return kButtonWakeMask;
}

void notifyGpioWake(uint64_t gpioMask) {
  if ((gpioMask & kButtonWakeMask) != 0) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Boot);
  }
}

// BLE answers a maintenance request with firmware_maintenance_unsupported, so
// no boot is ever a maintenance boot here.
bool beginFirmwareMaintenance() { return false; }

bool processFirmwareMaintenance() { return false; }

void beginInput() { board_input::begin(); }

void beginAudio() {}

void processInput(bool inputAllowed) {
  epaper::poll();
  if (inputAllowed) {
    board_input::process();
    epaper_ui::process();
  }
}

uint32_t limitWaitMs(uint32_t waitMs) {
  // The contacts are polled independently of LVGL and the waveform worker.
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  // All four active-low contacts are wake sources in this opt-in profile, so
  // the regular scheduler deadline can be used without 20 ms polling wakes.
  return waitMs;
#else
  return std::min<uint32_t>(20, waitMs);
#endif
}

bool keepBootPairingGateArmed() {
  return bleNavServer.hasOwnershipPairingCode() && !epaper::pairingPresented();
}

bool takePowerButtonEvents(waveshare_board::axp2101::PowerButtonEvents &) {
  return false;
}

bool discardStalePairingInput() {
  board_input::requireFreshPairingInput();
  return true;
}

}  // namespace board::startup
#endif
