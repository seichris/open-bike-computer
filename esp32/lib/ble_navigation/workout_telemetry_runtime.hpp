#pragma once

#include "workout_telemetry_state.hpp"

#include <cstddef>
#include <cstdint>

namespace workout_telemetry_runtime {

workout_telemetry::ApplyResult ingestFrame(const uint8_t *bytes,
                                           std::size_t length,
                                           uint32_t receivedAtMs,
                                           bool authenticated);

workout_telemetry::Snapshot snapshot(uint32_t nowMs);

bool isWorkoutActive();

void beginAuthenticatedResynchronization();

void reset();

} // namespace workout_telemetry_runtime
