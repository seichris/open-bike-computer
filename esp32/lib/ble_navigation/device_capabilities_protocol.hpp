#pragma once

#include <stddef.h>
#include <stdint.h>

namespace device_capabilities_protocol {

constexpr uint8_t CAP2_CLIENT_VERSION = 10;
constexpr uint8_t CAP2_SCHEMA_VERSION = 1;
constexpr uint32_t STREET_LABELS_FEATURE = 1UL << 8;
constexpr uint32_t BIRDS_EYE_MAP_NAVIGATION_FEATURE = 1UL << 9;
constexpr uint32_t BIRDS_EYE_PERSPECTIVE_FEATURE = 1UL << 10;
constexpr uint32_t BIRDS_EYE_STRONGER_PERSPECTIVE_FEATURE = 1UL << 11;
constexpr uint32_t OSM_3D_BUILDINGS_FEATURE = 1UL << 12;
constexpr uint32_t RIDE_AUTOMATION_V2_FEATURE = 1UL << 13;
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
