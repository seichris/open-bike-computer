#pragma once

#include "../ble_navigation/ride_ble_protocol.generated.hpp"

namespace world_radio_config {

// Keep the preview in development profiles until physical qualification and
// release-size budgeting are complete. Production's 3 MiB OTA layout is fixed.
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
inline constexpr bool ENABLED = true;
#else
inline constexpr bool ENABLED = false;
#endif

constexpr bool supportsClient(uint8_t clientVersion) {
  return ENABLED &&
         clientVersion >=
             ride_ble_protocol_generated::WORLD_RADIO_MINIMUM_CLIENT_VERSION;
}

} // namespace world_radio_config
