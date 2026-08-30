#include "../../lib/ble_navigation/renderer_diagnostics_ble_protocol.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  namespace protocol = renderer_diagnostics_ble_protocol;

  assert(protocol::isMetricsRequest(
      reinterpret_cast<const uint8_t *>(protocol::METRICS_REQUEST_PREFIX),
      protocol::PREFIX_BYTES));
  assert(!protocol::isMetricsRequest(
      reinterpret_cast<const uint8_t *>("RDMSx"), 5));

  protocol::RouteMarker input;
  for (size_t index = 0; index < protocol::SHA256_BYTES; ++index)
    input.fixtureSha256[index] = static_cast<uint8_t>(index);
  input.sampleIndex = 257;
  input.sampleCount = 1000;
  input.loop = 0x12345678;

  uint8_t encoded[protocol::ROUTE_MARKER_BYTES]{};
  assert(protocol::encodeRouteMarker(input, encoded, sizeof(encoded)));
  assert(std::memcmp(encoded, "RBM1", 4) == 0);
  assert(encoded[36] == 0x01 && encoded[37] == 0x01);
  assert(encoded[38] == 0xe8 && encoded[39] == 0x03);
  assert(encoded[40] == 0x78 && encoded[43] == 0x12);

  protocol::RouteMarker decoded;
  assert(protocol::decodeRouteMarker(encoded, sizeof(encoded), decoded));
  assert(std::memcmp(decoded.fixtureSha256, input.fixtureSha256,
                     protocol::SHA256_BYTES) == 0);
  assert(decoded.sampleIndex == input.sampleIndex);
  assert(decoded.sampleCount == input.sampleCount);
  assert(decoded.loop == input.loop);

  assert(!protocol::decodeRouteMarker(encoded, sizeof(encoded) - 1, decoded));
  encoded[0] = 'X';
  assert(!protocol::decodeRouteMarker(encoded, sizeof(encoded), decoded));
  encoded[0] = 'R';
  protocol::writeUInt16LE(0, encoded + 38);
  assert(!protocol::decodeRouteMarker(encoded, sizeof(encoded), decoded));

  input.sampleIndex = input.sampleCount;
  assert(!protocol::encodeRouteMarker(input, encoded, sizeof(encoded)));

  protocol::WindowRequest window;
  window.profile = 2;
  window.repeat = 7;
  window.runNonce = 0x0102030405060708ULL;
  for (size_t index = 0; index < protocol::SHA256_BYTES; ++index)
    window.routeFixtureSha256[index] = static_cast<uint8_t>(31 - index);
  std::strcpy(window.routeFixtureId, "shanghai-jingan-renderer-v1");
  uint8_t windowBytes[protocol::WINDOW_REQUEST_MAX_BYTES]{};
  size_t windowLength = 0;
  assert(protocol::encodeWindowRequest(window, windowBytes,
                                       sizeof(windowBytes), windowLength));
  assert(windowLength == protocol::WINDOW_REQUEST_FIXED_BYTES + 27);
  assert(std::memcmp(windowBytes, "RBW1", 4) == 0);
  assert(windowBytes[4] == 1 && windowBytes[5] == 2);
  assert(windowBytes[6] == 7 && windowBytes[7] == 0);
  assert(windowBytes[8] == 0x08 && windowBytes[15] == 0x01);
  assert(!protocol::isCurrentProfileCleanup(window, 1));
  window.profile = protocol::CURRENT_PROFILE;
  assert(protocol::isCurrentProfileCleanup(window, 2));
  assert(!protocol::isCurrentProfileCleanup(window,
                                            protocol::CURRENT_PROFILE));
  window.profile = 2;

  protocol::WindowRequest decodedWindow;
  assert(protocol::decodeWindowRequest(windowBytes, windowLength,
                                       decodedWindow));
  assert(decodedWindow.profile == window.profile);
  assert(decodedWindow.repeat == window.repeat);
  assert(decodedWindow.runNonce == window.runNonce);
  assert(std::strcmp(decodedWindow.routeFixtureId,
                     window.routeFixtureId) == 0);
  assert(std::memcmp(decodedWindow.routeFixtureSha256,
                     window.routeFixtureSha256,
                     protocol::SHA256_BYTES) == 0);
  windowBytes[4] = 2;
  assert(!protocol::decodeWindowRequest(windowBytes, windowLength,
                                        decodedWindow));
  windowBytes[4] = 1;
  windowBytes[48] = 0;
  assert(!protocol::decodeWindowRequest(windowBytes, windowLength,
                                        decodedWindow));

  std::cout << "renderer diagnostics BLE protocol tests passed\n";
  return 0;
}
