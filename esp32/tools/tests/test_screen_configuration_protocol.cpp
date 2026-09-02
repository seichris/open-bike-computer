#include "../../lib/ble_navigation/screen_configuration_protocol.hpp"

#include <cassert>
#include <cstring>

using namespace screen_configuration_protocol;

static ScreenInstance makeInstance(uint32_t id, ScreenType type,
                                   const char *name) {
  ScreenInstance instance{};
  instance.id = id;
  instance.type = type;
  instance.enabled = true;
  instance.mapProfile = defaultMapProfile(type);
  assert(setName(instance, name, std::strlen(name)));
  return instance;
}

static Document makeDocument() {
  Document document{};
  document.defaultInstanceID = 4;
  document.instanceCount = 5;
  document.instances[0] =
      makeInstance(4, ScreenType::MapNavigation, "Map + Navigation");
  document.instances[1] = makeInstance(3, ScreenType::RideStats, "Ride Stats");
  document.instances[2] = makeInstance(1, ScreenType::Map, "Map");
  document.instances[3] = makeInstance(2, ScreenType::Navigation, "Navigation");
  document.instances[4] =
      makeInstance(5, ScreenType::BatteryStatus, "Battery Status");
  return document;
}

int main() {
  Document minimal{};
  minimal.defaultInstanceID = 0x01020304;
  minimal.instanceCount = 1;
  minimal.instances[0] =
      makeInstance(0x01020304, ScreenType::Navigation, "Nav");
  std::array<uint8_t, MAX_DOCUMENT_BYTES> minimalEncoded{};
  const std::size_t minimalSize = encodeDocument(
      minimal, minimalEncoded.data(), minimalEncoded.size());
  const uint8_t golden[] = {
      0x53, 0x43, 0x56, 0x31, 0x01, 0x01, 0x04, 0x03, 0x02,
      0x01, 0x04, 0x03, 0x02, 0x01, 0x01, 0x01, 0x03, 0x01,
      0x00, 0x4e, 0x61, 0x76, 0x01, 0xd1, 0xb4, 0x07, 0x6f,
  };
  static_assert(sizeof(golden) == 27);
  assert(minimalSize == sizeof(golden));
  assert(std::memcmp(minimalEncoded.data(), golden, sizeof(golden)) == 0);

  Document document = makeDocument();
  assert(validate(document) == ValidationError::None);

  std::array<uint8_t, MAX_DOCUMENT_BYTES> encoded{};
  const std::size_t size =
      encodeDocument(document, encoded.data(), encoded.size());
  assert(size > 0);
  assert(documentCRC(encoded.data(), size) == crc32(encoded.data(), size - 4));

  Document decoded{};
  assert(decodeDocument(encoded.data(), size, decoded) ==
         DecodeResult::Complete);
  std::array<uint8_t, MAX_DOCUMENT_BYTES> reencoded{};
  const std::size_t reencodedSize =
      encodeDocument(decoded, reencoded.data(), reencoded.size());
  assert(reencodedSize == size);
  assert(std::memcmp(encoded.data(), reencoded.data(), size) == 0);

  auto corrupted = encoded;
  corrupted[5] ^= 1;
  assert(decodeDocument(corrupted.data(), size, decoded) ==
         DecodeResult::Malformed);
  assert(decodeDocument(encoded.data(), size - 1, decoded) ==
         DecodeResult::Malformed);

  Document invalid = document;
  invalid.instances[1].id = invalid.instances[0].id;
  assert(validate(invalid) == ValidationError::DuplicateID);
  invalid = document;
  invalid.instances[0].enabled = false;
  invalid.instances[1].enabled = false;
  invalid.instances[2].enabled = false;
  invalid.instances[3].enabled = false;
  invalid.instances[4].enabled = false;
  assert(validate(invalid) == ValidationError::AllDisabled);
  invalid = document;
  invalid.defaultInstanceID = 99;
  assert(validate(invalid) == ValidationError::InvalidDefault);
  invalid = document;
  for (auto &widget : invalid.instances[1].rideStatsLayout.slots)
    widget = RideStatsWidget::Empty;
  assert(validate(invalid) == ValidationError::EmptyRideStatsLayout);
  invalid = document;
  invalid.instances[0].mapProfile.routeLineWidth = 1;
  assert(validate(invalid) == ValidationError::InvalidPayload);
  invalid = document;
  invalid.instances[0].name[0] = '\n';
  assert(validate(invalid) == ValidationError::InvalidName);
  invalid = document;
  invalid.instances[0].name[0] = static_cast<char>(0xc2);
  invalid.instances[0].name[1] = static_cast<char>(0x80);
  invalid.instances[0].name[2] = '\0';
  invalid.instances[0].nameLength = 2;
  assert(validate(invalid) == ValidationError::InvalidName);

  uint8_t capability[2 + CAPABILITIES_TLV_VALUE_BYTES]{};
  assert(encodeCapabilitiesTLV(capability, sizeof(capability)) ==
         sizeof(capability));
  uint8_t schema = 0;
  uint8_t maximumInstances = 0;
  uint8_t maximumNameBytes = 0;
  uint8_t slotCount = 0;
  uint32_t screenTypes = 0;
  uint32_t widgets = 0;
  uint16_t maximumDocumentBytes = 0;
  assert(decodeCapabilitiesTLV(
      capability + 2, CAPABILITIES_TLV_VALUE_BYTES, schema, maximumInstances,
      maximumNameBytes, slotCount, screenTypes, widgets,
      maximumDocumentBytes));
  assert(screenTypes == SUPPORTED_SCREEN_TYPES);
  assert(widgets == SUPPORTED_RIDE_STATS_WIDGETS);
  assert(maximumInstances == MAX_INSTANCES);
  assert(maximumNameBytes == MAX_NAME_BYTES);
  assert(slotCount == RIDE_STATS_SLOT_COUNT);
  assert(maximumDocumentBytes == MAX_DOCUMENT_BYTES);

  uint8_t request[REQUEST_BYTES]{};
  assert(encodeRequest(42, request, sizeof(request)) == REQUEST_BYTES);
  uint32_t requestID = 0;
  assert(decodeRequest(request, sizeof(request), requestID));
  assert(requestID == 42);

  uint8_t first[CHUNK_HEADER_BYTES + 3]{};
  uint8_t second[CHUNK_HEADER_BYTES + 2]{};
  const uint8_t firstPayload[] = {1, 2, 3};
  const uint8_t secondPayload[] = {4, 5};
  assert(encodeChunk(
             ride_ble_protocol_generated::SCREEN_CONFIGURATION_UPLOAD_MAGIC,
             7, 3, 0, 2, firstPayload, sizeof(firstPayload), first,
             sizeof(first)) == sizeof(first));
  assert(encodeChunk(
             ride_ble_protocol_generated::SCREEN_CONFIGURATION_UPLOAD_MAGIC,
             7, 3, 1, 2, secondPayload, sizeof(secondPayload), second,
             sizeof(second)) == sizeof(second));
  UploadReassembler reassembler;
  assert(reassembler.consume(first, sizeof(first), 100) ==
         ChunkResult::Accepted);
  assert(reassembler.consume(second, sizeof(second), 101) ==
         ChunkResult::Complete);
  assert(reassembler.payloadLength() == 5);
  const uint8_t expectedPayload[] = {1, 2, 3, 4, 5};
  assert(std::memcmp(reassembler.payload(), expectedPayload, 5) == 0);

  reassembler.reset();
  assert(reassembler.consume(second, sizeof(second), 100) ==
         ChunkResult::Rejected);
  assert(reassembler.consume(first, sizeof(first), 100) ==
         ChunkResult::Accepted);
  assert(reassembler.consume(second, sizeof(second), 6001) ==
         ChunkResult::Rejected);

  uint8_t acknowledgement[ACK_BYTES]{};
  assert(encodeAcknowledgement(
             7,
             ride_ble_protocol_generated::ScreenConfigurationResult::Applied,
             4, documentCRC(encoded.data(), size), acknowledgement,
             sizeof(acknowledgement)) == ACK_BYTES);
  ride_ble_protocol_generated::ScreenConfigurationResult result{};
  uint32_t revision = 0;
  uint32_t checksum = 0;
  assert(decodeAcknowledgement(acknowledgement, sizeof(acknowledgement),
                               requestID, result, revision, checksum));
  assert(requestID == 7);
  assert(result ==
         ride_ble_protocol_generated::ScreenConfigurationResult::Applied);
  assert(revision == 4);
  assert(checksum == documentCRC(encoded.data(), size));
  return 0;
}
