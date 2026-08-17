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
  maximumPresentation.displayName = std::string(240, '\\');
  maximumPresentation.boundsE7 = {-1800000000, -900000000, 1800000000,
                                  900000000};
  maximumPresentation.hasBoundsE7 = true;
  std::string maximumBody =
      "{\"configured\":true,\"enabled\":true,\"port\":65535,"
      "\"firmwareVersion\":\"2026.08.17-production\","
      "\"firmwareBuild\":4294967295,"
      "\"firmwareGitSha\":\"0123456789abcdef0123456789abcdef01234567\","
      "\"protocols\":[1,2],\"streamFormatVersions\":[1],"
      "\"streamTrust\":[\"production-key=" +
      std::string(64, 'a') +
      "\"],\"sdPresent\":true,\"mapFound\":true,"
      "\"mapBlocks\":4294967295,"
      "\"baseUrl\":\"http://255.255.255.255:65535\","
      "\"apSsid\":\"BikeComputer-Transfer-123456789\","
      "\"networkTransport\":\"hotspot\","
      "\"networkSsid\":\"12345678901234567890123456789012\","
      "\"hotspotFallback\":true,"
      "\"hotspotFallbackReason\":\"endpoint_unreachable\","
      "\"activeMapId\":\"" +
      std::string(80, 'm') + "\",\"activeSessionId\":\"" +
      std::string(80, 's') + "\",\"activeManifestReceipt\":\"" +
      std::string(64, 'b') + "\"}";
  map_transfer_status_protocol::appendActiveMapPresentation(
      maximumBody, maximumPresentation);
  const size_t minimumMtuChunkBytes =
      map_transfer_status_protocol::chunkPayloadBytes(45);
  assert(minimumMtuChunkBytes == 13U);
  const size_t maximumBodyChunkCount =
      (maximumBody.size() + minimumMtuChunkBytes - 1U) /
      minimumMtuChunkBytes;
  assert(maximumBodyChunkCount <= 255U);

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
