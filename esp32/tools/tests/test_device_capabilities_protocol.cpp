#include "../../lib/ble_navigation/device_capabilities_protocol.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

int main() {
  static_assert(device_capabilities_protocol::CAP2_CLIENT_VERSION == 10);
  static_assert(device_capabilities_protocol::STREET_LABELS_FEATURE ==
                (1UL << 8));
  static_assert(
      device_capabilities_protocol::BIRDS_EYE_MAP_NAVIGATION_FEATURE ==
      (1UL << 9));
  static_assert(device_capabilities_protocol::BIRDS_EYE_PERSPECTIVE_FEATURE ==
                (1UL << 10));
  static_assert(
      device_capabilities_protocol::BIRDS_EYE_STRONGER_PERSPECTIVE_FEATURE ==
      (1UL << 11));
  static_assert(device_capabilities_protocol::OSM_3D_BUILDINGS_FEATURE ==
                (1UL << 12));
  static_assert(
      device_capabilities_protocol::EXPLICIT_INVALID_GPS_HEADING_CLIENT_VERSION ==
      11);
  static_assert(
      device_capabilities_protocol::EXPLICIT_INVALID_GPS_HEADING_FEATURE ==
      (1UL << 13));
  static_assert(
      device_capabilities_protocol::SCOPED_WATCH_CONTROLLER_CLIENT_VERSION ==
      12);
  static_assert(
      device_capabilities_protocol::SCOPED_WATCH_CONTROLLER_FEATURE ==
      (1UL << 14));
  static_assert(
      device_capabilities_protocol::RIDE_AUTOMATION_V2_CLIENT_VERSION == 13);
  static_assert(device_capabilities_protocol::RIDE_AUTOMATION_V2_FEATURE ==
                (1UL << 15));
  uint8_t output[device_capabilities_protocol::CAP2_MAX_BYTES]{};
  const uint8_t power[] = {1, 4, 80};
  const size_t size = device_capabilities_protocol::encodeCap2(
      0x00003fff, power, true, output, sizeof(output));
  const uint8_t expected[] = {'C', 'A', 'P', '2', 1, 0xff, 0x3f,
                              0x00, 0x00, 1,   3, 1,    4,    80};
  static_assert(sizeof(expected) == device_capabilities_protocol::CAP2_MAX_BYTES);
  assert(size == sizeof(expected));
  for (size_t index = 0; index < size; ++index)
    assert(output[index] == expected[index]);
  assert(device_capabilities_protocol::encodeCap2(0, nullptr, false, output,
                                                   8) == 0);
  assert(device_capabilities_protocol::encodeCap2(0, nullptr, false, output,
                                                   sizeof(output)) == 9);

  const size_t scopedControllerSize =
      device_capabilities_protocol::encodeCap2(
          device_capabilities_protocol::SCOPED_WATCH_CONTROLLER_FEATURE,
          nullptr, false, output, sizeof(output));
  const uint8_t expectedScopedController[] = {'C', 'A', 'P', '2', 1,
                                               0x00, 0x40, 0x00, 0x00};
  assert(scopedControllerSize == sizeof(expectedScopedController));
  for (size_t index = 0; index < scopedControllerSize; ++index)
    assert(output[index] == expectedScopedController[index]);
  std::cout << "device capabilities protocol tests passed\n";
  return 0;
}
