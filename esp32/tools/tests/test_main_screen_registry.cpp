#include "../../lib/gui/src/mainScreenRegistry.hpp"

#include <cassert>
#include <iostream>

int main() {
  using namespace main_screen_registry;

  static_assert(SUPPORTED_MASK == 0x3F);
  static_assert(deviceScreenForTile(WORLD_RADIO) == 5);
  static_assert(tileForDeviceScreen(5) == WORLD_RADIO);
  static_assert(isMapBacked(MAP));
  static_assert(isMapBacked(MAP_GUIDANCE));
  static_assert(!isMapBacked(WORLD_RADIO));
  static_assert(isEnabled(COMPASS, SUPPORTED_MASK));

  assert(nextEnabled(NAV, SUPPORTED_MASK) == WORLD_RADIO);
  assert(nextEnabled(WORLD_RADIO, SUPPORTED_MASK) == BATTERY_STATUS);
  assert(nextEnabled(COMPASS, SUPPORTED_MASK) == NAV);
  assert(nextEnabled(NAV, static_cast<uint8_t>(SUPPORTED_MASK & ~bit(DeviceScreenId::WorldRadio))) ==
         BATTERY_STATUS);
  tileName next = WORLD_RADIO;
  assert(nextEnabledMapBacked(RIDESTATS, SUPPORTED_MASK, next));
  assert(next == MAP);

  std::cout << "main screen registry tests passed\n";
  return 0;
}
