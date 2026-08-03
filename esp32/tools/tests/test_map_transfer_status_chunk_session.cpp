#include "../../lib/ble_navigation/map_transfer_status_chunk_session.hpp"

#include <cassert>
#include <iostream>

int main() {
  assert(map_transfer_status_protocol::chunkPayloadBytes(23) == 0);
  assert(map_transfer_status_protocol::chunkPayloadBytes(32) == 0);
  assert(map_transfer_status_protocol::chunkPayloadBytes(33) == 1);
  assert(map_transfer_status_protocol::chunkPayloadBytes(45) == 13);
  assert(map_transfer_status_protocol::chunkPayloadBytes(185) == 153);
  assert(map_transfer_status_protocol::chunkPayloadBytes(512) == 480);

  map_transfer_status_protocol::ChunkSession session;

  const uint8_t initial = session.transferIdFor("{\"status\":\"idle\"}");
  assert(initial != 0);
  assert(session.transferIdFor("{\"status\":\"idle\"}") == initial);
  assert(session.transferIdFor("{\"status\":\"idle\"}") == initial);

  const uint8_t activating =
      session.transferIdFor("{\"status\":\"activating\",\"progress\":50}");
  assert(activating != initial);
  assert(session.transferIdFor(
             "{\"status\":\"activating\",\"progress\":50}") ==
         activating);

  const uint8_t installed =
      session.transferIdFor("{\"status\":\"installed\"}");
  assert(installed != activating);
  assert(session.transferIdFor("{\"status\":\"installed\"}") == installed);

  std::cout << "map transfer status chunk session tests passed\n";
  return 0;
}
