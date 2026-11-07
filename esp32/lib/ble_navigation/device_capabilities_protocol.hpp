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
constexpr uint8_t DISPLAY_INACTIVITY_TIMEOUTS_CLIENT_VERSION =
    ride_ble_protocol_generated::
        DISPLAY_INACTIVITY_TIMEOUTS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RIDE_DIAGNOSTICS_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_DIAGNOSTICS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t DETAILED_RIDE_DIAGNOSTICS_CLIENT_VERSION =
    ride_ble_protocol_generated::
        DETAILED_RIDE_DIAGNOSTICS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RIDE_DELIVERY_ACK_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_MINIMUM_CLIENT_VERSION;
constexpr uint8_t MAP_POIS_CLIENT_VERSION =
    ride_ble_protocol_generated::EXTENDED_MAP_POIS_MINIMUM_CLIENT_VERSION;
constexpr uint8_t WORLD_RADIO_CLIENT_VERSION =
    ride_ble_protocol_generated::WORLD_RADIO_MINIMUM_CLIENT_VERSION;
constexpr uint8_t SCREEN_CONFIGURATION_CLIENT_VERSION =
    ride_ble_protocol_generated::SCREEN_CONFIGURATION_V1_MINIMUM_CLIENT_VERSION;
constexpr uint8_t RENDERER_BENCHMARK_SAMPLE_CLIENT_VERSION =
    ride_ble_protocol_generated::
        RENDERER_BENCHMARK_SAMPLE_MINIMUM_CLIENT_VERSION;
constexpr uint8_t WATCH_GPS_MOTION_EVIDENCE_V1_CLIENT_VERSION =
    ride_ble_protocol_generated::
        WATCH_GPS_MOTION_EVIDENCE_V1_MINIMUM_CLIENT_VERSION;
constexpr uint8_t TOPOGRAPHIC_CONTOURS_CLIENT_VERSION =
    ride_ble_protocol_generated::TOPOGRAPHIC_CONTOURS_MINIMUM_CLIENT_VERSION;
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
constexpr uint32_t DISPLAY_INACTIVITY_TIMEOUTS_FEATURE =
    ride_ble_protocol_generated::DISPLAY_INACTIVITY_TIMEOUTS_FEATURE;
constexpr uint32_t RIDE_DIAGNOSTICS_FEATURE =
    ride_ble_protocol_generated::RIDE_DIAGNOSTICS_FEATURE;
constexpr uint32_t DETAILED_RIDE_DIAGNOSTICS_FEATURE =
    ride_ble_protocol_generated::DETAILED_RIDE_DIAGNOSTICS_FEATURE;
constexpr uint32_t RIDE_DELIVERY_ACK_FEATURE =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_FEATURE;
constexpr uint32_t MAP_POIS_FEATURE =
    ride_ble_protocol_generated::EXTENDED_MAP_POIS_FEATURE;
constexpr uint32_t WORLD_RADIO_FEATURE =
    ride_ble_protocol_generated::WORLD_RADIO_FEATURE;
constexpr uint32_t SCREEN_CONFIGURATION_FEATURE =
    ride_ble_protocol_generated::SCREEN_CONFIGURATION_V1_FEATURE;
constexpr uint32_t RENDERER_BENCHMARK_SAMPLE_FEATURE =
    ride_ble_protocol_generated::RENDERER_BENCHMARK_SAMPLE_FEATURE;
constexpr uint32_t WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE =
    ride_ble_protocol_generated::WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE;
constexpr uint32_t TOPOGRAPHIC_CONTOURS_FEATURE =
    ride_ble_protocol_generated::TOPOGRAPHIC_CONTOURS_FEATURE;
constexpr uint32_t MAP_NAVIGATION_ORIENTATION_FEATURE =
    ride_ble_protocol_generated::MAP_NAVIGATION_ORIENTATION_FEATURE;
constexpr uint8_t MAP_NAVIGATION_ORIENTATION_CLIENT_VERSION =
    ride_ble_protocol_generated::MAP_NAVIGATION_ORIENTATION_MINIMUM_CLIENT_VERSION;
inline bool supportsMapPois(uint8_t clientVersion, bool runtimeEnabled,
                            bool screenConfigurationReady) {
  return runtimeEnabled && screenConfigurationReady &&
         clientVersion >= MAP_POIS_CLIENT_VERSION;
}
inline bool supportsMapNavigationOrientation(uint8_t clientVersion,
                                              bool implementationEnabled) {
  return implementationEnabled &&
         clientVersion >= MAP_NAVIGATION_ORIENTATION_CLIENT_VERSION;
}
// One-bit e-paper presentation policy. Bits 8, 12 and 30 keep their reader
// meaning (renderer targets 2-4, flat building footprints), so durable maps
// still install; the board never draws a bird's-eye view, LoD1 walls, a
// course-up camera, contours, terrain or POI icons, and has no dimmable
// backlight. Every contract bit must be classified here: a new feature fails
// to compile until someone decides whether this board can honour it.
namespace epaper_policy {
namespace generated = ride_ble_protocol_generated;
constexpr uint32_t UNSUPPORTED_FEATURES =
    generated::BIRDS_EYE_MAP_NAVIGATION_FEATURE |
    generated::BIRDS_EYE_PERSPECTIVE_FEATURE |
    generated::BIRDS_EYE_STRONGER_PERSPECTIVE_FEATURE |
    generated::AUTOMATIC_DISPLAY_OFF_FEATURE |
    generated::MAP_NAVIGATION_ORIENTATION_FEATURE |
    generated::DISPLAY_INACTIVITY_TIMEOUTS_FEATURE |
    generated::TERRAIN_EXPERIMENTS_FEATURE;
constexpr uint32_t SUPPORTED_FEATURES =
    generated::DEVICE_SOUNDS_FEATURE | generated::POWER_BUTTON_HONK_FEATURE |
    generated::POWER_BUTTON_HONK_ACK_FEATURE |
    generated::INDEPENDENT_MAP_PROFILES_FEATURE |
    generated::EXTENDED_MAP_VISIBILITY_FEATURE |
    generated::BATTERY_STATUS_SCREEN_FEATURE |
    generated::DESTINATION_PICKER_FEATURE | generated::WORKOUT_TELEMETRY_FEATURE |
    generated::STREET_LABELS_FEATURE | generated::OSM_3D_BUILDINGS_FEATURE |
    generated::EXPLICIT_INVALID_GPS_HEADING_FEATURE |
    generated::SCOPED_WATCH_CONTROLLER_FEATURE |
    generated::RIDE_AUTOMATION_V2_FEATURE | generated::REMOTE_DEVICE_DEBUG_FEATURE |
    generated::GPS_POSITION_QUALITY_V1_FEATURE |
    generated::RENDERER_DIAGNOSTICS_FEATURE | generated::RIDE_DIAGNOSTICS_FEATURE |
    generated::DETAILED_RIDE_DIAGNOSTICS_FEATURE |
    generated::RIDE_DELIVERY_ACK_FEATURE |
    generated::RENDERER_BENCHMARK_SAMPLE_FEATURE |
    generated::WATCH_GPS_MOTION_EVIDENCE_V1_FEATURE |
    generated::SCREEN_CONFIGURATION_V1_FEATURE | generated::WORLD_RADIO_FEATURE |
    generated::WORKOUT_ZONES_V1_FEATURE | generated::TOPOGRAPHIC_CONTOURS_FEATURE;
constexpr uint32_t UNSUPPORTED_EXTENDED_FEATURES =
    generated::EXTENDED_MAP_POIS_FEATURE;
constexpr uint32_t SUPPORTED_EXTENDED_FEATURES =
    generated::EXTENDED_GROUP_RIDERS_V1_FEATURE |
    generated::EXTENDED_FRIEND_MARKER_SCALE_V1_FEATURE |
    generated::EXTENDED_ROUTE_ELEVATION_V1_FEATURE |
    generated::EXTENDED_BOARD_DISPLAY_METADATA_FEATURE;
static_assert((UNSUPPORTED_FEATURES & SUPPORTED_FEATURES) == 0 &&
                  (UNSUPPORTED_FEATURES | SUPPORTED_FEATURES) ==
                      generated::ALL_FEATURES,
              "classify every CAP2 feature for the e-paper board");
static_assert((UNSUPPORTED_EXTENDED_FEATURES & SUPPORTED_EXTENDED_FEATURES) == 0 &&
                  (UNSUPPORTED_EXTENDED_FEATURES | SUPPORTED_EXTENDED_FEATURES) ==
                      generated::ALL_EXTENDED_FEATURES,
              "classify every extended CAP2 feature for the e-paper board");
} // namespace epaper_policy

constexpr uint8_t POWER_BUTTON_CONFIG_TLV = 1;
constexpr size_t POWER_BUTTON_CONFIG_BYTES = 3;
constexpr size_t CAP2_BASE_BYTES = 9;
constexpr size_t SCREEN_CONFIGURATION_TLV_BYTES = 16;
constexpr size_t EXTENDED_FEATURE_TLV_BYTES = 6;
constexpr size_t BOARD_DISPLAY_TLV_BYTES =
    2 + ride_ble_protocol_generated::BOARD_DISPLAY_PAYLOAD_BYTES;
constexpr size_t CAP2_MAX_BYTES =
    CAP2_BASE_BYTES + 2 + POWER_BUTTON_CONFIG_BYTES +
    SCREEN_CONFIGURATION_TLV_BYTES + EXTENDED_FEATURE_TLV_BYTES +
    BOARD_DISPLAY_TLV_BYTES;

// Board display metadata is the last TLV, so responses without it keep the
// established byte layout.
inline size_t encodeCap2(uint32_t featureFlags, const uint8_t *powerConfig,
                         bool includePowerConfig, uint8_t *output,
                         size_t capacity, const uint8_t *additionalTLV = nullptr,
                         size_t additionalTLVLength = 0,
                         uint32_t extendedFeatureFlags = 0,
                         const uint8_t *displayMetadata = nullptr) {
  if (additionalTLVLength > SCREEN_CONFIGURATION_TLV_BYTES)
    return 0;
  const size_t displayBytes =
      displayMetadata != nullptr ? BOARD_DISPLAY_TLV_BYTES : 0;
  const size_t required = CAP2_BASE_BYTES +
                          (includePowerConfig ? 2 + POWER_BUTTON_CONFIG_BYTES
                                              : 0) +
                          additionalTLVLength +
                          (extendedFeatureFlags != 0 ? EXTENDED_FEATURE_TLV_BYTES : 0) +
                          displayBytes;
  if (output == nullptr || capacity < required ||
      (includePowerConfig && powerConfig == nullptr) ||
      (additionalTLVLength != 0 && additionalTLV == nullptr))
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
  if (additionalTLVLength != 0) {
    const size_t offset = CAP2_BASE_BYTES +
                          (includePowerConfig
                               ? 2 + POWER_BUTTON_CONFIG_BYTES
                               : 0);
    for (size_t index = 0; index < additionalTLVLength; ++index)
      output[offset + index] = additionalTLV[index];
  }
  if (extendedFeatureFlags != 0) {
    const size_t offset = required - displayBytes - EXTENDED_FEATURE_TLV_BYTES;
    output[offset] = ride_ble_protocol_generated::EXTENDED_FEATURE_TLV_TYPE;
    output[offset + 1] = 4;
    for (uint8_t index = 0; index < 4; ++index)
      output[offset + 2 + index] =
          static_cast<uint8_t>(extendedFeatureFlags >> (index * 8U));
  }
  if (displayMetadata != nullptr) {
    const size_t offset = required - BOARD_DISPLAY_TLV_BYTES;
    output[offset] = ride_ble_protocol_generated::BOARD_DISPLAY_TLV_TYPE;
    output[offset + 1] = ride_ble_protocol_generated::BOARD_DISPLAY_PAYLOAD_BYTES;
    for (size_t index = 0;
         index < ride_ble_protocol_generated::BOARD_DISPLAY_PAYLOAD_BYTES; ++index)
      output[offset + 2 + index] = displayMetadata[index];
  }
  return required;
}

} // namespace device_capabilities_protocol
