// Firmware builds define VERSION as a string in their compiler flags.
// Keep the codec usable under that same preprocessor environment.
#define VERSION "firmware-build-version"
#include "../../lib/world_radio/world_radio_protocol.hpp"
#undef VERSION

#include <cassert>
#include <cstring>
#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "../../lib/gui/src/mainScreenRegistry.hpp"
#include "../../lib/ble_navigation/screen_configuration_protocol.hpp"

int main(int argc, char **argv) {
  using Screen = ride_ble_protocol_generated::ScreenType;
  static_assert(static_cast<uint8_t>(Screen::Map) == 0);
  static_assert(static_cast<uint8_t>(Screen::Navigation) == 1);
  static_assert(static_cast<uint8_t>(Screen::RideStats) == 2);
  static_assert(static_cast<uint8_t>(Screen::MapPlusNavigation) == 3);
  static_assert(static_cast<uint8_t>(Screen::BatteryStatus) == 4);
  static_assert(static_cast<uint8_t>(Screen::WorldRadio) == 5);
  static_assert(Screen::MapNavigation == Screen::MapPlusNavigation);
  static_assert(main_screen_registry::DeviceScreenId::WorldRadio ==
                screen_configuration_protocol::ScreenType::WorldRadio);

  // Helpers must work with deliberately unaligned input and signed bit patterns.
  uint8_t unaligned[9]{};
  wire_bytes::writeU32(unaligned + 1, 0x80000001U);
  assert(wire_bytes::readU32(unaligned + 1) == 0x80000001U);
  wire_bytes::writeU16(unaligned + 5, 0xabcdU);
  assert(wire_bytes::readU16(unaligned + 5) == 0xabcdU);

  std::ifstream input(argc > 1 ? argv[1] : "protocol/fixtures/world-radio-v1.txt");
  if (!input && argc == 1) input.open("../protocol/fixtures/world-radio-v1.txt");
  assert(input && "run from repo root/esp32 or provide the fixture path");
  std::string line;
  unsigned checked = 0;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream fields(line);
    std::string name, hex;
    fields >> name >> hex;
    assert(!name.empty() && !hex.empty() && hex.size() % 2 == 0);
    std::vector<uint8_t> bytes;
    for (std::size_t i = 0; i < hex.size(); i += 2)
      bytes.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
    world_radio_protocol::Request request{};
    world_radio_protocol::Status status{};
    if (name.rfind("request_", 0) == 0) {
      assert(world_radio_protocol::decodeRequest(bytes.data(), bytes.size(), request));
      if (name == "request_negative") {
        assert(request.latitudeE7 == -338688000 && request.longitudeE7 == -1800000000);
        assert(request.requestId == UINT32_MAX);
      }
      uint8_t encoded[world_radio_protocol::REQUEST_BYTES]{};
      assert(world_radio_protocol::encodeRequest(request, encoded, sizeof(encoded)));
      assert(bytes == std::vector<uint8_t>(encoded, encoded + sizeof(encoded)));
    } else if (name.rfind("status_", 0) == 0) {
      assert(world_radio_protocol::decodeStatus(bytes.data(), bytes.size(), status));
      if (name == "status_bounded") {
        assert(std::strlen(status.stationName) == 48);
        assert(std::strlen(status.place) == 28);
        assert(std::strlen(status.message) == 24);
      }
      if (name == "status_negative") {
        assert(status.stationLatitudeE7 == -338688000);
        assert(status.stationLongitudeE7 == -1800000000);
        assert(std::strcmp(status.place, "España") == 0);
      }
      uint8_t encoded[world_radio_protocol::STATUS_MAX_BYTES]{};
      std::size_t written = 0;
      assert(world_radio_protocol::encodeStatus(status, encoded, sizeof(encoded), written));
      assert(bytes == std::vector<uint8_t>(encoded, encoded + written));
    } else if (name.rfind("invalid_request_", 0) == 0) {
      assert(!world_radio_protocol::decodeRequest(bytes.data(), bytes.size(), request));
    } else if (name.rfind("invalid_status_", 0) == 0) {
      assert(!world_radio_protocol::decodeStatus(bytes.data(), bytes.size(), status));
    } else { assert(false && "unknown fixture kind"); }
    ++checked;
  }
  assert(checked == 20);

  using namespace world_radio_protocol;

  Request request{};
  request.command = Command::SelectLocation;
  request.requestId = 0x12345678;
  request.latitudeE7 = 312304000;
  request.longitudeE7 = 1214737000;
  uint8_t requestBytes[REQUEST_BYTES]{};
  assert(encodeRequest(request, requestBytes, sizeof(requestBytes)));
  assert(std::memcmp(requestBytes, "WRQ1", 4) == 0);
  assert(requestBytes[4] == 1);
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
