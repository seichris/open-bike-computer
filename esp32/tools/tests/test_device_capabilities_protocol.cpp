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
  static_assert(
      device_capabilities_protocol::REMOTE_DEVICE_DEBUG_CLIENT_VERSION == 14);
  static_assert(device_capabilities_protocol::REMOTE_DEVICE_DEBUG_FEATURE ==
                (1UL << 16));
  static_assert(device_capabilities_protocol::
                    GPS_POSITION_QUALITY_V1_CLIENT_VERSION == 15);
  static_assert(device_capabilities_protocol::GPS_POSITION_QUALITY_V1_FEATURE ==
                (1UL << 17));
  static_assert(device_capabilities_protocol::RENDERER_DIAGNOSTICS_CLIENT_VERSION ==
                16);
  static_assert(device_capabilities_protocol::RENDERER_DIAGNOSTICS_FEATURE ==
                (1UL << 18));
  static_assert(
      device_capabilities_protocol::AUTOMATIC_DISPLAY_OFF_CLIENT_VERSION ==
      16);
  static_assert(
      device_capabilities_protocol::AUTOMATIC_DISPLAY_OFF_FEATURE ==
      (1UL << 19));
  static_assert(
      device_capabilities_protocol::RIDE_DIAGNOSTICS_CLIENT_VERSION == 18);
  static_assert(device_capabilities_protocol::RIDE_DIAGNOSTICS_FEATURE ==
                (1UL << 20));
  static_assert(device_capabilities_protocol::
                    DETAILED_RIDE_DIAGNOSTICS_CLIENT_VERSION == 19);
  static_assert(
      device_capabilities_protocol::DETAILED_RIDE_DIAGNOSTICS_FEATURE ==
      (1UL << 21));
  static_assert(
      device_capabilities_protocol::RIDE_DELIVERY_ACK_CLIENT_VERSION == 20);
  static_assert(device_capabilities_protocol::RIDE_DELIVERY_ACK_FEATURE ==
                (1UL << 22));
  static_assert(
      device_capabilities_protocol::WATCH_GPS_MOTION_EVIDENCE_V1_CLIENT_VERSION ==
      21);
  static_assert(
      device_capabilities_protocol::WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE ==
      (1UL << 23));
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
  const size_t rideAutomationSize = device_capabilities_protocol::encodeCap2(
      device_capabilities_protocol::RIDE_AUTOMATION_V2_FEATURE, nullptr, false,
      output, sizeof(output));
  const uint8_t expectedRideAutomation[] = {'C', 'A', 'P', '2', 1,
                                            0x00, 0x80, 0x00, 0x00};
  assert(rideAutomationSize == sizeof(expectedRideAutomation));
  for (size_t index = 0; index < rideAutomationSize; ++index)
    assert(output[index] == expectedRideAutomation[index]);
  const size_t remoteDebugSize = device_capabilities_protocol::encodeCap2(
      device_capabilities_protocol::REMOTE_DEVICE_DEBUG_FEATURE, nullptr,
      false, output, sizeof(output));
  const uint8_t expectedRemoteDebug[] = {'C', 'A', 'P', '2', 1,
                                          0x00, 0x00, 0x01, 0x00};
  assert(remoteDebugSize == sizeof(expectedRemoteDebug));
  for (size_t index = 0; index < remoteDebugSize; ++index)
    assert(output[index] == expectedRemoteDebug[index]);
  const size_t gpsQualitySize = device_capabilities_protocol::encodeCap2(
      device_capabilities_protocol::GPS_POSITION_QUALITY_V1_FEATURE, nullptr,
      false, output, sizeof(output));
  const uint8_t expectedGpsQuality[] = {'C', 'A', 'P', '2', 1,
                                        0x00, 0x00, 0x02, 0x00};
  assert(gpsQualitySize == sizeof(expectedGpsQuality));
  for (size_t index = 0; index < gpsQualitySize; ++index)
    assert(output[index] == expectedGpsQuality[index]);
  const size_t rendererDiagnosticsSize =
      device_capabilities_protocol::encodeCap2(
          device_capabilities_protocol::RENDERER_DIAGNOSTICS_FEATURE, nullptr,
          false, output, sizeof(output));
  const uint8_t expectedRendererDiagnostics[] = {
      'C', 'A', 'P', '2', 1, 0x00, 0x00, 0x04, 0x00};
  assert(rendererDiagnosticsSize == sizeof(expectedRendererDiagnostics));
  for (size_t index = 0; index < rendererDiagnosticsSize; ++index)
    assert(output[index] == expectedRendererDiagnostics[index]);
  const size_t automaticDisplayOffSize =
      device_capabilities_protocol::encodeCap2(
          device_capabilities_protocol::AUTOMATIC_DISPLAY_OFF_FEATURE, nullptr,
          false, output, sizeof(output));
  const uint8_t expectedAutomaticDisplayOff[] = {
      'C', 'A', 'P', '2', 1, 0x00, 0x00, 0x08, 0x00};
  assert(automaticDisplayOffSize == sizeof(expectedAutomaticDisplayOff));
  for (size_t index = 0; index < automaticDisplayOffSize; ++index)
    assert(output[index] == expectedAutomaticDisplayOff[index]);
  const size_t rideDiagnosticsSize = device_capabilities_protocol::encodeCap2(
      device_capabilities_protocol::RIDE_DIAGNOSTICS_FEATURE, nullptr, false,
      output, sizeof(output));
  const uint8_t expectedRideDiagnostics[] = {
      'C', 'A', 'P', '2', 1, 0x00, 0x00, 0x10, 0x00};
  assert(rideDiagnosticsSize == sizeof(expectedRideDiagnostics));
  for (size_t index = 0; index < rideDiagnosticsSize; ++index)
    assert(output[index] == expectedRideDiagnostics[index]);
  const size_t detailedRideDiagnosticsSize =
      device_capabilities_protocol::encodeCap2(
          device_capabilities_protocol::DETAILED_RIDE_DIAGNOSTICS_FEATURE,
          nullptr, false, output, sizeof(output));
  const uint8_t expectedDetailedRideDiagnostics[] = {
      'C', 'A', 'P', '2', 1, 0x00, 0x00, 0x20, 0x00};
  assert(detailedRideDiagnosticsSize ==
         sizeof(expectedDetailedRideDiagnostics));
  for (size_t index = 0; index < detailedRideDiagnosticsSize; ++index)
    assert(output[index] == expectedDetailedRideDiagnostics[index]);
  const size_t rideDeliveryAckSize =
      device_capabilities_protocol::encodeCap2(
          device_capabilities_protocol::RIDE_DELIVERY_ACK_FEATURE, nullptr,
          false, output, sizeof(output));
  const uint8_t expectedRideDeliveryAck[] = {
      'C', 'A', 'P', '2', 1, 0x00, 0x00, 0x40, 0x00};
  assert(rideDeliveryAckSize == sizeof(expectedRideDeliveryAck));
  for (size_t index = 0; index < rideDeliveryAckSize; ++index)
    assert(output[index] == expectedRideDeliveryAck[index]);
  const size_t watchMotionSize = device_capabilities_protocol::encodeCap2(
      device_capabilities_protocol::WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE,
      nullptr, false, output, sizeof(output));
  const uint8_t expectedWatchMotion[] = {
      'C', 'A', 'P', '2', 1, 0x00, 0x00, 0x80, 0x00};
  assert(watchMotionSize == sizeof(expectedWatchMotion));
  for (size_t index = 0; index < watchMotionSize; ++index)
    assert(output[index] == expectedWatchMotion[index]);
  std::cout << "device capabilities protocol tests passed\n";
  return 0;
}
