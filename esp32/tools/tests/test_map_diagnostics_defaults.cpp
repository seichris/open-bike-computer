#include "../../lib/ble_navigation/map_profile_protocol.hpp"
#include <cassert>
extern uint32_t terrainVisibilityAfterRendererInclude();
int main() {
  assert(map_profile_protocol::VISIBILITY_TERRAIN == (FIRMWARE_DIAGNOSTICS ? 0x3c000u : 0));
  assert(terrainVisibilityAfterRendererInclude() == map_profile_protocol::VISIBILITY_TERRAIN);
}
