#include "../../lib/ui_scheduler/ui_scheduler_policy.hpp"

#include <cassert>
#include <cstdint>
#include <limits>

int main() {
  using ui_scheduler::DeadlineContext;

  DeadlineContext context;
  assert(ui_scheduler::nextWaitMs(context) == 250);

  context.connectedNavigation = true;
  assert(ui_scheduler::nextWaitMs(context) == 50);

  context.lvglDelayMs = 12;
  assert(ui_scheduler::nextWaitMs(context) == 12);

  context.housekeepingDelayMs = 7;
  assert(ui_scheduler::nextWaitMs(context) == 7);

  context.displayOff = true;
  context.connectedNavigation = false;
  context.housekeepingDelayMs = ui_scheduler::kNoDeadline;
  assert(ui_scheduler::nextWaitMs(context) == 250);

  context.displayOff = false;
  context.lvglBlocked = true;
  context.lvglDelayMs = 0;
  assert(ui_scheduler::nextWaitMs(context) == 250);

  context.lvglBlocked = false;
  assert(ui_scheduler::nextWaitMs(context) == 0);

  assert(ui_scheduler::remainingUntil(1'000, 900, 250) == 150);
  assert(ui_scheduler::remainingUntil(1'150, 900, 250) == 0);
  assert(ui_scheduler::isDue(1'150, 900, 250));
  assert(!ui_scheduler::isDue(1'149, 900, 250));

  // A maneuver published one millisecond after BLE housekeeping bypasses the
  // remaining 249 ms cadence immediately, while an unrelated wake does not.
  const uint32_t maneuverWake =
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Ble);
  assert(ui_scheduler::shouldRunForReason(
      maneuverWake, ui_scheduler::WakeReason::Ble, 1'001, 1'000, 250));
  assert(!ui_scheduler::shouldRunForReason(
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Touch),
      ui_scheduler::WakeReason::Ble, 1'001, 1'000, 250));

  // Work performed after LVGL returns consumes part of its next delay rather
  // than being added on top of that deadline.
  context = {};
  context.lvglDelayMs = ui_scheduler::remainingUntil(1'005, 1'000, 30);
  assert(ui_scheduler::nextWaitMs(context) == 25);

  constexpr uint32_t nearWrap = std::numeric_limits<uint32_t>::max() - 100;
  assert(ui_scheduler::remainingUntil(nearWrap + 150, nearWrap, 250) == 100);
  assert(ui_scheduler::remainingUntil(nearWrap + 250, nearWrap, 250) == 0);

  const uint32_t allReasons =
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Ble) |
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Touch) |
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Boot) |
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Display) |
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Transfer) |
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Audio);
  assert(ui_scheduler::hasReason(allReasons,
                                 ui_scheduler::WakeReason::Ble));
  assert(ui_scheduler::hasReason(allReasons,
                                 ui_scheduler::WakeReason::Transfer));
  assert(!ui_scheduler::hasReason(
      ui_scheduler::reasonBits(ui_scheduler::WakeReason::Boot),
      ui_scheduler::WakeReason::Touch));

  constexpr uint8_t touchPin = 21;
  constexpr uint8_t bootPin = 0;
  assert(ui_scheduler::gpioWakeReasons(0, touchPin, bootPin) == 0);
  const uint32_t touchWakeReasons =
      ui_scheduler::gpioWakeReasons(1ULL << touchPin, touchPin, bootPin);
  assert(ui_scheduler::hasReason(touchWakeReasons,
                                 ui_scheduler::WakeReason::Touch));
  assert(!ui_scheduler::hasReason(touchWakeReasons,
                                  ui_scheduler::WakeReason::Boot));
  const uint32_t bothGpioWakeReasons = ui_scheduler::gpioWakeReasons(
      (1ULL << touchPin) | (1ULL << bootPin), touchPin, bootPin);
  assert(ui_scheduler::hasReason(bothGpioWakeReasons,
                                 ui_scheduler::WakeReason::Touch));
  assert(ui_scheduler::hasReason(bothGpioWakeReasons,
                                 ui_scheduler::WakeReason::Boot));
  assert(ui_scheduler::gpioWakeReasons(1ULL << 7, touchPin, bootPin) == 0);

  return 0;
}
