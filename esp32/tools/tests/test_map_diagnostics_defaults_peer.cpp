#include "../../lib/maps/src/mapRendererFileValidator.hpp"
#include "../../lib/ble_navigation/map_profile_protocol.hpp"
uint32_t terrainVisibilityAfterRendererInclude() {
  return map_profile_protocol::VISIBILITY_TERRAIN;
}
