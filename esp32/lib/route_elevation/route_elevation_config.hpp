#pragma once

#include "../ble_navigation/ride_ble_protocol.generated.hpp"

#include <cstdint>

namespace route_elevation_config {

// Route Elevation is available on both Waveshare panels in development and
// production. Screen selection remains opt-in; the capability still requires
// a compatible authenticated peer. Define ROUTE_ELEVATION_SCREEN=0/1 to
// explicitly override the board default.
#if defined(ROUTE_ELEVATION_SCREEN)
#define ROUTE_ELEVATION_SCREEN_ENABLED (ROUTE_ELEVATION_SCREEN != 0)
#elif defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#define ROUTE_ELEVATION_SCREEN_ENABLED 1
#else
#define ROUTE_ELEVATION_SCREEN_ENABLED 0
#endif
inline constexpr bool ENABLED = ROUTE_ELEVATION_SCREEN_ENABLED;

constexpr bool supportsClient(uint8_t clientVersion) {
  return ENABLED &&
         clientVersion >= ride_ble_protocol_generated::EXTENDED_ROUTE_ELEVATION_V1_MINIMUM_CLIENT_VERSION;
}

} // namespace route_elevation_config
