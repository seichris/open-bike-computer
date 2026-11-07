/**
 * @file board_startup.hpp
 * @brief The startup part of the board layer: the bodies of the boot and
 *        loop steps that exist for one display family.
 *
 * docs/plans/board-support-architecture-plan.md, layer 2. main.cpp owns the
 * boot-stage order and enters and completes every boot_diagnostics stage
 * itself, so the BOOT_STAGE ids, names and order stay in one place; amoled.cpp
 * and epaper.cpp implement these functions for their family and are compiled
 * for that family only. Differences between the boards of one family are data
 * in lib/board/boards. This header names no other library so that the part
 * stays a leaf of the dependency finder for its callers.
 */

#pragma once

#include <cstdint>

namespace waveshare_board::axp2101 {
struct PowerButtonEvents;
}

namespace board::startup {

// Stage::WakeConfiguration, outside firmware maintenance. Configures the
// family's wake inputs and returns the EXT1 wake mask: BOOT plus the touch
// interrupt where it is an RTC GPIO (AMOLED), or BOOT plus the three side
// keys (e-paper). main.cpp attaches the BOOT interrupt and the touch wake
// hint itself.
uint64_t configureWakeSources();

// AUTOMATIC_LIGHT_SLEEP_EXPERIMENT notifier: maps a GPIO wake mask to the UI
// scheduler's wake reasons.
void notifyGpioWake(uint64_t gpioMask);

// After Stage::PmicInspection. The AMOLED family hosts the OTA firmware
// maintenance mode: when this boot was requested as a maintenance boot it
// brings up BLE and the transfer server only and returns true, and setup()
// returns. A family without it (the e-paper answers the BLE request with
// firmware_maintenance_unsupported) returns false and the normal boot goes on.
bool beginFirmwareMaintenance();

// loop(): true when the maintenance mode handled this pass, so the normal
// loop body is skipped. Also schedules the reboot into maintenance.
bool processFirmwareMaintenance();

// Stage::UserInterface, after the LVGL interface exists and before the first
// frame: the e-paper starts its side-key reader.
void beginInput();

// Stage::Speaker: the AMOLED family starts the ES8311 speaker path and the
// AXP2101 PWR-key event monitoring. The e-paper's PMIC policy writes only
// the panel rail, so it leaves the PWR-key interrupts alone.
void beginAudio();

// loop(), after the display inactivity policy and before LVGL: polls the
// family's panel and input devices. inputAllowed is false while the deferred
// shutdown notice is shown.
void processInput(bool inputAllowed);

// loop(): the family's upper bound on the scheduler wait. The e-paper polls
// its keys every 20 ms unless they are light-sleep wake sources.
uint32_t limitWaitMs(uint32_t waitMs);

// Ownership pairing input.
// Whether the pairing comparison is visible on the panel. The AMOLED panel
// flushes synchronously and reports it through appDisplayFlushCompleted();
// the e-paper presents asynchronously, and the BOOT gate stays armed until
// its waveform has completed.
bool pairingComparisonPresented();
// Reads and clears the PMIC PWR-key events (AMOLED). False when the family
// has no PWR-key input: the e-paper's side keys go through lib/board_input.
bool takePowerButtonEvents(waveshare_board::axp2101::PowerButtonEvents &events);
// Discards button input generated before the comparison was rendered. False
// when the family's input device could not be read; the confirmation is then
// left unarmed.
bool discardStalePairingInput();

}  // namespace board::startup
