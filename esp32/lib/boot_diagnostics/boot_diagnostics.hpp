#pragma once

#include "boot_diagnostics_policy.hpp"

namespace boot_diagnostics {

using Stage = policy::Stage;
constexpr std::size_t kStructuredSerialTxBufferSize =
    policy::kStructuredSerialTxBufferSize;

// Call once, before initializing board peripherals. This records the new boot
// in RTC no-init memory and reports the previous unfinished stage.
void begin();

bool safeModeActive();
void enterStage(Stage stage);
void completeStage(Stage stage);
void markReady();
void markDiagnosticHold();

} // namespace boot_diagnostics
