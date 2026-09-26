#pragma once

#include "gps_ride_observation.hpp"
#include <cstdint>

// Timing belongs to the physical source currently populating GPSDATA, not to
// whichever transport most recently updated its diagnostics.
struct GpsSampleTiming {
  bool ageKnown = false;
  bool speedAvailable = false;
  uint32_t capturedAtMs = 0;
  RidePositionSource source = RidePositionSource::None;

  bool fresh(uint32_t nowMs, uint32_t horizonMs = 2500) const {
    return ageKnown && static_cast<uint32_t>(nowMs - capturedAtMs) < horizonMs;
  }
};
