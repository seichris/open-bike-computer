#include "boot_diagnostics.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include <Arduino.h>
#include <esp_attr.h>
#include <esp_system.h>

#include "../firmware_metadata/firmware_metadata.hpp"

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 0
#endif

#ifndef POWER_METRICS
#define POWER_METRICS 0
#endif

namespace boot_diagnostics {
namespace {

RTC_NOINIT_ATTR policy::PersistentState persistentState;
bool initialized = false;
bool runtimeSafeMode = false;
uint32_t bootStartedAtMs = 0;

constexpr bool kLogEnabled = FIRMWARE_DIAGNOSTICS || POWER_METRICS;

uint32_t mixString(uint32_t hash, const char *value) {
  if (value != nullptr) {
    while (*value != '\0') {
      hash = policy::mixByte(hash, static_cast<uint8_t>(*value));
      ++value;
    }
  }
  return policy::mixByte(hash, 0);
}

uint32_t firmwareFingerprint() {
  uint32_t hash = 2166136261U;
  hash = mixString(hash, firmware_metadata::target());
  hash = mixString(hash, firmware_metadata::buildProfile());
  hash = mixString(hash, firmware_metadata::version());
  hash = policy::mixU32(hash, firmware_metadata::build());
  hash = mixString(hash, firmware_metadata::gitSha());
  hash = mixString(hash, firmware_metadata::buildTimestamp());
  return hash == 0 ? 1 : hash;
}

const char *resetReasonName(uint32_t reason) {
  // Stable numeric values from esp_reset_reason_t. Keeping the switch numeric
  // also lets the diagnostics build across Arduino/IDF versions that expose a
  // different subset of the newer enum labels.
  switch (reason) {
  case 1:
    return "power_on";
  case 2:
    return "external_pin";
  case 3:
    return "software";
  case 4:
    return "panic";
  case 5:
    return "interrupt_watchdog";
  case 6:
    return "task_watchdog";
  case 7:
    return "watchdog";
  case 8:
    return "deep_sleep";
  case 9:
    return "brownout";
  case 10:
    return "sdio";
  case 11:
    return "usb";
  case 12:
    return "jtag";
  case 13:
    return "efuse";
  case 14:
    return "power_glitch";
  case 15:
    return "cpu_lockup";
  default:
    return "unknown";
  }
}

const char *historyStatus(const policy::BeginResult &result) {
  if (!result.previousValid) {
    return "empty_or_invalid";
  }
  if (result.coldStart) {
    return "cold_power_reset";
  }
  if (!result.previousSameFirmware) {
    return "firmware_changed";
  }
  return "retained";
}

void logStage(const char *event, Stage stage) {
  if (!kLogEnabled) {
    return;
  }
  Serial.printf("BOOT_STAGE schema=1 sequence=%lu event=%s id=%u name=%s "
                "uptimeMs=%lu\n",
                static_cast<unsigned long>(persistentState.bootSequence), event,
                static_cast<unsigned>(stage), policy::stageName(stage),
                static_cast<unsigned long>(millis() - bootStartedAtMs));
}

} // namespace

void begin() {
  if (initialized) {
    return;
  }
  initialized = true;
  bootStartedAtMs = millis();

  const uint32_t resetReason = static_cast<uint32_t>(esp_reset_reason());
  const uint32_t fingerprint = firmwareFingerprint();
  const policy::BeginResult result = policy::beginBoot(
      persistentState, fingerprint, resetReason, resetReason == 1);
  runtimeSafeMode = result.safeMode;

  if (kLogEnabled) {
    Serial.printf("BOOT_META schema=1 sequence=%lu target=%s profile=%s version=%s "
                  "build=%lu git=%s built=%s fingerprint=%08lX reset=%s "
                  "resetCode=%lu\n",
                  static_cast<unsigned long>(persistentState.bootSequence),
                  firmware_metadata::target(),
                  firmware_metadata::buildProfile(),
                  firmware_metadata::version(),
                  static_cast<unsigned long>(firmware_metadata::build()),
                  firmware_metadata::gitSha(),
                  firmware_metadata::buildTimestamp(),
                  static_cast<unsigned long>(fingerprint),
                  resetReasonName(resetReason),
                  static_cast<unsigned long>(resetReason));

    const policy::PersistentState &previous = result.previous;
    Serial.printf("BOOT_PREVIOUS schema=1 history=%s valid=%d sameFirmware=%d "
                  "sequence=%lu fingerprint=%08lX ready=%d safeMode=%d "
                  "diagnosticHold=%d "
                  "reset=%s resetCode=%lu active=%s completed=%s "
                  "failureCount=%u failureStage=%s failureAfter=%s "
                  "failureReset=%s failureResetCode=%lu\n",
                  historyStatus(result), result.previousValid ? 1 : 0,
                  result.previousSameFirmware ? 1 : 0,
                  static_cast<unsigned long>(result.previousValid
                                                 ? previous.bootSequence
                                                 : 0),
                  static_cast<unsigned long>(result.previousValid
                                                 ? previous.firmwareFingerprint
                                                 : 0),
                  result.previousValid && policy::isReady(previous) ? 1 : 0,
                  result.previousValid && policy::isSafeMode(previous) ? 1 : 0,
                  result.previousValid && policy::isDiagnosticHold(previous)
                      ? 1
                      : 0,
                  resetReasonName(result.previousValid ? previous.resetReason
                                                       : 0),
                  static_cast<unsigned long>(result.previousValid
                                                 ? previous.resetReason
                                                 : 0),
                  policy::stageName(static_cast<Stage>(
                      result.previousValid ? previous.activeStage : 0)),
                  policy::stageName(static_cast<Stage>(
                      result.previousValid ? previous.completedStage : 0)),
                  static_cast<unsigned>(
                      result.previousValid ? previous.consecutiveEarlyFailures
                                           : 0),
                  policy::stageName(static_cast<Stage>(
                      result.previousValid ? previous.lastFailureStage : 0)),
                  policy::stageName(static_cast<Stage>(
                      result.previousValid
                          ? previous.lastFailureCompletedStage
                          : 0)),
                  resetReasonName(result.previousValid
                                      ? previous.lastFailureResetReason
                                      : 0),
                  static_cast<unsigned long>(
                      result.previousValid ? previous.lastFailureResetReason
                                           : 0));

    Serial.printf("BOOT_FAILURE schema=1 recorded=%d count=%u threshold=%u "
                  "stage=%s after=%s reset=%s resetCode=%lu safeMode=%d\n",
                  result.failureRecorded ? 1 : 0,
                  static_cast<unsigned>(
                      persistentState.consecutiveEarlyFailures),
                  static_cast<unsigned>(policy::kSafeModeFailureThreshold),
                  policy::stageName(static_cast<Stage>(
                      persistentState.lastFailureStage)),
                  policy::stageName(static_cast<Stage>(
                      persistentState.lastFailureCompletedStage)),
                  resetReasonName(persistentState.lastFailureResetReason),
                  static_cast<unsigned long>(
                      persistentState.lastFailureResetReason),
                  runtimeSafeMode ? 1 : 0);

    if (runtimeSafeMode) {
      Serial.println(
          "BOOT_SAFE_MODE schema=1 active=1 peripherals=skipped "
          "recovery=flash-new-build-or-remove-all-power");
    }
  }

  logStage(runtimeSafeMode ? "hold" : "enter",
           runtimeSafeMode ? Stage::SafeMode : Stage::Startup);
}

bool safeModeActive() { return runtimeSafeMode; }

Snapshot snapshot() {
  if (!initialized) {
    return {0, 0, 0, Stage::None, Stage::None, 0, false, false, false};
  }
  return {
      persistentState.bootSequence,
      persistentState.firmwareFingerprint,
      persistentState.resetReason,
      static_cast<Stage>(persistentState.activeStage),
      static_cast<Stage>(persistentState.completedStage),
      persistentState.consecutiveEarlyFailures,
      policy::isReady(persistentState),
      policy::isSafeMode(persistentState),
      policy::isDiagnosticHold(persistentState),
  };
}

void enterStage(Stage stage) {
  if (!initialized || runtimeSafeMode) {
    return;
  }
  if (policy::enterStage(persistentState, stage)) {
    logStage("enter", stage);
  } else if (kLogEnabled) {
    Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 operation=enter stage=%s\n",
                  policy::stageName(stage));
  }
}

void completeStage(Stage stage) {
  if (!initialized || runtimeSafeMode) {
    return;
  }
  if (policy::completeStage(persistentState, stage)) {
    logStage("complete", stage);
  } else if (kLogEnabled) {
    Serial.printf(
        "BOOT_DIAGNOSTICS_ERROR schema=1 operation=complete stage=%s\n",
        policy::stageName(stage));
  }
}

void markReady() {
  if (!initialized || runtimeSafeMode) {
    return;
  }
  if (policy::markReady(persistentState)) {
    logStage("ready", Stage::Ready);
  } else if (kLogEnabled) {
    Serial.println("BOOT_DIAGNOSTICS_ERROR schema=1 operation=ready");
  }
}

void markDiagnosticHold() {
  if (!initialized || runtimeSafeMode) {
    return;
  }
  if (policy::markDiagnosticHold(persistentState)) {
    logStage("hold", Stage::DiagnosticHold);
  } else if (kLogEnabled) {
    Serial.println(
        "BOOT_DIAGNOSTICS_ERROR schema=1 operation=diagnostic_hold");
  }
}

} // namespace boot_diagnostics

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
