#include "screen_configuration.hpp"

#include "ble_navigation.hpp"
#include "map_profile_persistence.hpp"

#include <Preferences.h>

#include <algorithm>
#include <array>
#include <cstring>

namespace screen_configuration {
namespace {

constexpr char kNamespace[] = "screenCfg";
constexpr char kSlotAKey[] = "slotA";
constexpr char kSlotBKey[] = "slotB";
constexpr char kHeadKey[] = "head";
constexpr char kMirrorRevisionKey[] = "mirrorRev";
constexpr char kMirrorTransactionKey[] = "mirrorTxn";
constexpr uint8_t kSlotMagic[4] = {'S', 'C', 'S', '1'};
constexpr uint8_t kHeadMagic[4] = {'S', 'C', 'H', '1'};
constexpr std::size_t kSlotHeaderBytes = 14;
constexpr std::size_t kSlotCRCBytes = 4;
constexpr std::size_t kMaximumSlotBytes =
    kSlotHeaderBytes + screen_configuration_protocol::MAX_DOCUMENT_BYTES +
    kSlotCRCBytes;
constexpr std::size_t kHeadBytes = 13;
constexpr uint32_t kLegacyDebounceMs = 250;
constexpr std::size_t kReplayWindow = 4;

struct SlotRecord {
  bool valid = false;
  char slot = 'A';
  uint32_t revision = 0;
  uint32_t legacyDigest = 0;
  uint32_t blobCRC = 0;
  std::size_t documentLength = 0;
  Document document{};
};

struct ReplayRecord {
  bool valid = false;
  uint32_t requestID = 0;
  uint32_t candidateCRC = 0;
  CommitOutcome outcome{};
};

Preferences preferences;
Snapshot active{};
bool ready = false;
char activeSlot = 'A';
uint32_t activeLegacyDigest = 0;
uint32_t legacyChangedAtMs = 0;
bool legacyChangePending = false;
uint32_t internalRequestID = 0x40000000UL;
std::array<uint8_t, kMaximumSlotBytes> slotBuffer{};
std::array<uint8_t, screen_configuration_protocol::MAX_DOCUMENT_BYTES>
    documentBuffer{};
std::array<ReplayRecord, kReplayWindow> replayRecords{};
std::size_t nextReplayRecord = 0;

MapProfile captureProfile(const ScreenMapRenderSettings &source,
                          const MapRenderSettings &legacy, ScreenType type) {
  MapProfile profile{};
  profile.minPolygonSize = source.minPolygonSize;
  profile.detailLevel = source.detailLevel;
  profile.routeLineWidth = source.routeLineWidth;
  profile.streetLineWidth = source.streetLineWidth;
  profile.positionMarkerScale = source.positionMarkerScale;
  profile.zoomLevel = source.zoomLevel;
  profile.visibilityMask =
      source.visibilityMask | legacy.navigationOverlayVisibilityMask;
  profile.labelDensity = source.labelDensity;
  profile.labelLanguageMode = source.labelLanguageMode;
  profile.labelTextSize = source.labelTextSize;
  profile.labelOrientation = source.labelOrientation;
  if (type == ScreenType::Map) {
    profile.rotationMode = legacy.mapRotationMode;
  } else {
    profile.birdsEyeEnabled = legacy.mapNavigationBirdsEyeEnabled;
    profile.birdsEyePerspective = legacy.mapNavigationBirdsEyePerspective;
    profile.buildings3DEnabled = legacy.mapNavigation3DBuildingsEnabled;
  }
  return profile;
}

void applyProfile(const MapProfile &source, ScreenMapRenderSettings &target) {
  target.minPolygonSize = source.minPolygonSize;
  target.detailLevel = source.detailLevel;
  target.routeLineWidth = source.routeLineWidth;
  target.streetLineWidth = source.streetLineWidth;
  target.positionMarkerScale = source.positionMarkerScale;
  target.zoomLevel = source.zoomLevel;
  target.visibilityMask =
      source.visibilityMask &
      map_profile_protocol::VISIBILITY_EXTENDED_FEATURE_MASK;
  target.labelDensity = source.labelDensity;
  target.labelLanguageMode = source.labelLanguageMode;
  target.labelTextSize = source.labelTextSize;
  target.labelOrientation = source.labelOrientation;
}

const ScreenInstance *primaryInstance(const Document &document,
                                      ScreenType type) {
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    const ScreenInstance &instance = document.instances[index];
    if (instance.enabled && instance.type == type)
      return &instance;
  }
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    if (document.instances[index].type == type)
      return &document.instances[index];
  }
  return nullptr;
}

uint8_t screenMask(const Document &document) {
  uint8_t mask = 0;
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    const ScreenInstance &instance = document.instances[index];
    if (instance.enabled)
      mask |= static_cast<uint8_t>(1U << static_cast<uint8_t>(instance.type));
  }
  return mask;
}

uint32_t legacyDigest(const MapRenderSettings &settings) {
  std::array<uint8_t, 64> bytes{};
  std::size_t count = 0;
  auto append = [&](uint8_t value) { bytes[count++] = value; };
  auto appendProfile = [&](const ScreenMapRenderSettings &profile) {
    append(profile.minPolygonSize);
    append(profile.detailLevel);
    append(profile.routeLineWidth);
    append(profile.streetLineWidth);
    append(profile.positionMarkerScale);
    append(profile.zoomLevel);
    screen_configuration_protocol::writeUInt32LE(bytes.data() + count,
                                                  profile.visibilityMask);
    count += 4;
    append(profile.labelDensity);
    append(profile.labelLanguageMode);
    append(profile.labelTextSize);
    append(profile.labelOrientation);
  };
  appendProfile(settings.mapStyle);
  appendProfile(settings.mapNavigationStyle);
  append(settings.mapNavigationBirdsEyeEnabled ? 1 : 0);
  append(settings.mapNavigationBirdsEyePerspective);
  append(settings.mapNavigation3DBuildingsEnabled ? 1 : 0);
  append(settings.mapRotationMode);
  append(settings.enabledScreensMask);
  append(settings.defaultScreen);
  screen_configuration_protocol::writeUInt32LE(
      bytes.data() + count, settings.navigationOverlayVisibilityMask);
  count += 4;
  return screen_configuration_protocol::crc32(bytes.data(), count);
}

void projectDocument(const Document &document, MapRenderSettings &settings) {
  if (const ScreenInstance *map = primaryInstance(document, ScreenType::Map)) {
    applyProfile(map->mapProfile, settings.mapStyle);
    settings.mapRotationMode = map->mapProfile.rotationMode;
  }
  if (const ScreenInstance *navigation =
          primaryInstance(document, ScreenType::MapNavigation)) {
    applyProfile(navigation->mapProfile, settings.mapNavigationStyle);
    settings.mapNavigationBirdsEyeEnabled =
        navigation->mapProfile.birdsEyeEnabled;
    settings.mapNavigationBirdsEyePerspective =
        navigation->mapProfile.birdsEyePerspective;
    settings.mapNavigation3DBuildingsEnabled =
        navigation->mapProfile.buildings3DEnabled;
  }
  settings.enabledScreensMask = screenMask(document);
  const uint8_t defaultIndex = defaultInstanceIndex(document);
  if (defaultIndex != kInvalidInstanceIndex)
    settings.defaultScreen =
        static_cast<uint8_t>(document.instances[defaultIndex].type);
  const ScreenInstance *overlaySource =
      primaryInstance(document, ScreenType::Map);
  if (overlaySource == nullptr)
    overlaySource = primaryInstance(document, ScreenType::MapNavigation);
  if (overlaySource != nullptr) {
    settings.navigationOverlayVisibilityMask =
        overlaySource->mapProfile.visibilityMask &
        map_profile_protocol::VISIBILITY_OVERLAY_MASK;
  }
}

bool writeLegacyProjection(const Document &document,
                           MapRenderSettings &settings) {
  projectDocument(document, settings);
  Preferences legacy;
  if (!legacy.begin("mapSettings", false))
    return false;
  const uint8_t settingIDs[] = {1, 2, 3, 7, 8, 9, 10, 16, 17, 18,
                                19, 20, 21, 22, 27, 28, 29, 30, 31, 32,
                                33, 34};
  bool wrote = true;
  for (uint8_t settingID : settingIDs) {
    wrote = map_profile_persistence::persistSetting(
                legacy, settings.mapStyle, settings.mapNavigationStyle,
                settings.navigationOverlayVisibilityMask, settingID, false) &&
            wrote;
  }
  map_profile_persistence::persistBirdsEyeEnabled(
      legacy, settings.mapNavigationBirdsEyeEnabled);
  map_profile_persistence::persistBirdsEyePerspective(
      legacy, settings.mapNavigationBirdsEyePerspective);
  map_profile_persistence::persist3DBuildingsEnabled(
      legacy, settings.mapNavigation3DBuildingsEnabled);
  wrote = legacy.putUChar("mapRotMode", settings.mapRotationMode) == 1 && wrote;
  wrote = legacy.putUChar("screenMask", settings.enabledScreensMask) == 1 &&
          wrote;
  wrote = legacy.putUChar("defaultScreen", settings.defaultScreen) == 1 &&
          wrote;
  wrote = legacy.putBool("batteryScrV1", true) == 1 && wrote;
  legacy.end();
  return wrote;
}

bool verifyLegacyProjection(const Document &document,
                            const MapRenderSettings &current,
                            uint32_t expectedDigest) {
  MapRenderSettings verified = current;
  Preferences legacy;
  if (!legacy.begin("mapSettings", true))
    return false;
  map_profile_persistence::load(legacy, verified.mapStyle,
                                verified.mapNavigationStyle);
  verified.mapNavigationBirdsEyeEnabled =
      map_profile_persistence::loadBirdsEyeEnabled(legacy);
  verified.mapNavigationBirdsEyePerspective =
      map_profile_persistence::loadBirdsEyePerspective(legacy);
  verified.mapNavigation3DBuildingsEnabled =
      map_profile_persistence::load3DBuildingsEnabled(legacy);
  verified.mapRotationMode = legacy.getUChar("mapRotMode", 0);
  verified.enabledScreensMask = legacy.getUChar("screenMask", 0);
  verified.defaultScreen = legacy.getUChar("defaultScreen", 0);
  verified.navigationOverlayVisibilityMask =
      legacy.getUInt("visMask", 0) &
      map_profile_protocol::VISIBILITY_OVERLAY_MASK;
  legacy.end();
  MapRenderSettings expected = current;
  projectDocument(document, expected);
  return legacyDigest(verified) == expectedDigest &&
         legacyDigest(expected) == expectedDigest;
}

bool encodeSlot(char slot, uint32_t revision, uint32_t projectionDigest,
                const uint8_t *document, std::size_t documentLength,
                std::size_t &slotLength, uint32_t &blobCRC) {
  if (document == nullptr || documentLength == 0 ||
      documentLength > screen_configuration_protocol::MAX_DOCUMENT_BYTES)
    return false;
  std::memcpy(slotBuffer.data(), kSlotMagic, sizeof(kSlotMagic));
  screen_configuration_protocol::writeUInt32LE(slotBuffer.data() + 4,
                                                revision);
  screen_configuration_protocol::writeUInt32LE(slotBuffer.data() + 8,
                                                projectionDigest);
  screen_configuration_protocol::writeUInt16LE(
      slotBuffer.data() + 12, static_cast<uint16_t>(documentLength));
  std::memcpy(slotBuffer.data() + kSlotHeaderBytes, document, documentLength);
  slotLength = kSlotHeaderBytes + documentLength + kSlotCRCBytes;
  blobCRC = screen_configuration_protocol::crc32(slotBuffer.data(),
                                                  slotLength - 4);
  screen_configuration_protocol::writeUInt32LE(
      slotBuffer.data() + slotLength - 4, blobCRC);
  (void)slot;
  return true;
}

bool decodeSlot(const char *key, char slot, SlotRecord &record) {
  record = {};
  record.slot = slot;
  const std::size_t length = preferences.getBytesLength(key);
  if (length < kSlotHeaderBytes + kSlotCRCBytes ||
      length > slotBuffer.size() ||
      preferences.getBytes(key, slotBuffer.data(), length) != length ||
      std::memcmp(slotBuffer.data(), kSlotMagic, sizeof(kSlotMagic)) != 0)
    return false;
  const uint16_t documentLength =
      screen_configuration_protocol::readUInt16LE(slotBuffer.data() + 12);
  if (length != kSlotHeaderBytes + documentLength + kSlotCRCBytes)
    return false;
  const uint32_t storedCRC = screen_configuration_protocol::readUInt32LE(
      slotBuffer.data() + length - 4);
  if (screen_configuration_protocol::crc32(slotBuffer.data(), length - 4) !=
      storedCRC)
    return false;
  const auto result = screen_configuration_protocol::decodeDocument(
      slotBuffer.data() + kSlotHeaderBytes, documentLength, record.document);
  if (result != screen_configuration_protocol::DecodeResult::Complete)
    return false;
  record.valid = true;
  record.revision =
      screen_configuration_protocol::readUInt32LE(slotBuffer.data() + 4);
  record.legacyDigest =
      screen_configuration_protocol::readUInt32LE(slotBuffer.data() + 8);
  record.blobCRC = storedCRC;
  record.documentLength = documentLength;
  return record.revision != 0;
}

bool writeHead(char slot, uint32_t revision, uint32_t blobCRC) {
  uint8_t bytes[kHeadBytes]{};
  std::memcpy(bytes, kHeadMagic, sizeof(kHeadMagic));
  bytes[4] = static_cast<uint8_t>(slot);
  screen_configuration_protocol::writeUInt32LE(bytes + 5, revision);
  screen_configuration_protocol::writeUInt32LE(bytes + 9, blobCRC);
  if (preferences.putBytes(kHeadKey, bytes, sizeof(bytes)) != sizeof(bytes))
    return false;
  uint8_t verified[kHeadBytes]{};
  return preferences.getBytes(kHeadKey, verified, sizeof(verified)) ==
             sizeof(verified) &&
         std::memcmp(bytes, verified, sizeof(bytes)) == 0;
}

bool readHead(char &slot, uint32_t &revision, uint32_t &blobCRC) {
  uint8_t bytes[kHeadBytes]{};
  if (preferences.getBytesLength(kHeadKey) != sizeof(bytes) ||
      preferences.getBytes(kHeadKey, bytes, sizeof(bytes)) != sizeof(bytes) ||
      std::memcmp(bytes, kHeadMagic, sizeof(kHeadMagic)) != 0 ||
      (bytes[4] != 'A' && bytes[4] != 'B'))
    return false;
  slot = static_cast<char>(bytes[4]);
  revision = screen_configuration_protocol::readUInt32LE(bytes + 5);
  blobCRC = screen_configuration_protocol::readUInt32LE(bytes + 9);
  return revision != 0;
}

bool writeMirrorTransaction(bool activeTransaction) {
  return preferences.putBool(kMirrorTransactionKey, activeTransaction) == 1 &&
         preferences.getBool(kMirrorTransactionKey, !activeTransaction) ==
             activeTransaction;
}

bool writeMirrorRevision(uint32_t revision) {
  return preferences.putUInt(kMirrorRevisionKey, revision) ==
             sizeof(uint32_t) &&
         preferences.getUInt(kMirrorRevisionKey, 0) == revision;
}

bool writeSlot(char slot, uint32_t revision, uint32_t projectionDigest,
               const uint8_t *document, std::size_t documentLength,
               SlotRecord &verified) {
  std::size_t slotLength = 0;
  uint32_t blobCRC = 0;
  if (!encodeSlot(slot, revision, projectionDigest, document, documentLength,
                  slotLength, blobCRC))
    return false;
  const char *key = slot == 'A' ? kSlotAKey : kSlotBKey;
  if (preferences.putBytes(key, slotBuffer.data(), slotLength) != slotLength ||
      !decodeSlot(key, slot, verified))
    return false;
  return verified.revision == revision && verified.blobCRC == blobCRC &&
         verified.legacyDigest == projectionDigest;
}

void recordReplay(uint32_t requestID, uint32_t candidateCRC,
                  const CommitOutcome &outcome) {
  replayRecords[nextReplayRecord] = {true, requestID, candidateCRC, outcome};
  nextReplayRecord = (nextReplayRecord + 1) % replayRecords.size();
}

const ReplayRecord *findReplay(uint32_t requestID) {
  for (const ReplayRecord &record : replayRecords) {
    if (record.valid && record.requestID == requestID)
      return &record;
  }
  return nullptr;
}

void importLegacy(Document &document, const MapRenderSettings &legacy) {
  const uint8_t mask = legacy.enabledScreensMask & DEVICE_SCREEN_SUPPORTED_MASK;
  bool represented[5]{};
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    ScreenInstance &instance = document.instances[index];
    const uint8_t rawType = static_cast<uint8_t>(instance.type);
    represented[rawType] = true;
    instance.enabled = (mask & (1U << rawType)) != 0;
  }
  for (uint8_t rawType = 0; rawType < 5 &&
                            document.instanceCount <
                                screen_configuration_protocol::MAX_INSTANCES;
       ++rawType) {
    if (represented[rawType] || (mask & (1U << rawType)) == 0)
      continue;
    ScreenInstance &instance = document.instances[document.instanceCount++];
    instance = {};
    instance.id = static_cast<uint32_t>(rawType + 1);
    instance.type = static_cast<ScreenType>(rawType);
    instance.enabled = true;
    const char *name = "Screen";
    switch (instance.type) {
    case ScreenType::Map: name = "Map"; break;
    case ScreenType::Navigation: name = "Navigation"; break;
    case ScreenType::RideStats: name = "Ride Stats"; break;
    case ScreenType::MapNavigation: name = "Map + Navigation"; break;
    case ScreenType::BatteryStatus: name = "Battery Status"; break;
    }
    (void)screen_configuration_protocol::setName(instance, name,
                                                  std::strlen(name));
    instance.mapProfile =
        screen_configuration_protocol::defaultMapProfile(instance.type);
  }

  if (ScreenInstance *map = const_cast<ScreenInstance *>(
          primaryInstance(document, ScreenType::Map))) {
    map->mapProfile = captureProfile(legacy.mapStyle, legacy, ScreenType::Map);
  }
  if (ScreenInstance *navigation = const_cast<ScreenInstance *>(
          primaryInstance(document, ScreenType::MapNavigation))) {
    navigation->mapProfile = captureProfile(
        legacy.mapNavigationStyle, legacy, ScreenType::MapNavigation);
  }
  const ScreenType defaultType = legacy.defaultScreen <= 4
                                     ? static_cast<ScreenType>(legacy.defaultScreen)
                                     : ScreenType::MapNavigation;
  const ScreenInstance *newDefault = primaryInstance(document, defaultType);
  if (newDefault != nullptr && newDefault->enabled)
    document.defaultInstanceID = newDefault->id;
  if (screen_configuration_protocol::validate(document) !=
      screen_configuration_protocol::ValidationError::None) {
    for (uint8_t index = 0; index < document.instanceCount; ++index) {
      if (document.instances[index].enabled) {
        document.defaultInstanceID = document.instances[index].id;
        break;
      }
    }
  }
}

} // namespace

Document makeMigratedDocument(const MapRenderSettings &legacy) {
  Document document{};
  const ScreenType order[] = {ScreenType::MapNavigation, ScreenType::RideStats,
                              ScreenType::Map, ScreenType::Navigation,
                              ScreenType::BatteryStatus};
  const char *names[] = {"Map + Navigation", "Ride Stats", "Map",
                         "Navigation", "Battery Status"};
  document.instanceCount = 5;
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    ScreenInstance &instance = document.instances[index];
    instance.id = static_cast<uint32_t>(static_cast<uint8_t>(order[index]) + 1);
    instance.type = order[index];
    instance.enabled =
        (legacy.enabledScreensMask &
         (1U << static_cast<uint8_t>(instance.type))) != 0;
    instance.mapProfile =
        screen_configuration_protocol::defaultMapProfile(instance.type);
    (void)screen_configuration_protocol::setName(instance, names[index],
                                                  std::strlen(names[index]));
  }
  document.instances[0].mapProfile = captureProfile(
      legacy.mapNavigationStyle, legacy, ScreenType::MapNavigation);
  document.instances[2].mapProfile =
      captureProfile(legacy.mapStyle, legacy, ScreenType::Map);
  const ScreenType requestedDefault =
      legacy.defaultScreen <= 4 ? static_cast<ScreenType>(legacy.defaultScreen)
                                : ScreenType::MapNavigation;
  const ScreenInstance *selected = primaryInstance(document, requestedDefault);
  if (selected == nullptr || !selected->enabled) {
    for (uint8_t index = 0; index < document.instanceCount; ++index) {
      if (document.instances[index].enabled) {
        selected = &document.instances[index];
        break;
      }
    }
  }
  document.defaultInstanceID = selected == nullptr ? 4 : selected->id;
  return document;
}

bool initialize(const MapRenderSettings &legacy) {
  if (ready)
    return true;
  if (!preferences.begin(kNamespace, false))
    return false;

  SlotRecord slotA{};
  SlotRecord slotB{};
  const bool hasA = decodeSlot(kSlotAKey, 'A', slotA);
  const bool hasB = decodeSlot(kSlotBKey, 'B', slotB);
  char headSlot = 0;
  uint32_t headRevision = 0;
  uint32_t headCRC = 0;
  const bool hasHead = readHead(headSlot, headRevision, headCRC);
  const char selectedSlot = selectActiveSlot(
      {hasA, 'A', slotA.revision, slotA.blobCRC},
      {hasB, 'B', slotB.revision, slotB.blobCRC}, hasHead, headSlot,
      headRevision, headCRC);
  const SlotRecord *selected =
      selectedSlot == 'A' ? &slotA : (selectedSlot == 'B' ? &slotB : nullptr);

  if (selected == nullptr) {
    const Document migrated = makeMigratedDocument(legacy);
    const std::size_t length = screen_configuration_protocol::encodeDocument(
        migrated, documentBuffer.data(), documentBuffer.size());
    if (length == 0)
      return false;
    MapRenderSettings projected = legacy;
    projectDocument(migrated, projected);
    const uint32_t projectionDigest = legacyDigest(projected);
    SlotRecord verified{};
    if (!writeSlot('A', 1, projectionDigest, documentBuffer.data(), length,
                   verified) ||
        !writeMirrorTransaction(true) ||
        !writeHead('A', 1, verified.blobCRC) ||
        !writeLegacyProjection(migrated, mapRenderSettings) ||
        !verifyLegacyProjection(migrated, mapRenderSettings,
                                projectionDigest) ||
        !writeMirrorRevision(1) || !writeMirrorTransaction(false)) {
      return false;
    }
    active = {1, migrated};
    activeSlot = 'A';
    activeLegacyDigest = projectionDigest;
    ready = true;
    Serial.printf("BLE screens: migrated legacy settings revision=1 count=%u\n",
                  migrated.instanceCount);
    return true;
  }

  active = {selected->revision, selected->document};
  activeSlot = selected->slot;
  activeLegacyDigest = selected->legacyDigest;
  ready = true;
  if (!writeHead(activeSlot, active.revision, selected->blobCRC)) {
    ready = false;
    return false;
  }
  const uint32_t mirrorRevision =
      preferences.getUInt(kMirrorRevisionKey, 0);
  const bool interruptedMirror =
      preferences.getBool(kMirrorTransactionKey, false);
  const uint32_t currentLegacyDigest = legacyDigest(legacy);
  if (interruptedMirror || mirrorRevision != active.revision) {
    if (!writeLegacyProjection(active.document, mapRenderSettings) ||
        !verifyLegacyProjection(active.document, mapRenderSettings,
                                activeLegacyDigest) ||
        !writeMirrorRevision(active.revision) ||
        !writeMirrorTransaction(false)) {
      projectDocument(active.document, mapRenderSettings);
      ready = false;
      return false;
    }
  } else if (currentLegacyDigest != activeLegacyDigest) {
    Document imported = active.document;
    importLegacy(imported, legacy);
    const uint32_t request = ++internalRequestID;
    const std::size_t length = screen_configuration_protocol::encodeDocument(
        imported, documentBuffer.data(), documentBuffer.size());
    if (length != 0)
      (void)commit(request, active.revision, documentBuffer.data(), length);
  } else {
    projectDocument(active.document, mapRenderSettings);
  }
  Serial.printf("BLE screens: loaded revision=%lu count=%u slot=%c\n",
                static_cast<unsigned long>(active.revision),
                active.document.instanceCount, activeSlot);
  return true;
}

bool isReady() { return ready; }

const Snapshot &activeSnapshot() { return active; }

CommitOutcome commit(uint32_t requestID, uint32_t baseRevision,
                     const uint8_t *document, std::size_t length) {
  CommitOutcome outcome{};
  outcome.revision = active.revision;
  if (!ready || requestID == 0 || document == nullptr || length < 4) {
    outcome.result = CommitResult::Malformed;
    return outcome;
  }
  const uint32_t candidateCRC =
      screen_configuration_protocol::documentCRC(document, length);
  if (const ReplayRecord *replay = findReplay(requestID)) {
    if (replay->candidateCRC == candidateCRC)
      return replay->outcome;
    outcome.result = CommitResult::Malformed;
    return outcome;
  }
  if (baseRevision != active.revision) {
    outcome.result = CommitResult::Conflict;
    recordReplay(requestID, candidateCRC, outcome);
    return outcome;
  }
  Document candidate{};
  const auto decoded = screen_configuration_protocol::decodeDocument(
      document, length, candidate);
  if (decoded != screen_configuration_protocol::DecodeResult::Complete) {
    outcome.result = decoded == screen_configuration_protocol::DecodeResult::Unsupported
                         ? CommitResult::Unsupported
                         : CommitResult::Malformed;
    recordReplay(requestID, candidateCRC, outcome);
    return outcome;
  }

  const uint32_t candidateRevision = nextRevision(active.revision);
  MapRenderSettings projected = mapRenderSettings;
  projectDocument(candidate, projected);
  const uint32_t projectionDigest = legacyDigest(projected);
  const char nextSlot = inactiveSlot(activeSlot);
  SlotRecord verified{};
  CommitPersistenceProgress persistence{};
  persistence.inactiveSlotWriteAndReadback = writeSlot(
      nextSlot, candidateRevision, projectionDigest, document, length,
      verified);
  char previousHeadSlot = activeSlot;
  uint32_t previousHeadRevision = active.revision;
  SlotRecord previousSlot{};
  (void)decodeSlot(activeSlot == 'A' ? kSlotAKey : kSlotBKey, activeSlot,
                   previousSlot);
  if (persistence.inactiveSlotWriteAndReadback)
    persistence.transactionMarkerWriteAndReadback =
        writeMirrorTransaction(true);
  if (persistence.transactionMarkerWriteAndReadback)
    persistence.headWriteAndReadback =
        writeHead(nextSlot, candidateRevision, verified.blobCRC);
  if (persistence.headWriteAndReadback)
    persistence.legacyMirrorWrite =
        writeLegacyProjection(candidate, mapRenderSettings);
  if (persistence.legacyMirrorWrite)
    persistence.legacyMirrorReadback = verifyLegacyProjection(
        candidate, mapRenderSettings, projectionDigest);
  if (persistence.legacyMirrorReadback)
    persistence.mirrorRevisionWriteAndReadback =
        writeMirrorRevision(candidateRevision);
  if (persistence.mirrorRevisionWriteAndReadback)
    persistence.transactionClearWriteAndReadback =
        writeMirrorTransaction(false);
  if (!persistence.complete()) {
    if (previousSlot.valid)
      (void)writeHead(previousHeadSlot, previousHeadRevision,
                      previousSlot.blobCRC);
    projectDocument(active.document, mapRenderSettings);
    if (writeLegacyProjection(active.document, mapRenderSettings) &&
        verifyLegacyProjection(active.document, mapRenderSettings,
                               activeLegacyDigest)) {
      (void)writeMirrorRevision(active.revision);
      (void)writeMirrorTransaction(false);
    }
    outcome.result = CommitResult::PersistenceFailed;
    recordReplay(requestID, candidateCRC, outcome);
    return outcome;
  }

  active = {candidateRevision, candidate};
  activeSlot = nextSlot;
  activeLegacyDigest = projectionDigest;
  outcome.result = CommitResult::Applied;
  outcome.revision = candidateRevision;
  outcome.documentCRC = candidateCRC;
  outcome.published = true;
  recordReplay(requestID, candidateCRC, outcome);
  Serial.printf("BLE screens: commit request=%lu revision=%lu bytes=%u count=%u\n",
                static_cast<unsigned long>(requestID),
                static_cast<unsigned long>(candidateRevision),
                static_cast<unsigned>(length), candidate.instanceCount);
  return outcome;
}

void applySnapshotToLegacyRuntime(MapRenderSettings &settings) {
  if (ready)
    projectDocument(active.document, settings);
}

void noteLegacySettingsChanged(uint32_t nowMs) {
  if (!ready)
    return;
  legacyChangedAtMs = nowMs;
  legacyChangePending = true;
}

bool processLegacySettings(MapRenderSettings &settings, uint32_t nowMs) {
  if (!ready || !legacyChangePending ||
      static_cast<uint32_t>(nowMs - legacyChangedAtMs) < kLegacyDebounceMs)
    return false;
  legacyChangePending = false;
  Document imported = active.document;
  importLegacy(imported, settings);
  const std::size_t length = screen_configuration_protocol::encodeDocument(
      imported, documentBuffer.data(), documentBuffer.size());
  if (length == 0)
    return false;
  ++internalRequestID;
  if (internalRequestID == 0)
    internalRequestID = 0x40000001UL;
  return commit(internalRequestID, active.revision, documentBuffer.data(),
                length)
      .published;
}

void resetTransferState() { legacyChangePending = false; }

} // namespace screen_configuration
