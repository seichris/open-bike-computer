#pragma once

#include "../ble_navigation/ride_ble_protocol.generated.hpp"

#include <cstdint>

namespace route_elevation_config {

// The Elevation screen targets the 1.75-inch round panel. Keep it in
// development (diagnostics) profiles until transfer, reconnect and riding
// readability are physically qualified; production and the unqualified
// 2.06-inch layout omit both the screen and the capability. Define
// ROUTE_ELEVATION_SCREEN=0/1 to override after a recorded hardware gate.
#if defined(ROUTE_ELEVATION_SCREEN)
#define ROUTE_ELEVATION_SCREEN_ENABLED (ROUTE_ELEVATION_SCREEN != 0)
#elif defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS && defined(WAVESHARE_AMOLED_175)
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
