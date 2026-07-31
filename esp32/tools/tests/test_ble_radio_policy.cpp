#include "../../lib/ble_navigation/ble_radio_policy.hpp"

#include <cassert>
#include <cstdint>

int main() {
  using namespace ble_radio_policy;

  static_assert(kConfiguration.characterizationEnabled ==
                (BLE_RADIO_CHARACTERIZATION != 0));
  static_assert(kConfiguration.txPowerDbm == BLE_TX_POWER_DBM);
  static_assert(isValid(kConfiguration));
  static_assert(isSupportedTxPowerDbm(9));
  static_assert(isSupportedTxPowerDbm(3));
  static_assert(isSupportedTxPowerDbm(0));
  static_assert(!isSupportedTxPowerDbm(6));

  assert(advertisingModeForElapsed(0) == AdvertisingMode::Fast);
  assert(advertisingModeForElapsed(29999) == AdvertisingMode::Fast);
  assert(advertisingModeForElapsed(30000) == AdvertisingMode::Slow);
  assert(advertisingModeForElapsed(UINT32_MAX) == AdvertisingMode::Slow);
  assert(nextAdvertisingMode(AdvertisingMode::Default, 0, false) ==
         AdvertisingMode::Fast);
  assert(nextAdvertisingMode(AdvertisingMode::Fast, 29999, false) ==
         AdvertisingMode::Fast);
  assert(nextAdvertisingMode(AdvertisingMode::Fast, 30000, false) ==
         AdvertisingMode::Slow);
  assert(nextAdvertisingMode(AdvertisingMode::Slow, 0, false) ==
         AdvertisingMode::Slow);
  assert(nextAdvertisingMode(AdvertisingMode::Slow, UINT32_MAX, false) ==
         AdvertisingMode::Slow);
  assert(nextAdvertisingMode(AdvertisingMode::Slow, 0, true) ==
         AdvertisingMode::Fast);

  assert(connectionProfile(true) == ConnectionProfile::Navigation);
  assert(connectionProfile(false) == ConnectionProfile::Idle);
  assert(connectionParameters(ConnectionProfile::Navigation).latency == 0);
  assert(connectionParameters(ConnectionProfile::Idle).latency == 4);

  assert(isValid(IntervalRange{160, 320}));
  assert(!isValid(IntervalRange{31, 320}));
  assert(!isValid(IntervalRange{320, 160}));
  assert(isValid(ConnectionParameters{24, 40, 0, 400}));
  assert(!isValid(ConnectionParameters{40, 24, 0, 400}));
  assert(!isValid(ConnectionParameters{48, 80, 499, 10}));
  return 0;
}
