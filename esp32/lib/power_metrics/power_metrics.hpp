#pragma once

#include "power_metrics_schema.hpp"

#include <cstdint>

#ifndef POWER_METRICS
#define POWER_METRICS 0
#endif

namespace power_metrics {

enum class DisplayState : uint8_t {
  Unknown = 0,
  On,
  Off,
};

enum class Pulse : uint8_t {
  DisplayFlush = 0,
  MapRender,
};

struct RuntimeSnapshot {
  IntervalData interval{};
  DisplayState displayState = DisplayState::Unknown;
  uint8_t requestedBrightness = 0;
  uint8_t effectiveBrightness = 0;
};

#if POWER_METRICS

void begin();
void noteLoop(uint32_t nowMs);
void noteLvgl(uint32_t durationUs);
void noteDisplayFlush(uint32_t rotationUs, uint32_t qspiUs,
                      uint32_t totalUs);
void noteDisplayState(DisplayState state, uint8_t requestedBrightness,
                      uint8_t effectiveBrightness);
void noteMapRequest(MapRenderReason reason);
void noteBlePacket(BlePacketClass packetClass);
RuntimeSnapshot snapshotAndReset();
void pulseBegin(Pulse pulse);
void pulseEnd(Pulse pulse);

class MapRenderMeasurement {
public:
  MapRenderMeasurement();
  ~MapRenderMeasurement();
  MapRenderMeasurement(const MapRenderMeasurement &) = delete;
  MapRenderMeasurement &operator=(const MapRenderMeasurement &) = delete;

  void setStageDurations(uint32_t blocksUs, uint32_t drawUs,
                         uint32_t routeUs);
  void finish(bool completed = true);

private:
  uint32_t startUs_ = 0;
  uint32_t reasons_ = 0;
  uint32_t blocksUs_ = 0;
  uint32_t drawUs_ = 0;
  uint32_t routeUs_ = 0;
  bool finished_ = false;
};

#else

inline void begin() {}
inline void noteLoop(uint32_t) {}
inline void noteLvgl(uint32_t) {}
inline void noteDisplayFlush(uint32_t, uint32_t, uint32_t) {}
inline void noteDisplayState(DisplayState, uint8_t, uint8_t) {}
inline void noteMapRequest(MapRenderReason) {}
inline void noteBlePacket(BlePacketClass) {}
inline RuntimeSnapshot snapshotAndReset() { return {}; }
inline void pulseBegin(Pulse) {}
inline void pulseEnd(Pulse) {}

class MapRenderMeasurement {
public:
  void setStageDurations(uint32_t, uint32_t, uint32_t) {}
  void finish(bool = true) {}
};

#endif

} // namespace power_metrics
