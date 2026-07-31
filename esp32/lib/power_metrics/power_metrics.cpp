#include "power_metrics.hpp"

#if POWER_METRICS

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>

#ifndef POWER_METRICS_PULSE_GPIO
#define POWER_METRICS_PULSE_GPIO -1
#endif

namespace power_metrics {
namespace {

portMUX_TYPE metricsMux = portMUX_INITIALIZER_UNLOCKED;
IntervalAccumulator accumulator;
DisplayState displayState = DisplayState::Unknown;
uint8_t requestedBrightness = 0;
uint8_t effectiveBrightness = 0;
uint32_t pendingMapReasons = 0;
bool pulseReady = false;

uint32_t consumeMapReasons() {
  portENTER_CRITICAL(&metricsMux);
  uint32_t reasons = pendingMapReasons;
  pendingMapReasons = 0;
  portEXIT_CRITICAL(&metricsMux);
  if (reasons == 0) {
    reasons = reasonMask(MapRenderReason::Other);
  }
  return reasons;
}

} // namespace

void begin() {
#if POWER_METRICS_PULSE_GPIO >= 0
  pinMode(POWER_METRICS_PULSE_GPIO, OUTPUT);
  digitalWrite(POWER_METRICS_PULSE_GPIO, LOW);
  pulseReady = true;
#endif
}

void noteLoop(uint32_t nowMs) {
  portENTER_CRITICAL(&metricsMux);
  accumulator.noteLoop(nowMs);
  portEXIT_CRITICAL(&metricsMux);
}

void noteLvgl(uint32_t durationUs) {
  portENTER_CRITICAL(&metricsMux);
  accumulator.noteLvgl(durationUs);
  portEXIT_CRITICAL(&metricsMux);
}

void noteDisplayFlush(uint32_t rotationUs, uint32_t qspiUs,
                      uint32_t totalUs) {
  portENTER_CRITICAL(&metricsMux);
  accumulator.noteDisplayFlush(rotationUs, qspiUs, totalUs);
  portEXIT_CRITICAL(&metricsMux);
}

void noteDisplayState(DisplayState state, uint8_t requested,
                      uint8_t effective) {
  portENTER_CRITICAL(&metricsMux);
  displayState = state;
  requestedBrightness = requested;
  effectiveBrightness = effective;
  portEXIT_CRITICAL(&metricsMux);
}

void noteMapRequest(MapRenderReason reason) {
  portENTER_CRITICAL(&metricsMux);
  pendingMapReasons |= reasonMask(reason);
  portEXIT_CRITICAL(&metricsMux);
}

void noteBlePacket(BlePacketClass packetClass) {
  portENTER_CRITICAL(&metricsMux);
  accumulator.noteBlePacket(packetClass);
  portEXIT_CRITICAL(&metricsMux);
}

RuntimeSnapshot snapshotAndReset() {
  portENTER_CRITICAL(&metricsMux);
  RuntimeSnapshot snapshot;
  snapshot.interval = accumulator.snapshotAndReset();
  snapshot.displayState = displayState;
  snapshot.requestedBrightness = requestedBrightness;
  snapshot.effectiveBrightness = effectiveBrightness;
  portEXIT_CRITICAL(&metricsMux);
  return snapshot;
}

void pulseBegin(Pulse) {
#if POWER_METRICS_PULSE_GPIO >= 0
  if (pulseReady) {
    digitalWrite(POWER_METRICS_PULSE_GPIO, HIGH);
  }
#endif
}

void pulseEnd(Pulse) {
#if POWER_METRICS_PULSE_GPIO >= 0
  if (pulseReady) {
    digitalWrite(POWER_METRICS_PULSE_GPIO, LOW);
  }
#endif
}

MapRenderMeasurement::MapRenderMeasurement()
    : startUs_(micros()), reasons_(consumeMapReasons()) {
  pulseBegin(Pulse::MapRender);
}

MapRenderMeasurement::~MapRenderMeasurement() {
  if (!finished_) {
    finish(false);
  }
}

void MapRenderMeasurement::setStageDurations(uint32_t blocksUs,
                                             uint32_t drawUs,
                                             uint32_t routeUs) {
  blocksUs_ = blocksUs;
  drawUs_ = drawUs;
  routeUs_ = routeUs;
}

void MapRenderMeasurement::finish(bool completed) {
  if (finished_) {
    return;
  }
  const uint32_t totalUs = micros() - startUs_;
  portENTER_CRITICAL(&metricsMux);
  accumulator.noteMapRender(completed, totalUs, blocksUs_, drawUs_, routeUs_,
                            reasons_);
  portEXIT_CRITICAL(&metricsMux);
  pulseEnd(Pulse::MapRender);
  finished_ = true;
}

} // namespace power_metrics

#endif
