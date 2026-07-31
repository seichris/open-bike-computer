#pragma once

#include <cstdint>

#ifndef BLE_RADIO_CHARACTERIZATION
#define BLE_RADIO_CHARACTERIZATION 0
#endif

#ifndef BLE_TX_POWER_DBM
#define BLE_TX_POWER_DBM 9
#endif

namespace ble_radio_policy {

enum class AdvertisingMode : uint8_t {
  Default = 0,
  Fast = 1,
  Slow = 2,
};

enum class ConnectionProfile : uint8_t {
  Unset = 0,
  Navigation = 1,
  Idle = 2,
};

struct IntervalRange {
  uint16_t minimumUnits;
  uint16_t maximumUnits;
};

struct ConnectionParameters {
  uint16_t minimumIntervalUnits;
  uint16_t maximumIntervalUnits;
  uint16_t latency;
  uint16_t supervisionTimeoutUnits;
};

struct Configuration {
  bool characterizationEnabled;
  int8_t txPowerDbm;
  uint32_t fastAdvertisingWindowMs;
  IntervalRange fastAdvertising;
  IntervalRange slowAdvertising;
  ConnectionParameters navigation;
  ConnectionParameters idle;
};

constexpr Configuration kConfiguration{
    BLE_RADIO_CHARACTERIZATION != 0,
    BLE_TX_POWER_DBM,
    30000,
    {160, 320},   // 100-200 ms in 0.625 ms units.
    {1440, 1760}, // 900-1100 ms in 0.625 ms units.
    {24, 40, 0, 400}, // 30-50 ms, zero latency, four-second timeout.
    {48, 80, 4, 600}, // 60-100 ms, latency four, six-second timeout.
};

constexpr bool isSupportedTxPowerDbm(int txPowerDbm) {
  return txPowerDbm == 9 || txPowerDbm == 3 || txPowerDbm == 0;
}

constexpr bool isValid(const IntervalRange &range) {
  return range.minimumUnits >= 0x20 &&
         range.minimumUnits <= range.maximumUnits &&
         range.maximumUnits <= 0x4000;
}

constexpr bool isValid(const ConnectionParameters &parameters) {
  return parameters.minimumIntervalUnits >= 0x06 &&
         parameters.minimumIntervalUnits <= parameters.maximumIntervalUnits &&
         parameters.maximumIntervalUnits <= 0x0C80 &&
         parameters.latency <= 499 &&
         parameters.supervisionTimeoutUnits >= 10 &&
         parameters.supervisionTimeoutUnits <= 3200 &&
         static_cast<uint32_t>(parameters.supervisionTimeoutUnits) * 8 >
             static_cast<uint32_t>(parameters.latency + 1) * 2 *
                 parameters.maximumIntervalUnits;
}

constexpr bool isValid(const Configuration &configuration) {
  return isSupportedTxPowerDbm(configuration.txPowerDbm) &&
         configuration.fastAdvertisingWindowMs > 0 &&
         isValid(configuration.fastAdvertising) &&
         isValid(configuration.slowAdvertising) &&
         isValid(configuration.navigation) && isValid(configuration.idle);
}

constexpr AdvertisingMode advertisingModeForElapsed(uint32_t elapsedMs) {
  return elapsedMs < kConfiguration.fastAdvertisingWindowMs
             ? AdvertisingMode::Fast
             : AdvertisingMode::Slow;
}

constexpr AdvertisingMode nextAdvertisingMode(AdvertisingMode currentMode,
                                               uint32_t elapsedMs,
                                               bool userWakeRequested) {
  if (userWakeRequested) {
    return AdvertisingMode::Fast;
  }
  if (currentMode == AdvertisingMode::Default) {
    return AdvertisingMode::Fast;
  }
  if (currentMode == AdvertisingMode::Slow) {
    return AdvertisingMode::Slow;
  }
  return advertisingModeForElapsed(elapsedMs);
}

constexpr ConnectionProfile connectionProfile(bool navigationActive) {
  return navigationActive ? ConnectionProfile::Navigation
                          : ConnectionProfile::Idle;
}

constexpr const ConnectionParameters &
connectionParameters(ConnectionProfile profile) {
  return profile == ConnectionProfile::Navigation ? kConfiguration.navigation
                                                   : kConfiguration.idle;
}

static_assert(isValid(kConfiguration));
static_assert(kConfiguration.characterizationEnabled ||
                  kConfiguration.txPowerDbm == 9,
              "non-default BLE TX power is characterization-only");

} // namespace ble_radio_policy
