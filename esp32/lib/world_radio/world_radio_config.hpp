#pragma once

#include "../ble_navigation/ride_ble_protocol.generated.hpp"

namespace world_radio_config {

// Keep the preview in development profiles while the interaction and phone
// playback lifecycle are physically qualified. Its former heavyweight map,
// multilingual font, and flags are no longer part of the size decision.
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
