#pragma once

#include "ride_ble_protocol.generated.hpp"

#include <stddef.h>
#include <stdint.h>

namespace device_capabilities_protocol {

constexpr uint8_t CAP2_CLIENT_VERSION =
    ride_ble_protocol_generated::STREET_LABELS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t EXPLICIT_INVALID_GPS_HEADING_CLIENT_VERSION =
    ride_ble_protocol_generated::
        EXPLICIT_INVALID_GPS_HEADING_MINIMUM_CLIENT_VERSION;
constexpr uint8_t SCOPED_WATCH_CONTROLLER_CLIENT_VERSION =
    ride_ble_protocol_generated::
        SCOPED_WATCH_CONTROLLER_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RIDE_AUTOMATION_V2_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_AUTOMATION_V2_MINIMUM_CLIENT_VERSION;
constexpr uint8_t REMOTE_DEVICE_DEBUG_CLIENT_VERSION =
    ride_ble_protocol_generated::REMOTE_DEVICE_DEBUG_MINIMUM_CLIENT_VERSION;
constexpr uint8_t GPS_POSITION_QUALITY_V1_CLIENT_VERSION =
    ride_ble_protocol_generated::
        GPS_POSITION_QUALITY_V1_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RENDERER_DIAGNOSTICS_CLIENT_VERSION =
    ride_ble_protocol_generated::RENDERER_DIAGNOSTICS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t AUTOMATIC_DISPLAY_OFF_CLIENT_VERSION =
    ride_ble_protocol_generated::AUTOMATIC_DISPLAY_OFF_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RIDE_DIAGNOSTICS_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_DIAGNOSTICS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t DETAILED_RIDE_DIAGNOSTICS_CLIENT_VERSION =
    ride_ble_protocol_generated::
        DETAILED_RIDE_DIAGNOSTICS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RIDE_DELIVERY_ACK_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_MINIMUM_CLIENT_VERSION;
constexpr uint8_t WATCH_GPS_MOTION_EVIDENCE_V1_CLIENT_VERSION =
    ride_ble_protocol_generated::
        WATCH_GPS_MOTION_EVIDENCE_V1_MINIMUM_CLIENT_VERSION;
constexpr uint8_t CAP2_SCHEMA_VERSION =
    ride_ble_protocol_generated::CAPABILITY_SCHEMA_VERSION;
constexpr uint32_t STREET_LABELS_FEATURE =
    ride_ble_protocol_generated::STREET_LABELS_FEATURE;
constexpr uint32_t BIRDS_EYE_MAP_NAVIGATION_FEATURE =
    ride_ble_protocol_generated::BIRDS_EYE_MAP_NAVIGATION_FEATURE;
constexpr uint32_t BIRDS_EYE_PERSPECTIVE_FEATURE =
    ride_ble_protocol_generated::BIRDS_EYE_PERSPECTIVE_FEATURE;
constexpr uint32_t BIRDS_EYE_STRONGER_PERSPECTIVE_FEATURE =
    ride_ble_protocol_generated::BIRDS_EYE_STRONGER_PERSPECTIVE_FEATURE;
constexpr uint32_t OSM_3D_BUILDINGS_FEATURE =
    ride_ble_protocol_generated::OSM_3D_BUILDINGS_FEATURE;
constexpr uint32_t EXPLICIT_INVALID_GPS_HEADING_FEATURE =
    ride_ble_protocol_generated::EXPLICIT_INVALID_GPS_HEADING_FEATURE;
// Complete scoped Watch-controller authentication and exclusive writer-lease
// contract. Runtime capability encoding keeps this bit clear if the durable
// controller store does not boot cleanly.
constexpr uint32_t SCOPED_WATCH_CONTROLLER_FEATURE =
    ride_ble_protocol_generated::SCOPED_WATCH_CONTROLLER_FEATURE;
constexpr uint32_t RIDE_AUTOMATION_V2_FEATURE =
    ride_ble_protocol_generated::RIDE_AUTOMATION_V2_FEATURE;
constexpr uint32_t REMOTE_DEVICE_DEBUG_FEATURE =
    ride_ble_protocol_generated::REMOTE_DEVICE_DEBUG_FEATURE;
constexpr uint32_t GPS_POSITION_QUALITY_V1_FEATURE =
    ride_ble_protocol_generated::GPS_POSITION_QUALITY_V1_FEATURE;
constexpr uint32_t RENDERER_DIAGNOSTICS_FEATURE =
    ride_ble_protocol_generated::RENDERER_DIAGNOSTICS_FEATURE;
// Connected-display inactivity control (setting ID 36).
constexpr uint32_t AUTOMATIC_DISPLAY_OFF_FEATURE =
    ride_ble_protocol_generated::AUTOMATIC_DISPLAY_OFF_FEATURE;
constexpr uint32_t RIDE_DIAGNOSTICS_FEATURE =
    ride_ble_protocol_generated::RIDE_DIAGNOSTICS_FEATURE;
constexpr uint32_t DETAILED_RIDE_DIAGNOSTICS_FEATURE =
    ride_ble_protocol_generated::DETAILED_RIDE_DIAGNOSTICS_FEATURE;
constexpr uint32_t RIDE_DELIVERY_ACK_FEATURE =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_FEATURE;
constexpr uint32_t WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE =
    ride_ble_protocol_generated::WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE;
constexpr uint8_t POWER_BUTTON_CONFIG_TLV = 1;
constexpr size_t POWER_BUTTON_CONFIG_BYTES = 3;
constexpr size_t CAP2_BASE_BYTES = 9;
constexpr size_t CAP2_MAX_BYTES =
    CAP2_BASE_BYTES + 2 + POWER_BUTTON_CONFIG_BYTES;

inline size_t encodeCap2(uint32_t featureFlags, const uint8_t *powerConfig,
                         bool includePowerConfig, uint8_t *output,
                         size_t capacity) {
  const size_t required = CAP2_BASE_BYTES +
                          (includePowerConfig ? 2 + POWER_BUTTON_CONFIG_BYTES
                                              : 0);
  if (output == nullptr || capacity < required ||
      (includePowerConfig && powerConfig == nullptr))
    return 0;
  output[0] = 'C';
  output[1] = 'A';
  output[2] = 'P';
  output[3] = '2';
  output[4] = CAP2_SCHEMA_VERSION;
  for (uint8_t index = 0; index < 4; ++index)
    output[5 + index] = static_cast<uint8_t>(featureFlags >> (index * 8U));
  if (includePowerConfig) {
    output[9] = POWER_BUTTON_CONFIG_TLV;
    output[10] = POWER_BUTTON_CONFIG_BYTES;
    for (size_t index = 0; index < POWER_BUTTON_CONFIG_BYTES; ++index)
      output[11 + index] = powerConfig[index];
  }
  return required;
}

} // namespace device_capabilities_protocol
