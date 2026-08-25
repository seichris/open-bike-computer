#pragma once

#include "runtime_watchdog_policy.hpp"

#include <cstddef>
#include <cstdint>

namespace runtime_watchdog_diagnostics {

using Role = policy::Role;
using Phase = policy::Phase;

// Initialize the retained recorder before board services and worker tasks
// start. Only an ESP task-watchdog reset may expose the previous boot.
void begin(uint32_t bootSequence, uint32_t firmwareFingerprint,
           bool taskWatchdogReset);

// Each role has a single task owner. Updates are checksum-sealed independently
// so a reset during one write cannot invalidate the other task snapshots.
void registerCurrentTask(Role role, Phase initialPhase);
void notePhase(Role role, Phase phase, uint32_t detail = 0);
void heartbeat(Role role, uint32_t detail = 0);

// Returns one allowlisted, privacy-safe diagnostics object describing the
// previous task-watchdog boot. The snapshot is retained in RAM after begin().
bool formatPreviousTaskWatchdogFields(char *out, std::size_t capacity);

// Called only by the ESP-IDF task-watchdog user ISR hook.
void captureTaskWatchdogFromIsr(uint32_t watchdogUptimeMs,
                                uint32_t failingCoreMask);

} // namespace runtime_watchdog_diagnostics
