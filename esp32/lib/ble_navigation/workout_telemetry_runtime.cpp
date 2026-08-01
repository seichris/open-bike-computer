#include "workout_telemetry_runtime.hpp"

#include <Arduino.h>

namespace {

portMUX_TYPE workoutTelemetryMux = portMUX_INITIALIZER_UNLOCKED;
workout_telemetry::AuthenticatedResynchronizer workoutTelemetryReducer;

} // namespace

namespace workout_telemetry_runtime {

workout_telemetry::ApplyResult ingestFrame(const uint8_t *bytes,
                                           std::size_t length,
                                           uint32_t receivedAtMs,
                                           bool authenticated) {
  portENTER_CRITICAL(&workoutTelemetryMux);
  const workout_telemetry::ApplyResult result =
      workoutTelemetryReducer.applyFrame(bytes, length, receivedAtMs,
                                         authenticated);
  portEXIT_CRITICAL(&workoutTelemetryMux);
  return result;
}

workout_telemetry::Snapshot snapshot(uint32_t nowMs) {
  portENTER_CRITICAL(&workoutTelemetryMux);
  const workout_telemetry::State state = workoutTelemetryReducer.state();
  portEXIT_CRITICAL(&workoutTelemetryMux);
  return workout_telemetry::makeSnapshot(state, nowMs);
}

bool isWorkoutActive() {
  portENTER_CRITICAL(&workoutTelemetryMux);
  const bool active =
      workout_telemetry::isActiveWorkout(workoutTelemetryReducer.state());
  portEXIT_CRITICAL(&workoutTelemetryMux);
  return active;
}

void beginAuthenticatedResynchronization() {
  portENTER_CRITICAL(&workoutTelemetryMux);
  workoutTelemetryReducer.beginResynchronization();
  portEXIT_CRITICAL(&workoutTelemetryMux);
}

void reset() {
  portENTER_CRITICAL(&workoutTelemetryMux);
  workoutTelemetryReducer.reset();
  portEXIT_CRITICAL(&workoutTelemetryMux);
}

} // namespace workout_telemetry_runtime
