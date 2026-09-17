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
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
  static_assert(SUPPORTED_MASK == 0x3F);
  static_assert(deviceScreenForTile(WORLD_RADIO) == 5);
  static_assert(tileForDeviceScreen(5) == WORLD_RADIO);
  assert(nextEnabled(NAV, SUPPORTED_MASK) == WORLD_RADIO);
  assert(nextEnabled(WORLD_RADIO, SUPPORTED_MASK) == BATTERY_STATUS);
#else
  static_assert(SUPPORTED_MASK == 0x1F);
  static_assert(descriptorForTile(WORLD_RADIO) == nullptr);
  static_assert(descriptorForDeviceScreen(5) == nullptr);
  static_assert(normalizedMask(0x3F) == 0x1F);
  static_assert(normalizedDefault(5, 0x3F) == 3);
  assert(nextEnabled(NAV, SUPPORTED_MASK) == BATTERY_STATUS);
#endif
  static_assert(isMapBacked(MAP));
  static_assert(isMapBacked(MAP_GUIDANCE));
  static_assert(!isMapBacked(WORLD_RADIO));
  static_assert(isEnabled(COMPASS, SUPPORTED_MASK));

  assert(nextEnabled(COMPASS, SUPPORTED_MASK) == NAV);
  assert(nextEnabled(NAV, static_cast<uint8_t>(SUPPORTED_MASK & ~screenBit(DeviceScreenId::WorldRadio))) ==
         BATTERY_STATUS);
  tileName next = WORLD_RADIO;
  assert(nextEnabledMapBacked(RIDESTATS, SUPPORTED_MASK, next));
  assert(next == MAP);

  std::cout << "main screen registry tests passed\n";
  return 0;
}
