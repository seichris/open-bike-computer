#include "../../lib/world_radio/world_radio_protocol.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  using namespace world_radio_protocol;

  Request request{};
  request.command = Command::SelectLocation;
  request.requestId = 0x12345678;
  request.latitudeE7 = 312304000;
  request.longitudeE7 = 1214737000;
  uint8_t requestBytes[REQUEST_BYTES]{};
  assert(encodeRequest(request, requestBytes, sizeof(requestBytes)));
  assert(std::memcmp(requestBytes, "WRQ1", 4) == 0);
  assert(requestBytes[4] == VERSION);
  Request decodedRequest{};
  assert(decodeRequest(requestBytes, sizeof(requestBytes), decodedRequest));
  assert(decodedRequest.command == request.command);
  assert(decodedRequest.requestId == request.requestId);
  assert(decodedRequest.latitudeE7 == request.latitudeE7);
  assert(decodedRequest.longitudeE7 == request.longitudeE7);
  request.requestId = 0;
  assert(!encodeRequest(request, requestBytes, sizeof(requestBytes)));

  Status status{};
  status.state = PlaybackState::Playing;
  status.favorite = true;
  status.hasStation = true;
  status.stationIndex = 2;
  status.stationCount = 7;
  status.bitrateKbps = 96;
  status.requestId = 0x12345678;
  status.stationLatitudeE7 = 356817000;
  status.stationLongitudeE7 = 1397671000;
  std::memcpy(status.countryCode, "JP", 2);
  std::strcpy(status.stationName, "Tokyo Community Radio");
  std::strcpy(status.place, "Tokyo");
  std::strcpy(status.message, "Playing on iPhone");
  uint8_t statusBytes[STATUS_MAX_BYTES]{};
  std::size_t written = 0;
  assert(encodeStatus(status, statusBytes, sizeof(statusBytes), written));
  assert(written > STATUS_HEADER_BYTES);
  Status decodedStatus{};
  assert(decodeStatus(statusBytes, written, decodedStatus));
  assert(decodedStatus.state == PlaybackState::Playing);
  assert(decodedStatus.favorite);
  assert(decodedStatus.hasStation);
  assert(decodedStatus.requestId == status.requestId);
  assert(std::strcmp(decodedStatus.stationName, status.stationName) == 0);
  assert(std::strcmp(decodedStatus.place, status.place) == 0);
  assert(std::strcmp(decodedStatus.message, status.message) == 0);
  statusBytes[31] = 1;
  assert(!decodeStatus(statusBytes, written, decodedStatus));

  std::cout << "world radio protocol tests passed\n";
  return 0;
}
