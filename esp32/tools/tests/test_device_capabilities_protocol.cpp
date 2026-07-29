#include "../../lib/ble_navigation/device_capabilities_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

int main() {
  uint8_t output[device_capabilities_protocol::CAP2_MAX_BYTES]{};
  const uint8_t power[] = {1, 4, 80};
  const size_t size = device_capabilities_protocol::encodeCap2(
      0x000001ff, power, true, output, sizeof(output));
  const uint8_t expected[] = {'C', 'A', 'P', '2', 1, 0xff, 0x01,
                              0x00, 0x00, 1,   3, 1,    4,    80};
  static_assert(sizeof(expected) == device_capabilities_protocol::CAP2_MAX_BYTES);
  assert(size == sizeof(expected));
  for (size_t index = 0; index < size; ++index)
    assert(output[index] == expected[index]);
  assert(device_capabilities_protocol::encodeCap2(0, nullptr, false, output,
                                                   8) == 0);
  assert(device_capabilities_protocol::encodeCap2(0, nullptr, false, output,
                                                   sizeof(output)) == 9);
  std::cout << "device capabilities protocol tests passed\n";
  return 0;
}
