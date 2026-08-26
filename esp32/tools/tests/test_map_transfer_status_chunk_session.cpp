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

  map_transfer_status_protocol::ChunkTransmission transmission;
  assert(!transmission.begin("", initial, 8));
  assert(!transmission.begin("status", initial, 0));
  assert(!transmission.active());

  const std::string chunkBody = "abcdefghijklmnopqrstuvwxyz";
  assert(transmission.begin(chunkBody, installed, 8));
  assert(transmission.active());
  assert(transmission.bodySize() == chunkBody.size());
  assert(transmission.chunkCount() == 4);
  assert(transmission.nextIndex() == 0);
  assert(transmission.matches(chunkBody, installed, 8));
  assert(!transmission.matches(chunkBody + "!", installed, 8));

  std::string frame = transmission.nextFrame();
  assert(frame.size() == 15);
  assert(frame.substr(0, 4) == "MSTC");
  assert(static_cast<uint8_t>(frame[4]) == installed);
  assert(static_cast<uint8_t>(frame[5]) == 0);
  assert(static_cast<uint8_t>(frame[6]) == 4);
  assert(frame.substr(7) == "abcdefgh");

  transmission.advance();
  frame = transmission.nextFrame();
  assert(static_cast<uint8_t>(frame[5]) == 1);
  assert(frame.substr(7) == "ijklmnop");
  transmission.advance();
  frame = transmission.nextFrame();
  assert(static_cast<uint8_t>(frame[5]) == 2);
  assert(frame.substr(7) == "qrstuvwx");
  transmission.advance();
  frame = transmission.nextFrame();
  assert(static_cast<uint8_t>(frame[5]) == 3);
  assert(frame.substr(7) == "yz");
  transmission.advance();
  assert(!transmission.active());
  assert(transmission.nextFrame().empty());

  const std::string oversizedQueueBody = "0123456789ABCDEFGHIJ";
  assert(transmission.begin(oversizedQueueBody, activating, 1));
  for (size_t slot = 0; slot < 8; ++slot) {
    assert(transmission.active());
    assert(transmission.nextIndex() == slot);
    transmission.advance();
  }
  assert(transmission.active());
  assert(transmission.nextIndex() == 8);
  for (size_t slot = 0; slot < 8; ++slot) {
    assert(transmission.active());
    assert(transmission.nextIndex() == slot + 8);
    transmission.advance();
  }
  assert(transmission.active());
  assert(transmission.nextIndex() == 16);
  for (size_t slot = 0; slot < 4; ++slot) {
    assert(transmission.active());
    assert(transmission.nextIndex() == slot + 16);
    transmission.advance();
  }
  assert(!transmission.active());
  assert(transmission.nextIndex() == oversizedQueueBody.size());

  transmission.reset();
  assert(!transmission.active());
  assert(transmission.bodySize() == 0);
  assert(transmission.chunkCount() == 0);
  assert(transmission.nextIndex() == 0);

  assert(!transmission.begin(std::string(256, 'x'), initial, 1));
  assert(!transmission.active());

  std::cout << "map transfer status chunk session tests passed\n";
  return 0;
}
