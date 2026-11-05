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
  Transfer = 3,
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
  ConnectionParameters transfer;
};

constexpr Configuration kConfiguration{
    BLE_RADIO_CHARACTERIZATION != 0,
    BLE_TX_POWER_DBM,
    30000,
    {160, 320},   // 100-200 ms in 0.625 ms units.
    {1440, 1760}, // 900-1100 ms in 0.625 ms units.
    {24, 40, 0, 400}, // 30-50 ms, zero latency, four-second timeout.
    {48, 80, 4, 600}, // 60-100 ms, latency four, six-second timeout.
    // Transfers: the navigation interval with zero latency, so a phone write
    // never waits for the peripheral's next listening event, and the idle
    // profile's six-second supervision timeout, which keeps the owner link
    // alive while Wi-Fi, TLS and SD hashing compete with BLE. With latency
    // four the peripheral listened only every fifth event: each write waited
    // up to half a second, and every event lost to Wi-Fi cost another half
    // second (phone write replies of 1 to 10 s during transfers on
    // 2026-11-05, with the device's host task never late).
    {24, 40, 0, 600}, // 30-50 ms, zero latency, six-second timeout.
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
         isValid(configuration.navigation) && isValid(configuration.idle) &&
         isValid(configuration.transfer);
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
         : profile == ConnectionProfile::Transfer ? kConfiguration.transfer
                                                  : kConfiguration.idle;
}

// The central's own limits for a peripheral request (Apple accessory design
// guidelines): an interval of at least 15 ms with 15 ms between minimum and
// maximum, latency at most 30, a 2 to 6 s supervision timeout longer than
// three effective intervals, and an effective interval of at most 2 s.
// Computed exactly in quarter milliseconds: an interval unit is 1.25 ms (5
// quarters) and a timeout unit 10 ms (40 quarters), so no rounding can let a
// request just over a limit pass.
constexpr bool acceptableToPhone(const ConnectionParameters &parameters) {
  const uint32_t minimumQuarters =
      static_cast<uint32_t>(parameters.minimumIntervalUnits) * 5;
  const uint32_t maximumQuarters =
      static_cast<uint32_t>(parameters.maximumIntervalUnits) * 5;
  const uint32_t effectiveQuarters =
      maximumQuarters * (static_cast<uint32_t>(parameters.latency) + 1);
  const uint32_t timeoutQuarters =
      static_cast<uint32_t>(parameters.supervisionTimeoutUnits) * 40;
  return minimumQuarters >= 60 && minimumQuarters + 60 <= maximumQuarters &&
         parameters.latency <= 30 && timeoutQuarters >= 8000 &&
         timeoutQuarters <= 24000 && effectiveQuarters * 3 < timeoutQuarters &&
         effectiveQuarters <= 8000;
}

static_assert(isValid(kConfiguration));
static_assert(acceptableToPhone(kConfiguration.navigation));
static_assert(acceptableToPhone(kConfiguration.idle));
static_assert(acceptableToPhone(kConfiguration.transfer));
static_assert(kConfiguration.transfer.latency == 0 &&
                  kConfiguration.transfer.supervisionTimeoutUnits ==
                      kConfiguration.idle.supervisionTimeoutUnits,
              "transfers keep the long timeout without peripheral latency");
static_assert(kConfiguration.characterizationEnabled ||
                  kConfiguration.txPowerDbm == 9,
              "non-default BLE TX power is characterization-only");

} // namespace ble_radio_policy
