#include "runtime_watchdog_diagnostics.hpp"

#include <Arduino.h>
#include <esp_task_wdt.h>

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include <esp_attr.h>
#endif

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

namespace runtime_watchdog_diagnostics {
namespace {

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
RTC_NOINIT_ATTR policy::RetainedState retainedState;
#else
policy::RetainedState retainedState = {};
#endif

policy::PreviousSnapshot previousSnapshot = {};
portMUX_TYPE snapshotMux = portMUX_INITIALIZER_UNLOCKED;
volatile uint32_t activeBootSequence = 0;
volatile uint32_t activeFirmwareFingerprint = 0;

policy::RetainedRoleSlot &slotFor(Role role) {
  return retainedState.roles[static_cast<std::size_t>(role)];
}

policy::RetainedRoleSlot currentSlot(Role role) {
  policy::RetainedRoleSlot slot = slotFor(role);
  if (!policy::valid(slot) || slot.bootSequence != activeBootSequence ||
      slot.firmwareFingerprint != activeFirmwareFingerprint ||
      slot.role != static_cast<uint8_t>(role)) {
    slot = policy::initialRoleSlot(role, activeBootSequence,
                                   activeFirmwareFingerprint);
  }
  return slot;
}

void writeRole(Role role, Phase phase, uint32_t detail, bool phaseChanged,
               bool forceProgress) {
  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&snapshotMux);
  policy::RetainedRoleSlot slot = currentSlot(role);
  const bool progressDue =
      forceProgress ||
      static_cast<uint32_t>(nowMs - slot.lastProgressUptimeMs) >= 1000U;
  if (!phaseChanged && !progressDue && slot.detail == detail) {
    portEXIT_CRITICAL(&snapshotMux);
    return;
  }
  if (phaseChanged)
    slot.phase = static_cast<uint8_t>(phase);
  if (progressDue || phaseChanged)
    slot.lastProgressUptimeMs = nowMs;
  slot.detail = detail;
  policy::seal(slot);
  slotFor(role) = slot;
  portEXIT_CRITICAL(&snapshotMux);
}

} // namespace

void begin(uint32_t bootSequence, uint32_t firmwareFingerprint,
           bool taskWatchdogReset) {
  portENTER_CRITICAL(&snapshotMux);
  previousSnapshot = policy::beginBoot(retainedState, bootSequence,
                                       firmwareFingerprint,
                                       taskWatchdogReset);
  activeBootSequence = bootSequence;
  activeFirmwareFingerprint = firmwareFingerprint;
  portEXIT_CRITICAL(&snapshotMux);
}

void registerCurrentTask(Role role, Phase initialPhase) {
  const std::size_t index = static_cast<std::size_t>(role);
  if (index >= policy::kRoleCount)
    return;
  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&snapshotMux);
  policy::RetainedRoleSlot slot = currentSlot(role);
  slot.phase = static_cast<uint8_t>(initialPhase);
  slot.lastProgressUptimeMs = nowMs;
  slot.detail = 0;
  slot.core = static_cast<uint8_t>(xPortGetCoreID());
  slot.priority = static_cast<uint8_t>(uxTaskPriorityGet(nullptr));
  policy::seal(slot);
  slotFor(role) = slot;
  portEXIT_CRITICAL(&snapshotMux);
}

void notePhase(Role role, Phase phase, uint32_t detail) {
  const std::size_t index = static_cast<std::size_t>(role);
  if (index >= policy::kRoleCount)
    return;
  writeRole(role, phase, detail, true, true);
}

void heartbeat(Role role, uint32_t detail) {
  const std::size_t index = static_cast<std::size_t>(role);
  if (index >= policy::kRoleCount)
    return;
  const policy::RetainedRoleSlot slot = slotFor(role);
  const Phase phase = policy::valid(slot)
                          ? static_cast<Phase>(slot.phase)
                          : Phase::Unregistered;
  writeRole(role, phase, detail, false, false);
}

bool formatPreviousTaskWatchdogFields(char *out, std::size_t capacity) {
  return policy::formatPreviousFields(previousSnapshot, out, capacity);
}

void captureTaskWatchdogFromIsr(uint32_t watchdogUptimeMs,
                                uint32_t failingCoreMask) {
  policy::RetainedTrigger trigger = {};
  trigger.bootSequence = activeBootSequence;
  trigger.firmwareFingerprint = activeFirmwareFingerprint;
  trigger.watchdogUptimeMs = watchdogUptimeMs;
  trigger.failingCoreMask = failingCoreMask;
  policy::seal(trigger);

  // Publish the checksum last. A reset during this bounded write leaves an
  // invalid trigger, while the independently sealed role slots remain usable.
  retainedState.trigger.checksum = 0;
  retainedState.trigger.magic = trigger.magic;
  retainedState.trigger.bootSequence = trigger.bootSequence;
  retainedState.trigger.firmwareFingerprint = trigger.firmwareFingerprint;
  retainedState.trigger.watchdogUptimeMs = trigger.watchdogUptimeMs;
  retainedState.trigger.failingCoreMask = trigger.failingCoreMask;
  retainedState.trigger.size = trigger.size;
  retainedState.trigger.schema = trigger.schema;
  retainedState.trigger.reserved = 0;
  __atomic_store_n(&retainedState.trigger.checksum, trigger.checksum,
                   __ATOMIC_RELEASE);
}

} // namespace runtime_watchdog_diagnostics

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
namespace {

void discardTaskWatchdogMessage(void *, const char *) {}

} // namespace

extern "C" void esp_task_wdt_isr_user_handler(void) {
  int failingCoreMask = 0;
  (void)esp_task_wdt_print_triggered_tasks(discardTaskWatchdogMessage, nullptr,
                                           &failingCoreMask);
  runtime_watchdog_diagnostics::captureTaskWatchdogFromIsr(
      static_cast<uint32_t>(xTaskGetTickCountFromISR()) * portTICK_PERIOD_MS,
      static_cast<uint32_t>(failingCoreMask));
}
#endif
