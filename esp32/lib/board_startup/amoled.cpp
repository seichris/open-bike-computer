#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
/**
 * @file amoled.cpp
 * @brief Startup part of the Waveshare AMOLED family (1.75 and 2.06).
 */

#include "board_startup.hpp"

#include <Arduino.h>
#include <esp_heap_caps.h>

#include <cstdio>

#include "axp2101.hpp"
#include "ble_navigation.hpp"
#include "board.hpp"
#include "boot_diagnostics.hpp"
#include "device_transfer_http.hpp"
#include "firmware_maintenance.hpp"
#include "firmware_maintenance_policy.hpp"
#include "firmware_update_http.hpp"
#include "power.hpp"
#include "power_management.hpp"
#include "ride_diagnostics.hpp"
#include "speaker.hpp"
#include "ui_scheduler.hpp"

extern Power power;
extern device_transfer::HttpTransferServer deviceTransferHttp;
extern firmware_update::FirmwareUpdateHttpServer firmwareUpdateHttp;

namespace board::startup {
namespace {

static_assert(!board::touch::ext1WakeSource || board::touch::interrupt <= 21,
              "EXT1 wake needs an RTC GPIO");

void queueDeviceTransferStatusNotification() {
  bleNavServer.requestDeviceTransferStatusNotification();
}

void setupFirmwareMaintenanceMode() {
  deviceTransferHttp.configure(8080, "BikeComputer-Transfer");
  firmwareUpdateHttp.configure(&deviceTransferHttp);
  deviceTransferHttp.noteStatusChanged("maintenance_boot_baseline");
  deviceTransferHttp.setStatusChangedCallback(
      queueDeviceTransferStatusNotification);
  boot_diagnostics::markFirmwareMaintenance();
  firmware_maintenance::setStage(
      firmware_maintenance::Stage::AwaitingAuthentication);
  // Preserve boot diagnostics before NimBLE allocates its tasks and buffers,
  // matching the normal startup ordering contract.
  (void)std::fflush(stdout);
  bleNavServer.init("BikeComputer");
  power_management::completeStartup();
  Serial.printf(
      "FIRMWARE_MAINTENANCE: ready correlation=%lu internal_free=%u "
      "dma_free=%u\n",
      static_cast<unsigned long>(firmware_maintenance::correlation()),
      static_cast<unsigned>(heap_caps_get_free_size(
          MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT)),
      static_cast<unsigned>(
          heap_caps_get_free_size(MALLOC_CAP_DMA | MALLOC_CAP_8BIT)));
}

void processFirmwareMaintenanceMode() {
  bleNavServer.process();
  deviceTransferHttp.process();
  const device_transfer::HttpTransferStatus transferStatus =
      deviceTransferHttp.status();
  const uint32_t now = millis();

  const firmware_maintenance::Stage stage = firmware_maintenance::stage();
  const bool commitOwnsReboot =
      stage == firmware_maintenance::Stage::Committing ||
      stage == firmware_maintenance::Stage::Rebooting;
  static firmware_maintenance::policy::BootButtonExitState bootButtonExit;
  if (!commitOwnsReboot && !firmware_maintenance::exitRequested() &&
      firmware_maintenance::policy::bootButtonExitRequested(
          bootButtonExit, digitalRead(board::buttons::boot) == LOW, now)) {
    (void)ride_diagnostics::record(ride_diagnostics::Level::Warning,
                                   "ota", "exit_boot_button", "{}");
    firmware_maintenance::requestExit();
  }

  const uint32_t maintenanceElapsed =
      now - firmware_maintenance::activeSinceMs();
  if (!firmware_maintenance::exitRequested() && !commitOwnsReboot &&
      !transferStatus.enabled &&
      firmware_maintenance::policy::authenticationTimedOut(
          maintenanceElapsed, bleNavServer.isAuthenticated())) {
    deviceTransferHttp.setLastError(
        "maintenance_authentication_timeout",
        "owner authentication did not complete before the deadline");
    (void)ride_diagnostics::record(ride_diagnostics::Level::Warning,
                                   "ota", "exit_auth_timeout", "{}");
    firmware_maintenance::requestExit();
  } else if (!firmware_maintenance::exitRequested() && !commitOwnsReboot &&
             firmware_maintenance::policy::transferTimedOut(
                 now, transferStatus.lastUsefulTrafficMs,
                 transferStatus.enabled,
                 transferStatus.authorizedRequestInProgress)) {
    deviceTransferHttp.setLastError(
        "maintenance_inactivity_timeout",
        "firmware transfer made no useful progress before the deadline");
    (void)ride_diagnostics::record(ride_diagnostics::Level::Warning,
                                   "ota", "exit_inactivity", "{}");
    firmware_maintenance::requestExit();
  }
  if (!firmware_maintenance::exitRequested() && !commitOwnsReboot &&
      maintenanceElapsed >=
          firmware_maintenance::kOverallDeadlineMs) {
    deviceTransferHttp.setLastError(
        "maintenance_deadline",
        "firmware maintenance exceeded its overall deadline");
    (void)ride_diagnostics::record(ride_diagnostics::Level::Warning,
                                   "ota", "exit_deadline", "{}");
    firmware_maintenance::requestExit();
  }

  if (firmware_maintenance::exitRequested() && !commitOwnsReboot) {
    const bool disabled = firmwareUpdateHttp.setEnabled(false);
    if (disabled && deviceTransferHttp.waitUntilStopped(5500)) {
      Serial.println("FIRMWARE_MAINTENANCE: returning to normal boot");
      delay(250);
      ::power.deviceRestart();
    }
  }
  delay(5);
}

}  // namespace

uint64_t configureWakeSources() {
  uint64_t ext1WakeMask = 1ULL << board::buttons::boot;
  if constexpr (board::touch::ext1WakeSource) {
    ext1WakeMask |= 1ULL << board::touch::interrupt;
  }
  return ext1WakeMask;
}

void notifyGpioWake(uint64_t gpioMask) {
  const uint32_t reasons = ui_scheduler::gpioWakeReasons(
      gpioMask, board::touch::interrupt, board::buttons::boot);
  if (ui_scheduler::hasReason(reasons, ui_scheduler::WakeReason::Touch)) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Touch);
  }
  if (ui_scheduler::hasReason(reasons, ui_scheduler::WakeReason::Boot)) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Boot);
  }
}

bool beginFirmwareMaintenance() {
  if (!firmware_maintenance::active()) {
    return false;
  }
  setupFirmwareMaintenanceMode();
  return true;
}

bool processFirmwareMaintenance() {
  if (firmware_maintenance::active()) {
    processFirmwareMaintenanceMode();
    return true;
  }
  if (firmware_maintenance::stage() ==
          firmware_maintenance::Stage::RebootPending &&
      millis() - firmware_maintenance::activeSinceMs() >= 750) {
    Serial.println("FIRMWARE_MAINTENANCE: rebooting into maintenance");
    Serial.flush();
    ::power.deviceRestart();
  }
  return false;
}

void beginInput() {}

void beginAudio() {
  waveshare_board::speaker::begin();
  if (!waveshare_board::axp2101::setPowerButtonEventMonitoring(true)) {
    Serial.println("AXP2101: PWR button-event monitoring unavailable");
  }
}

void processInput(bool) {}

uint32_t limitWaitMs(uint32_t waitMs) { return waitMs; }

bool pairingComparisonPresented() { return true; }

bool takePowerButtonEvents(
    waveshare_board::axp2101::PowerButtonEvents &events) {
  return waveshare_board::axp2101::readAndClearPowerButtonEvents(events);
}

bool discardStalePairingInput() {
  waveshare_board::axp2101::PowerButtonEvents stalePowerButtonEvents;
  return waveshare_board::axp2101::readAndClearPowerButtonEvents(
      stalePowerButtonEvents);
}

}  // namespace board::startup
#endif
