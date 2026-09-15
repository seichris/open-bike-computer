#pragma once

#include "boot_diagnostics_policy.hpp"

namespace boot_diagnostics {

using Stage = policy::Stage;
constexpr std::size_t kStructuredSerialTxBufferSize =
    policy::kStructuredSerialTxBufferSize;

// Call once, before initializing board peripherals. This records the new boot
// in RTC no-init memory and reports the previous unfinished stage.
void begin();

// Optional bounded observer, registered from setup before board initialization.
// Called on the setup task only after a successful stage completion (including
// Ready). It must not mutate boot policy. Null preserves standalone/probe paths.
using StageCompletionObserver = void (*)(Stage);
void setStageCompletionObserver(StageCompletionObserver observer);

struct Snapshot {
  uint32_t bootSequence;
  uint32_t firmwareFingerprint;
  uint32_t resetReason;
  Stage activeStage;
  Stage completedStage;
  Stage lastFailureStage;
  Stage lastFailureCompletedStage;
  uint32_t lastFailureResetReason;
  uint8_t consecutiveEarlyFailures;
  bool ready;
  bool safeMode;
  bool diagnosticHold;
};

// Read-only runtime state for structured post-storage diagnostics. This does
// not change the early-boot RTC state machine or touch peripheral ownership.
Snapshot snapshot();

bool safeModeActive();
void enterStage(Stage stage);
void completeStage(Stage stage);
void markReady();
void markDiagnosticHold();

} // namespace boot_diagnostics
