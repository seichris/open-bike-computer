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

static ScreenInstance nearbyProfile(uint32_t id, const char *name,
                                    bool enabled = true) {
  ScreenInstance instance = makeInstance(id, ScreenType::Map, name);
  instance.enabled = enabled;
  instance.mapProfile = defaultMapProfile(ScreenType::Nearby);
  instance.mapProfile.zoomLevel = 4;
  return instance;
}

static size_t instanceOffset(const std::array<uint8_t, MAX_DOCUMENT_BYTES> &bytes,
                             uint8_t target) {
  size_t offset = DOCUMENT_HEADER_BYTES;
  for (uint8_t index = 0; index < target; ++index)
    offset += INSTANCE_HEADER_BYTES + bytes[offset + 6] +
              wire_bytes::readU16(bytes.data() + offset + 7);
  return offset;
}

static void resealDocument(std::array<uint8_t, MAX_DOCUMENT_BYTES> &bytes,
                           size_t size) {
  wire_bytes::writeU32(bytes.data() + size - DOCUMENT_CRC_BYTES,
                       crc32(bytes.data(), size - DOCUMENT_CRC_BYTES));
}

// POI-enabled firmware stored these Map-format payloads as Nearby screens.
static size_t encodeStoredNearby(const Document &document, uint32_t nearbyIndexes,
                                 std::array<uint8_t, MAX_DOCUMENT_BYTES> &bytes) {
  const size_t size = encodeDocument(document, bytes.data(), bytes.size());
  assert(size > 0);
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    if ((nearbyIndexes & (1UL << index)) == 0) continue;
    const size_t offset = instanceOffset(bytes, index);
    assert(bytes[offset + 4] == static_cast<uint8_t>(ScreenType::Map));
    bytes[offset + 4] = static_cast<uint8_t>(ScreenType::Nearby);
  }
  assert(instanceOffset(bytes, document.instanceCount) == size - DOCUMENT_CRC_BYTES);
  resealDocument(bytes, size);
  return size;
}

static bool hasName(const ScreenInstance &instance, const char *name) {
  return instance.nameLength == std::strlen(name) &&
         std::memcmp(instance.name.data(), name, instance.nameLength) == 0;
}

// The normalized document is itself a valid upload for this firmware build.
static void assertPersistable(const Document &document) {
  std::array<uint8_t, MAX_DOCUMENT_BYTES> bytes{};
  const size_t size = encodeDocument(document, bytes.data(), bytes.size());
  assert(size > 0);
  Document decoded{};
  assert(decodeDocument(bytes.data(), size, decoded) == DecodeResult::Complete);
  assert(decoded.instanceCount == document.instanceCount);
}

static void testScreenActivationFrames() {
  // Golden layout shared with docs/ble-protocol.md and the iOS codec.
  ActivationRequest showMap{};
  showMap.requestID = 0x01020304;
  showMap.action = ScreenActivationAction::ShowTypes;
  showMap.typeCount = 2;
  showMap.types[0] = ScreenType::Map;
  showMap.types[1] = ScreenType::MapNavigation;
  uint8_t frame[ACTIVATION_HEADER_BYTES + MAX_ACTIVATION_TYPES]{};
  assert(encodeActivationRequest(showMap, frame, sizeof(frame)) == 12);
  const uint8_t expectedShowMap[] = {'S', 'C', 'S', 'W', 4, 3, 2, 1,
                                     0,   2,   0,   3};
  assert(std::memcmp(frame, expectedShowMap, sizeof(expectedShowMap)) == 0);
  ActivationRequest decoded{};
  assert(decodeActivationRequest(frame, 12, decoded) ==
         ActivationDecode::Valid);
  assert(decoded.requestID == 0x01020304);
  assert(decoded.action == ScreenActivationAction::ShowTypes);
  assert(decoded.typeCount == 2);
  assert(decoded.types[0] == ScreenType::Map);
  assert(decoded.types[1] == ScreenType::MapNavigation);

  ActivationRequest next{};
  next.requestID = 9;
  next.action = ScreenActivationAction::Next;
  assert(encodeActivationRequest(next, frame, sizeof(frame)) ==
         ACTIVATION_HEADER_BYTES);
  assert(decodeActivationRequest(frame, ACTIVATION_HEADER_BYTES, decoded) ==
         ActivationDecode::Valid);
  assert(decoded.action == ScreenActivationAction::Next);
  assert(decoded.typeCount == 0);
  next.action = ScreenActivationAction::Previous;
  assert(encodeActivationRequest(next, frame, sizeof(frame)) ==
         ACTIVATION_HEADER_BYTES);
  assert(decodeActivationRequest(frame, ACTIVATION_HEADER_BYTES, decoded) ==
         ActivationDecode::Valid);
  assert(decoded.action == ScreenActivationAction::Previous);

  // Encoders refuse frames the decoder would reject.
  next.typeCount = 1;
  assert(encodeActivationRequest(next, frame, sizeof(frame)) == 0);
  showMap.typeCount = 0;
  assert(encodeActivationRequest(showMap, frame, sizeof(frame)) == 0);
  showMap.typeCount = MAX_ACTIVATION_TYPES + 1;
  assert(encodeActivationRequest(showMap, frame, sizeof(frame)) == 0);
  showMap.typeCount = 2;
  showMap.requestID = 0;
  assert(encodeActivationRequest(showMap, frame, sizeof(frame)) == 0);
  showMap.requestID = 5;
  assert(encodeActivationRequest(showMap, frame, 11) == 0);

  // Malformed frames keep their request ID so the sender gets a rejection.
  uint8_t malformed[ACTIVATION_HEADER_BYTES + MAX_ACTIVATION_TYPES + 1]{};
  std::memcpy(malformed, expectedShowMap, sizeof(expectedShowMap));
  assert(decodeActivationRequest(malformed, 11, decoded) ==
         ActivationDecode::Malformed);
  assert(decoded.requestID == 0x01020304);
  assert(decodeActivationRequest(malformed, 13, decoded) ==
         ActivationDecode::Malformed);
  malformed[11] = static_cast<uint8_t>(ScreenType::Nearby) + 1;
  assert(decodeActivationRequest(malformed, 12, decoded) ==
         ActivationDecode::Malformed);
  malformed[11] = static_cast<uint8_t>(ScreenType::Nearby);
  assert(decodeActivationRequest(malformed, 12, decoded) ==
         ActivationDecode::Valid);
  malformed[8] = 3;
  assert(decodeActivationRequest(malformed, 12, decoded) ==
         ActivationDecode::Malformed);
  malformed[8] = static_cast<uint8_t>(ScreenActivationAction::Next);
  assert(decodeActivationRequest(malformed, 12, decoded) ==
         ActivationDecode::Malformed);
  malformed[8] = static_cast<uint8_t>(ScreenActivationAction::ShowTypes);
  malformed[9] = 0;
  assert(decodeActivationRequest(malformed, ACTIVATION_HEADER_BYTES,
                                 decoded) == ActivationDecode::Malformed);
  malformed[9] = MAX_ACTIVATION_TYPES + 1;
  assert(decodeActivationRequest(malformed, sizeof(malformed), decoded) ==
         ActivationDecode::Malformed);
  std::memset(malformed + 4, 0, 4);
  malformed[9] = 1;
  assert(decodeActivationRequest(malformed, 11, decoded) ==
         ActivationDecode::Malformed);
  assert(decoded.requestID == 0);
  assert(decodeActivationRequest(malformed, 6, decoded) ==
         ActivationDecode::Malformed);
  uint8_t request[REQUEST_BYTES]{};
  assert(encodeRequest(42, request, sizeof(request)) == REQUEST_BYTES);
  assert(decodeActivationRequest(request, sizeof(request), decoded) ==
         ActivationDecode::NotActivation);

  uint8_t result[ACTIVATION_RESULT_BYTES]{};
  assert(encodeActivationResult(0x01020304, ScreenActivationResult::Switched,
                                0x0A0B0C0D,
                                static_cast<uint8_t>(ScreenType::RideStats),
                                result, sizeof(result)) ==
         ACTIVATION_RESULT_BYTES);
  const uint8_t expectedResult[] = {'S', 'C', 'S', 'R', 4,   3,   2,
                                    1,   0,   13,  12,  11,  10,  2};
  assert(std::memcmp(result, expectedResult, sizeof(expectedResult)) == 0);
  assert(encodeActivationResult(0, ScreenActivationResult::Busy, 0,
                                ACTIVATION_NO_SCREEN_TYPE, result,
                                sizeof(result)) == 0);
  assert(encodeActivationResult(1, ScreenActivationResult::Busy, 0,
                                ACTIVATION_NO_SCREEN_TYPE, result,
                                ACTIVATION_RESULT_BYTES - 1) == 0);
}

static void testStoredNearbyScreens() {
  constexpr bool runtime = map_profile_protocol::POIS_RUNTIME_ENABLED;
  std::array<uint8_t, MAX_DOCUMENT_BYTES> bytes{};
  Document decoded{};
  bool normalized = true;

  // Custom screens around two Nearby screens keep order, IDs and settings.
  Document mixed{};
  mixed.defaultInstanceID = 4;
  mixed.instanceCount = 6;
  mixed.instances[0] = makeInstance(4, ScreenType::MapNavigation, "Map + Navigation");
  mixed.instances[1] = nearbyProfile(9, "Nearby");
  mixed.instances[2] = makeInstance(3, ScreenType::RideStats, "Ride Stats");
  mixed.instances[2].rideStatsLayout.slots[0] = RideStatsWidget::Distance;
  mixed.instances[3] = makeInstance(1, ScreenType::Map, "Commute");
  mixed.instances[3].mapProfile.zoomLevel = 5;
  mixed.instances[4] = nearbyProfile(10, "Food", false);
  mixed.instances[5] = makeInstance(2, ScreenType::Navigation, "Navigation");
  mixed.instances[5].enabled = false;
  size_t size = encodeStoredNearby(mixed, (1U << 1) | (1U << 4), bytes);
  assert(decodeDocument(bytes.data(), size, decoded) ==
         (runtime ? DecodeResult::Complete : DecodeResult::Unsupported));
  assert(decodeDocument(bytes.data(), size, decoded, true, &normalized) ==
         DecodeResult::Complete);
  if (runtime) {
    assert(!normalized && decoded.instanceCount == 6);
    assert(decoded.instances[1].type == ScreenType::Nearby);
    assert(decoded.instances[4].type == ScreenType::Nearby &&
           !decoded.instances[4].enabled);
  } else {
    assert(normalized && decoded.instanceCount == 4);
    const uint32_t ids[] = {4, 3, 1, 2};
    for (uint8_t index = 0; index < 4; ++index)
      assert(decoded.instances[index].id == ids[index]);
    assert(decoded.defaultInstanceID == 4);
    assert(decoded.instances[1].rideStatsLayout.slots[0] == RideStatsWidget::Distance);
    assert(hasName(decoded.instances[2], "Commute") &&
           decoded.instances[2].mapProfile.zoomLevel == 5);
    assert(!decoded.instances[3].enabled);
    assert(decoded.instances[4].id == 0); // no stale trailing instance
    assertPersistable(decoded);
  }

  // A removed default moves to the first enabled screen; disabled screens
  // stay disabled.
  Document defaultNearby{};
  defaultNearby.defaultInstanceID = 9;
  defaultNearby.instanceCount = 3;
  defaultNearby.instances[0] = makeInstance(3, ScreenType::RideStats, "Ride Stats");
  defaultNearby.instances[0].enabled = false;
  defaultNearby.instances[1] = nearbyProfile(9, "Nearby");
  defaultNearby.instances[2] = makeInstance(1, ScreenType::Map, "Map");
  size = encodeStoredNearby(defaultNearby, 1U << 1, bytes);
  assert(decodeDocument(bytes.data(), size, decoded, true, &normalized) ==
         DecodeResult::Complete);
  if (runtime) {
    assert(!normalized && decoded.defaultInstanceID == 9);
  } else {
    assert(normalized && decoded.instanceCount == 2);
    assert(decoded.instances[0].id == 3 && !decoded.instances[0].enabled);
    assert(decoded.instances[1].id == 1 && decoded.defaultInstanceID == 1);
    assertPersistable(decoded);
  }

  // With no other enabled screen, the default Nearby screen becomes an
  // enabled Map screen in place, keeping its ID and map settings.
  Document onlyNearby{};
  onlyNearby.defaultInstanceID = 7;
  onlyNearby.instanceCount = 2;
  onlyNearby.instances[0] = nearbyProfile(7, "Nearby");
  onlyNearby.instances[1] = nearbyProfile(8, "Food", false);
  size = encodeStoredNearby(onlyNearby, 0b11, bytes);
  assert(decodeDocument(bytes.data(), size, decoded, true, &normalized) ==
         DecodeResult::Complete);
  if (runtime) {
    assert(!normalized && decoded.instanceCount == 2);
  } else {
    assert(normalized && decoded.instanceCount == 1);
    const ScreenInstance &map = decoded.instances[0];
    assert(map.id == 7 && map.type == ScreenType::Map && map.enabled);
    assert(hasName(map, "Map") && map.mapProfile.zoomLevel == 4);
    assert((map.mapProfile.visibilityMask &
            map_profile_protocol::VISIBILITY_POI_MASK) == 0);
    assert(decoded.defaultInstanceID == 7);
    assertPersistable(decoded);
  }

  Document disabledOthers{};
  disabledOthers.defaultInstanceID = 7;
  disabledOthers.instanceCount = 3;
  disabledOthers.instances[0] = makeInstance(1, ScreenType::Map, "Map");
  disabledOthers.instances[0].enabled = false;
  disabledOthers.instances[1] = nearbyProfile(7, "Nearby");
  disabledOthers.instances[2] = makeInstance(2, ScreenType::Navigation, "Navigation");
  disabledOthers.instances[2].enabled = false;
  size = encodeStoredNearby(disabledOthers, 1U << 1, bytes);
  assert(decodeDocument(bytes.data(), size, decoded, true, &normalized) ==
         DecodeResult::Complete);
  if (!runtime) {
    assert(normalized && decoded.instanceCount == 3);
    assert(decoded.instances[0].id == 1 && !decoded.instances[0].enabled);
    assert(decoded.instances[1].id == 7 &&
           decoded.instances[1].type == ScreenType::Map &&
           decoded.instances[1].enabled);
    assert(decoded.instances[2].id == 2 && !decoded.instances[2].enabled);
    assert(decoded.defaultInstanceID == 7);
    assertPersistable(decoded);
  }

  // An already invalid document (every screen disabled) is not repaired.
  size = encodeStoredNearby(disabledOthers, 1U << 1, bytes);
  bytes[instanceOffset(bytes, 1) + 5] = 0;
  resealDocument(bytes, size);
  assert(decodeDocument(bytes.data(), size, decoded, true, &normalized) ==
         DecodeResult::Malformed);

  // CRC, truncation and unknown screen types still fail closed when stored.
  size = encodeStoredNearby(mixed, (1U << 1) | (1U << 4), bytes);
  auto corrupted = bytes;
  corrupted[DOCUMENT_HEADER_BYTES + INSTANCE_HEADER_BYTES + 3] ^= 1;
  assert(decodeDocument(corrupted.data(), size, decoded, true, &normalized) ==
         DecodeResult::Malformed);
  assert(decodeDocument(bytes.data(), size - 1, decoded, true, &normalized) ==
         DecodeResult::Malformed);
  auto unknown = bytes;
  assert(unknown[instanceOffset(unknown, 1) + 4] ==
         static_cast<uint8_t>(ScreenType::Nearby));
  unknown[instanceOffset(unknown, 1) + 4] =
      static_cast<uint8_t>(ScreenType::Nearby) + 1;
  resealDocument(unknown, size);
  assert(decodeDocument(unknown.data(), size, decoded, true, &normalized) ==
         DecodeResult::Unsupported);
}

int main() {
  testStoredNearbyScreens();
  assert((defaultMapProfile(ScreenType::Map).visibilityMask &
          map_profile_protocol::VISIBILITY_POI_MASK) ==
         (map_profile_protocol::POIS_RUNTIME_ENABLED ?
          map_profile_protocol::VISIBILITY_POI_MASK : 0U));
#if !MAP_POIS_RUNTIME_ENABLED
  // A CRC-checked document left by POI-enabled firmware can shed only its
  // unsupported bits on load. The same wire upload must still be rejected.
  Document stored = makeDocument();
  std::array<uint8_t, MAX_DOCUMENT_BYTES> storedBytes{};
  const size_t storedSize = encodeDocument(stored, storedBytes.data(), storedBytes.size());
  assert(storedSize > 0);
  const size_t maskOffset = DOCUMENT_HEADER_BYTES + INSTANCE_HEADER_BYTES +
      stored.instances[0].nameLength + 7;
  const uint32_t mask = stored.instances[0].mapProfile.visibilityMask |
      map_profile_protocol::VISIBILITY_POI_MASK;
  wire_bytes::writeU32(storedBytes.data() + maskOffset, mask);
  wire_bytes::writeU32(storedBytes.data() + storedSize - 4,
                       crc32(storedBytes.data(), storedSize - 4));
  Document normalizedDocument{};
  bool normalized = false;
  assert(decodeDocument(storedBytes.data(), storedSize, normalizedDocument) != DecodeResult::Complete);
  assert(decodeDocument(storedBytes.data(), storedSize, normalizedDocument, true,
                        &normalized) == DecodeResult::Complete);
  assert(normalized);
  assert((normalizedDocument.instances[0].mapProfile.visibilityMask &
          map_profile_protocol::VISIBILITY_POI_MASK) == 0);
#endif
  Document nearbyOnly{};
  nearbyOnly.instanceCount = 1;
  nearbyOnly.defaultInstanceID = 7;
  nearbyOnly.instances[0] = makeInstance(7, ScreenType::Nearby, "Nearby");
#if MAP_POIS_RUNTIME_ENABLED
  assert(isSupportedScreenType(ScreenType::Nearby));
  assert((nearbyOnly.instances[0].mapProfile.visibilityMask &
          map_profile_protocol::VISIBILITY_POI_MASK) == 0);
  nearbyOnly.instances[0].mapProfile.visibilityMask |=
      map_profile_protocol::VISIBILITY_CONTOURS;
  assert(validate(nearbyOnly) == ValidationError::None);
  std::array<uint8_t, MAX_DOCUMENT_BYTES> nearbyBytes{};
  const auto nearbySize = encodeDocument(
      nearbyOnly, nearbyBytes.data(), nearbyBytes.size());
  assert(nearbySize > 0);
  Document nearbyDecoded{};
  assert(decodeDocument(nearbyBytes.data(), nearbySize, nearbyDecoded) ==
         DecodeResult::Complete);
  assert(nearbyDecoded.instances[0].type == ScreenType::Nearby);
  assert((nearbyDecoded.instances[0].mapProfile.visibilityMask &
          map_profile_protocol::VISIBILITY_CONTOURS) != 0);
#else
  assert(!isSupportedScreenType(ScreenType::Nearby));
  assert(validate(nearbyOnly) == ValidationError::UnsupportedType);
#endif

  Document radio{};
  radio.instanceCount = 1;
  radio.defaultInstanceID = 6;
  radio.instances[0] = makeInstance(6, ScreenType::WorldRadio, "World Radio");
  assert(isSupportedScreenType(ScreenType::WorldRadio) == world_radio_config::ENABLED);
  std::array<uint8_t, MAX_DOCUMENT_BYTES> radioBytes{};
  const auto radioSize = encodeDocument(radio, radioBytes.data(), radioBytes.size());
  if (world_radio_config::ENABLED) {
    assert(radioSize > 0);
    Document radioDecoded{};
    assert(decodeDocument(radioBytes.data(), radioSize, radioDecoded) == DecodeResult::Complete);
    assert(radioDecoded.instances[0].type == ScreenType::WorldRadio);
  } else {
    assert(validate(radio) == ValidationError::UnsupportedType);
    assert(radioSize == 0);
  }
  // Both new orientations round-trip; old pre-integration payloads retain
  // their historical Course Up navigation behavior.
  for (uint8_t rotation = 0; rotation <= 1; ++rotation) {
    auto profile = defaultMapProfile(ScreenType::MapNavigation);
    assert(profile.rotationMode == 1);
    profile.rotationMode = rotation;
    uint8_t payload[MAP_NAVIGATION_PAYLOAD_BYTES]{};
    Writer writer(payload, sizeof(payload));
    assert(encodeMapProfile(writer, profile, ScreenType::MapNavigation));
    assert(writer.size() == 19 && payload[18] == rotation);
    MapProfile decodedProfile{};
    Reader reader(payload, sizeof(payload));
    assert(decodeMapProfile(reader, sizeof(payload), ScreenType::MapNavigation,
                            decodedProfile));
    assert(reader.remaining() == 0 && decodedProfile.rotationMode == rotation);
    Reader legacyReader(payload, 18);
    assert(decodeMapProfile(legacyReader, 18, ScreenType::MapNavigation,
                            decodedProfile));
    assert(legacyReader.remaining() == 0 && decodedProfile.rotationMode == 1);
  }
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
  assert((document.instances[2].mapProfile.visibilityMask &
          map_profile_protocol::VISIBILITY_CONTOURS) == 0);
  document.instances[2].mapProfile.visibilityMask |=
      map_profile_protocol::VISIBILITY_CONTOURS;
  assert(validate(document) == ValidationError::None);

  auto terrainDocument = document;
  terrainDocument.instances[2].mapProfile.visibilityMask |= 1u << 17;
  assert((validate(terrainDocument) == ValidationError::None) == (FIRMWARE_DIAGNOSTICS != 0));
  terrainDocument.instances[0].mapProfile.visibilityMask |= 1u << 17;
  assert(validate(terrainDocument) != ValidationError::None);

  std::array<uint8_t, MAX_DOCUMENT_BYTES> encoded{};
  const std::size_t size =
      encodeDocument(document, encoded.data(), encoded.size());
  assert(size > 0);
  assert(documentCRC(encoded.data(), size) == crc32(encoded.data(), size - 4));

  Document decoded{};
  assert(decodeDocument(encoded.data(), size, decoded) ==
         DecodeResult::Complete);
  assert((decoded.instances[2].mapProfile.visibilityMask &
          map_profile_protocol::VISIBILITY_CONTOURS) != 0);
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
  invalid.instances[0].mapProfile.rotationMode = 2;
  assert(validate(invalid) == ValidationError::InvalidPayload);
  invalid = document;
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
  testScreenActivationFrames();
  return 0;
}
