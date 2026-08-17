#include "../../lib/ble_navigation/map_transfer_status_chunk_session.hpp"

#include <cassert>
#include <iostream>

int main() {
  std::string statusBody = "{\"status\":\"idle\"";
  map_transfer_status_protocol::ActiveMapPresentation presentation;
  presentation.displayName = "Chris's \"Bike\"";
  presentation.boundsE7 = {-468300000, -240100000, -463600000, -233500000};
  presentation.hasBoundsE7 = true;
  map_transfer_status_protocol::appendActiveMapPresentation(statusBody,
                                                            presentation);
  assert(statusBody ==
         "{\"status\":\"idle\",\"activeMapDisplayName\":"
         "\"Chris's \\\"Bike\\\"\",\"activeMapBoundsE7\":"
         "[-468300000,-240100000,-463600000,-233500000]");

  const std::string unchanged = statusBody;
  map_transfer_status_protocol::appendActiveMapPresentation(
      statusBody, map_transfer_status_protocol::ActiveMapPresentation());
  assert(statusBody == unchanged);

  map_transfer_status_protocol::ActiveMapPresentation maximumPresentation;
  maximumPresentation.displayName = std::string(240, 'x');
  maximumPresentation.boundsE7 = {-1800000000, -900000000, 1800000000,
                                  900000000};
  maximumPresentation.hasBoundsE7 = true;
  std::string maximumBody = "{}";
  map_transfer_status_protocol::appendActiveMapPresentation(
      maximumBody, maximumPresentation);
  assert(maximumBody.size() <= 13U * 255U);

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
