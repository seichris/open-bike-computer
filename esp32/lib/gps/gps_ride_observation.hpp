#pragma once

#include <cstdint>
#include <cmath>

enum class RidePositionSource : uint8_t {
  None = 0,
  HardwareNmea,
  AuthenticatedBle,
};

struct GpsRideObservation {
  RidePositionSource source = RidePositionSource::None;
  bool fixAvailable = false;
  bool fixValid = false;
  bool speedAvailable = false;
  float speedMetersPerSecond = 0.0F;
  bool locationAvailable = false;
  double latitude = 0.0;
  double longitude = 0.0;
  bool horizontalUncertaintyAvailable = false;
  float horizontalUncertaintyMeters = 0.0F;
  uint32_t capturedAtMs = 0;
};

inline bool validGpsRideObservation(const GpsRideObservation &value,
                                    uint32_t nowMs,
                                    uint32_t maximumAgeMs) {
  if (value.source == RidePositionSource::None ||
      nowMs - value.capturedAtMs > maximumAgeMs || !value.fixAvailable ||
      (value.speedAvailable &&
       (!std::isfinite(value.speedMetersPerSecond) ||
        value.speedMetersPerSecond < 0.0F))) {
    return false;
  }
  if (!value.fixValid)
    return true;
  return value.locationAvailable && std::isfinite(value.latitude) &&
         std::isfinite(value.longitude) && value.latitude >= -90.0 &&
         value.latitude <= 90.0 && value.longitude >= -180.0 &&
         value.longitude <= 180.0 &&
         value.horizontalUncertaintyAvailable &&
         std::isfinite(value.horizontalUncertaintyMeters) &&
         value.horizontalUncertaintyMeters >= 0.0F;
}

inline GpsRideObservation selectGpsRideObservation(
    const GpsRideObservation &hardware, const GpsRideObservation &ble,
    uint32_t nowMs, uint32_t maximumAgeMs) {
  const bool hardwareValid =
      validGpsRideObservation(hardware, nowMs, maximumAgeMs);
  const bool bleValid = validGpsRideObservation(ble, nowMs, maximumAgeMs);
  if (!hardwareValid)
    return bleValid ? ble : GpsRideObservation{};
  if (!bleValid)
    return hardware;
  if (hardware.fixValid != ble.fixValid)
    return hardware.fixValid ? hardware : ble;
  if (hardware.fixValid &&
      hardware.horizontalUncertaintyMeters !=
          ble.horizontalUncertaintyMeters) {
    return hardware.horizontalUncertaintyMeters <
                   ble.horizontalUncertaintyMeters
               ? hardware
               : ble;
  }
  return static_cast<int32_t>(hardware.capturedAtMs - ble.capturedAtMs) >= 0
             ? hardware
             : ble;
}

// Source-neutral firmware boundary used by ride automation. Keeping this
// declaration independent of NeoGPS lets PlatformIO compile consumers without
// inheriting the full GPS parser dependency graph.
void publishHardwareGpsRideObservation(const GpsRideObservation &observation);
void publishAuthenticatedBleGpsRideObservation(
    const GpsRideObservation &observation);
void clearAuthenticatedBleGpsRideObservation();
GpsRideObservation currentGpsRideObservation(uint32_t nowMs,
                                             uint32_t maximumAgeMs);
