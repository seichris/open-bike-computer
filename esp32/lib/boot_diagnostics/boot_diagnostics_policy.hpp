#pragma once

#include <cstddef>
#include <cstdint>

namespace boot_diagnostics::policy {

constexpr uint32_t kStateMagic = 0x424F4F54; // "BOOT"
constexpr uint16_t kStateSchema = 1;
constexpr uint8_t kSafeModeFailureThreshold = 3;
// BOOT_PREVIOUS is intentionally a single structured record. Keep enough USB
// CDC buffering for that record, power-metrics reports, and future fields to
// survive the host-attach window without truncating the diagnostic tail.
constexpr std::size_t kStructuredSerialTxBufferSize = 4096;

enum class Stage : uint8_t {
  None = 0,
  Startup = 1,
  CoreServices = 2,
  WakeConfiguration = 3,
  I2cBus = 4,
  PmicInspection = 5,
  ClockAndSensors = 6,
  Display = 7,
  Storage = 8,
  MapRecovery = 9,
  ApplicationServices = 10,
  UserInterface = 11,
  Speaker = 12,
  Ble = 13,
  Finalization = 14,
  Ready = 15,
  SafeMode = 16,
  DiagnosticHold = 17,
};

constexpr const char *stageName(Stage stage) {
  switch (stage) {
  case Stage::None:
    return "none";
  case Stage::Startup:
    return "startup";
  case Stage::CoreServices:
    return "core_services";
  case Stage::WakeConfiguration:
    return "wake_configuration";
  case Stage::I2cBus:
    return "i2c_bus";
  case Stage::PmicInspection:
    return "pmic_inspection";
  case Stage::ClockAndSensors:
    return "clock_and_sensors";
  case Stage::Display:
    return "display";
  case Stage::Storage:
    return "storage";
  case Stage::MapRecovery:
    return "map_recovery";
  case Stage::ApplicationServices:
    return "application_services";
  case Stage::UserInterface:
    return "user_interface";
  case Stage::Speaker:
    return "speaker";
  case Stage::Ble:
    return "ble";
  case Stage::Finalization:
    return "finalization";
  case Stage::Ready:
    return "ready";
  case Stage::SafeMode:
    return "safe_mode";
  case Stage::DiagnosticHold:
    return "diagnostic_hold";
  }
  return "invalid";
}

constexpr bool isKnownStage(uint8_t stage) {
  return stage <= static_cast<uint8_t>(Stage::DiagnosticHold);
}

constexpr uint8_t kFlagReady = 1U << 0;
constexpr uint8_t kFlagSafeMode = 1U << 1;
constexpr uint8_t kFlagDiagnosticHold = 1U << 2;
constexpr uint8_t kKnownFlags =
    kFlagReady | kFlagSafeMode | kFlagDiagnosticHold;

// RTC no-init memory preserves this state across software, watchdog, panic,
// brownout, and USB resets. A magic/version/size/checksum envelope makes
// uninitialized cold-boot memory fail closed as an empty history.
struct PersistentState {
  uint32_t magic;
  uint16_t schema;
  uint16_t size;
  uint32_t firmwareFingerprint;
  uint32_t bootSequence;
  uint32_t resetReason;
  uint8_t activeStage;
  uint8_t completedStage;
  uint8_t lastFailureStage;
  uint8_t lastFailureCompletedStage;
  uint8_t consecutiveEarlyFailures;
  uint8_t flags;
  uint8_t lastFailureResetReason;
  uint8_t reserved;
  uint32_t checksum;
};

static_assert(sizeof(PersistentState) == 32,
              "boot state layout is part of the RTC-memory schema");

struct BeginResult {
  PersistentState previous;
  bool previousValid;
  bool previousSameFirmware;
  bool coldStart;
  bool failureRecorded;
  bool safeMode;
};

constexpr uint32_t mixByte(uint32_t hash, uint8_t value) {
  return (hash ^ value) * 16777619U;
}

constexpr uint32_t mixU16(uint32_t hash, uint16_t value) {
  hash = mixByte(hash, static_cast<uint8_t>(value));
  return mixByte(hash, static_cast<uint8_t>(value >> 8));
}

constexpr uint32_t mixU32(uint32_t hash, uint32_t value) {
  hash = mixU16(hash, static_cast<uint16_t>(value));
  return mixU16(hash, static_cast<uint16_t>(value >> 16));
}

constexpr uint32_t checksum(const PersistentState &state) {
  uint32_t hash = 2166136261U;
  hash = mixU32(hash, state.magic);
  hash = mixU16(hash, state.schema);
  hash = mixU16(hash, state.size);
  hash = mixU32(hash, state.firmwareFingerprint);
  hash = mixU32(hash, state.bootSequence);
  hash = mixU32(hash, state.resetReason);
  hash = mixByte(hash, state.activeStage);
  hash = mixByte(hash, state.completedStage);
  hash = mixByte(hash, state.lastFailureStage);
  hash = mixByte(hash, state.lastFailureCompletedStage);
  hash = mixByte(hash, state.consecutiveEarlyFailures);
  hash = mixByte(hash, state.flags);
  hash = mixByte(hash, state.lastFailureResetReason);
  return mixByte(hash, state.reserved);
}

inline void seal(PersistentState &state) { state.checksum = checksum(state); }

constexpr bool isValid(const PersistentState &state) {
  if (state.magic != kStateMagic || state.schema != kStateSchema ||
      state.size != sizeof(PersistentState) || state.reserved != 0 ||
      (state.flags & ~kKnownFlags) != 0 ||
      !isKnownStage(state.activeStage) ||
      !isKnownStage(state.completedStage) ||
      !isKnownStage(state.lastFailureStage) ||
      !isKnownStage(state.lastFailureCompletedStage) ||
      state.checksum != checksum(state)) {
    return false;
  }

  const bool ready = (state.flags & kFlagReady) != 0;
  const bool safeMode = (state.flags & kFlagSafeMode) != 0;
  const bool diagnosticHold = (state.flags & kFlagDiagnosticHold) != 0;
  if (ready &&
      (state.activeStage != static_cast<uint8_t>(Stage::Ready) ||
       state.completedStage != static_cast<uint8_t>(Stage::Ready))) {
    return false;
  }
  if (safeMode &&
      state.activeStage != static_cast<uint8_t>(Stage::SafeMode)) {
    return false;
  }
  if (diagnosticHold &&
      state.activeStage != static_cast<uint8_t>(Stage::DiagnosticHold)) {
    return false;
  }
  return static_cast<unsigned>(ready) + static_cast<unsigned>(safeMode) +
             static_cast<unsigned>(diagnosticHold) <=
         1;
}

constexpr bool isReady(const PersistentState &state) {
  return (state.flags & kFlagReady) != 0;
}

constexpr bool isSafeMode(const PersistentState &state) {
  return (state.flags & kFlagSafeMode) != 0;
}

constexpr bool isDiagnosticHold(const PersistentState &state) {
  return (state.flags & kFlagDiagnosticHold) != 0;
}

constexpr uint8_t incrementSaturating(uint8_t value) {
  return value == UINT8_MAX ? value : static_cast<uint8_t>(value + 1);
}

inline BeginResult beginBoot(PersistentState &state,
                             uint32_t firmwareFingerprint,
                             uint32_t resetReason, bool coldStart) {
  const PersistentState previous = state;
  const bool previousValid = isValid(previous);
  const bool sameFirmware =
      previousValid &&
      previous.firmwareFingerprint == firmwareFingerprint;
  const bool retainHistory = previousValid && sameFirmware && !coldStart;

  uint32_t sequence = 1;
  uint8_t failures = 0;
  uint8_t lastFailure = static_cast<uint8_t>(Stage::None);
  uint8_t lastFailureCompleted = static_cast<uint8_t>(Stage::None);
  uint8_t lastFailureResetReason = 0;
  bool failureRecorded = false;

  if (retainHistory) {
    sequence = previous.bootSequence + 1;
    if (sequence == 0) {
      sequence = 1;
    }
    lastFailure = previous.lastFailureStage;
    lastFailureCompleted = previous.lastFailureCompletedStage;
    lastFailureResetReason = previous.lastFailureResetReason;

    if (isReady(previous) || isDiagnosticHold(previous)) {
      failures = 0;
      lastFailure = static_cast<uint8_t>(Stage::None);
      lastFailureCompleted = static_cast<uint8_t>(Stage::None);
      lastFailureResetReason = 0;
    } else if (isSafeMode(previous)) {
      // Safe mode is a deliberate hold, not another failed initialization.
      failures = previous.consecutiveEarlyFailures;
    } else {
      failures = incrementSaturating(previous.consecutiveEarlyFailures);
      lastFailure = previous.activeStage;
      lastFailureCompleted = previous.completedStage;
      // esp_reset_reason() on this boot describes how the unfinished previous
      // boot ended. Preserve that final cause across subsequent safe-mode
      // resets and diagnostic rescue flashes.
      lastFailureResetReason = static_cast<uint8_t>(resetReason);
      failureRecorded = true;
    }
  }

  const bool safeMode = failures >= kSafeModeFailureThreshold;
  state = {
      kStateMagic,
      kStateSchema,
      static_cast<uint16_t>(sizeof(PersistentState)),
      firmwareFingerprint,
      sequence,
      resetReason,
      static_cast<uint8_t>(safeMode ? Stage::SafeMode : Stage::Startup),
      static_cast<uint8_t>(Stage::None),
      lastFailure,
      lastFailureCompleted,
      failures,
      static_cast<uint8_t>(safeMode ? kFlagSafeMode : 0),
      lastFailureResetReason,
      0,
      0,
  };
  seal(state);

  return {previous, previousValid, sameFirmware, coldStart, failureRecorded,
          safeMode};
}

inline bool enterStage(PersistentState &state, Stage stage) {
  if (!isValid(state) || isReady(state) || isSafeMode(state) ||
      isDiagnosticHold(state) ||
      stage == Stage::None || stage == Stage::Ready ||
      stage == Stage::SafeMode || stage == Stage::DiagnosticHold) {
    return false;
  }
  state.activeStage = static_cast<uint8_t>(stage);
  seal(state);
  return true;
}

inline bool completeStage(PersistentState &state, Stage stage) {
  if (!isValid(state) || isReady(state) || isSafeMode(state) ||
      isDiagnosticHold(state) ||
      state.activeStage != static_cast<uint8_t>(stage) ||
      stage == Stage::None || stage == Stage::Ready ||
      stage == Stage::SafeMode || stage == Stage::DiagnosticHold) {
    return false;
  }
  state.completedStage = static_cast<uint8_t>(stage);
  state.activeStage = static_cast<uint8_t>(Stage::None);
  seal(state);
  return true;
}

inline bool markReady(PersistentState &state) {
  if (!isValid(state) || isSafeMode(state) || isDiagnosticHold(state)) {
    return false;
  }
  state.activeStage = static_cast<uint8_t>(Stage::Ready);
  state.completedStage = static_cast<uint8_t>(Stage::Ready);
  state.lastFailureStage = static_cast<uint8_t>(Stage::None);
  state.lastFailureCompletedStage = static_cast<uint8_t>(Stage::None);
  state.consecutiveEarlyFailures = 0;
  state.flags = kFlagReady;
  state.lastFailureResetReason = 0;
  seal(state);
  return true;
}

// Diagnostic images can intentionally stop after a partial bring-up. Record
// that terminal state separately from full application readiness so repeated
// probe resets neither count as crashes nor satisfy a normal ready gate.
inline bool markDiagnosticHold(PersistentState &state) {
  if (!isValid(state) || isReady(state) || isSafeMode(state) ||
      isDiagnosticHold(state) ||
      state.activeStage != static_cast<uint8_t>(Stage::None) ||
      state.completedStage == static_cast<uint8_t>(Stage::None)) {
    return false;
  }
  state.activeStage = static_cast<uint8_t>(Stage::DiagnosticHold);
  state.lastFailureStage = static_cast<uint8_t>(Stage::None);
  state.lastFailureCompletedStage = static_cast<uint8_t>(Stage::None);
  state.consecutiveEarlyFailures = 0;
  state.flags = kFlagDiagnosticHold;
  state.lastFailureResetReason = 0;
  seal(state);
  return true;
}

} // namespace boot_diagnostics::policy
