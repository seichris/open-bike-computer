#pragma once

#include <cstdint>

struct GpsRideObservation {
  bool fixAvailable = false;
  bool fixValid = false;
  uint32_t fixCapturedAtMs = 0;
  bool speedAvailable = false;
  float speedMetersPerSecond = 0.0F;
  uint32_t speedCapturedAtMs = 0;
  bool locationAvailable = false;
  double latitude = 0.0;
  double longitude = 0.0;
  uint32_t locationCapturedAtMs = 0;
  bool hdopAvailable = false;
  float hdop = 0.0F;
  uint32_t hdopCapturedAtMs = 0;
};

// Source-neutral firmware boundary used by ride automation. Keeping this
// declaration independent of NeoGPS lets PlatformIO compile consumers without
// inheriting the full GPS parser dependency graph.
GpsRideObservation currentGpsRideObservation();
