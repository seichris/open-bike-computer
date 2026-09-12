#include "../../lib/ble_navigation/device_screen_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

int main() {
  using namespace device_screen_protocol;

  assert(applyCompatibility(0x0F, 0x3F) == 0x3F);
  assert(applyCompatibility(0x0F, 0x0F) == 0x0F);
  assert(applyCompatibility(CURRENT_MASK_MARKER | 0x0F, 0x3F) == 0x0F);
  assert(applyCompatibility(CURRENT_MASK_MARKER | 0x3F, 0x0F) == 0x3F);
  assert((applyCompatibility(CURRENT_MASK_MARKER | 0x3F, 0x0F) &
          CURRENT_MASK_MARKER) == 0);

  std::cout << "device screen protocol tests passed\n";
  return 0;
}
