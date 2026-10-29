// Arduino.h defines bit() before the main screen includes this registry.
#define bit(b) (1UL << (b))
#include "../../lib/gui/src/mainScreenRegistry.hpp"
#undef bit

#include <cassert>
#include <iostream>

int main() {
  using namespace main_screen_registry;

  static_assert(!world_radio_config::supportsClient(23));
  static_assert(world_radio_config::supportsClient(25) ==
                world_radio_config::ENABLED);
  static_assert(world_radio_config::supportsClient(255) ==
                world_radio_config::ENABLED);
  static_assert(!route_elevation_config::supportsClient(31));
  static_assert(route_elevation_config::supportsClient(32) == route_elevation_config::ENABLED);
  constexpr uint8_t expectedSupported = static_cast<uint8_t>(
      0x1F | (world_radio_config::ENABLED ? 0x20 : 0) |
      (route_elevation_config::ENABLED ? 0x40 : 0) |
      (map_profile_protocol::POIS_RUNTIME_ENABLED ? 0x80 : 0));
  static_assert(SUPPORTED_MASK == expectedSupported);
#if ROUTE_ELEVATION_SCREEN_ENABLED
  static_assert(deviceScreenForTile(ELEVATION) == 6);
  static_assert(tileForDeviceScreen(6) == ELEVATION);
  static_assert(!isMapBacked(ELEVATION));
  assert(nextEnabled(RIDESTATS, SUPPORTED_MASK) == ELEVATION);
  assert(nextEnabled(ELEVATION, SUPPORTED_MASK) == MAP);
  assert(nextEnabled(RIDESTATS, static_cast<uint8_t>(SUPPORTED_MASK & ~screenBit(DeviceScreenId::Elevation))) == MAP);
  assert(previousEnabled(MAP, SUPPORTED_MASK) == ELEVATION);
  static_assert(normalizedDefault(6, 0x40) == 6);
#else
  static_assert(descriptorForTile(ELEVATION) == nullptr);
  static_assert(descriptorForDeviceScreen(6) == nullptr);
  static_assert(normalizedDefault(6, 0x7F) == 3);
#endif
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
  static_assert(deviceScreenForTile(WORLD_RADIO) == 5);
  static_assert(tileForDeviceScreen(5) == WORLD_RADIO);
  assert(nextEnabled(NAV, SUPPORTED_MASK) == WORLD_RADIO);
  assert(nextEnabled(WORLD_RADIO, SUPPORTED_MASK) == BATTERY_STATUS);
#else
  static_assert(descriptorForTile(WORLD_RADIO) == nullptr);
  static_assert(descriptorForDeviceScreen(5) == nullptr);
  static_assert(normalizedMask(0x3F) == 0x1F);
  static_assert(normalizedDefault(5, 0x3F) == 3);
  assert(nextEnabled(NAV, SUPPORTED_MASK) == BATTERY_STATUS);
#endif
  // Elevation (6) and Nearby (7) coexist in POI qualification builds, and
  // both remain opt-in like World Radio.
  static_assert((DEFAULT_MASK & screenBit(DeviceScreenId::Elevation)) == 0);
#if MAP_POIS_RUNTIME_ENABLED
  static_assert(deviceScreenForTile(NEARBY) == 7);
  static_assert(tileForDeviceScreen(7) == NEARBY);
  assert(nextEnabled(MAP, SUPPORTED_MASK) == NEARBY);
  assert(previousEnabled(NAV, SUPPORTED_MASK) == NEARBY);
  static_assert(normalizedDefault(7, 0x80) == 7);
#else
  static_assert(descriptorForTile(NEARBY) == nullptr);
  static_assert(descriptorForDeviceScreen(7) == nullptr);
  static_assert(normalizedDefault(7, 0xFF) == 3);
  assert(nextEnabled(MAP, SUPPORTED_MASK) == NAV);
#endif
  static_assert(isMapBacked(MAP));
  static_assert(DEFAULT_MASK == 0x1F);
  static_assert(normalizedMask(0) == DEFAULT_MASK);
  static_assert((DEFAULT_MASK & screenBit(DeviceScreenId::Nearby)) == 0);
  static_assert(isMapBacked(NEARBY) ==
                map_profile_protocol::POIS_RUNTIME_ENABLED);
  static_assert(tileForDeviceScreen(7) ==
                (map_profile_protocol::POIS_RUNTIME_ENABLED ? NEARBY : MAP));
  static_assert(isMapBacked(MAP_GUIDANCE));
  static_assert(!isMapBacked(WORLD_RADIO));
  static_assert(isEnabled(COMPASS, SUPPORTED_MASK));

  assert(nextEnabled(COMPASS, SUPPORTED_MASK) ==
         (map_profile_protocol::POIS_RUNTIME_ENABLED ? NEARBY : NAV));
  assert(nextEnabled(NAV, static_cast<uint8_t>(SUPPORTED_MASK & ~screenBit(DeviceScreenId::WorldRadio))) ==
         BATTERY_STATUS);
  assert(previousEnabled(BATTERY_STATUS, SUPPORTED_MASK) ==
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
         WORLD_RADIO
#else
         NAV
#endif
  );
  assert(previousEnabled(MAP_GUIDANCE, SUPPORTED_MASK) == BATTERY_STATUS);
  assert(previousEnabled(BATTERY_STATUS,
                         screenBit(DeviceScreenId::MapPlusNavigation)) ==
         MAP_GUIDANCE);
  tileName next = WORLD_RADIO;
  assert(nextEnabledMapBacked(RIDESTATS, SUPPORTED_MASK, next));
  assert(next == MAP);

  std::cout << "main screen registry tests passed\n";
  return 0;
}
