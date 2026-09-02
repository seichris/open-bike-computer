#pragma once

#include "screen_configuration_protocol.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

struct MapRenderSettings;

namespace screen_configuration {

using screen_configuration_protocol::Document;
using screen_configuration_protocol::MapProfile;
using screen_configuration_protocol::ScreenInstance;
using screen_configuration_protocol::ScreenType;

struct Snapshot {
  uint32_t revision = 0;
  Document document{};
};

enum class CommitResult : uint8_t {
  Applied = 0,
  Conflict = 1,
  Malformed = 2,
  Unsupported = 3,
  PersistenceFailed = 4,
  Busy = 5,
  Unauthorized = 6,
};

struct CommitOutcome {
  CommitResult result = CommitResult::Malformed;
  uint32_t revision = 0;
  uint32_t documentCRC = 0;
  bool published = false;
};

struct CommitPersistenceProgress {
  bool inactiveSlotWriteAndReadback = false;
  bool transactionMarkerWriteAndReadback = false;
  bool headWriteAndReadback = false;
  bool legacyMirrorWrite = false;
  bool legacyMirrorReadback = false;
  bool mirrorRevisionWriteAndReadback = false;
  bool transactionClearWriteAndReadback = false;

  constexpr bool complete() const {
    return inactiveSlotWriteAndReadback &&
           transactionMarkerWriteAndReadback && headWriteAndReadback &&
           legacyMirrorWrite && legacyMirrorReadback &&
           mirrorRevisionWriteAndReadback &&
           transactionClearWriteAndReadback;
  }
};

constexpr uint8_t kInvalidInstanceIndex = 0xff;

struct SlotCandidate {
  bool valid = false;
  char slot = 0;
  uint32_t revision = 0;
  uint32_t blobCRC = 0;
};

inline char selectActiveSlot(const SlotCandidate &first,
                             const SlotCandidate &second, bool headValid,
                             char headSlot, uint32_t headRevision,
                             uint32_t headCRC) {
  if (headValid) {
    if (first.valid && first.slot == headSlot &&
        first.revision == headRevision && first.blobCRC == headCRC)
      return first.slot;
    if (second.valid && second.slot == headSlot &&
        second.revision == headRevision && second.blobCRC == headCRC)
      return second.slot;
  }
  if (!first.valid)
    return second.valid ? second.slot : 0;
  if (!second.valid)
    return first.slot;
  return second.revision > first.revision ? second.slot : first.slot;
}

inline char inactiveSlot(char current) { return current == 'A' ? 'B' : 'A'; }

inline uint32_t nextRevision(uint32_t current) {
  const uint32_t candidate = current + 1;
  return candidate == 0 ? 1 : candidate;
}

inline uint8_t findInstanceIndex(const Document &document, uint32_t id) {
  for (uint8_t index = 0; index < document.instanceCount; ++index) {
    if (document.instances[index].id == id)
      return index;
  }
  return kInvalidInstanceIndex;
}

inline uint8_t defaultInstanceIndex(const Document &document) {
  return findInstanceIndex(document, document.defaultInstanceID);
}

inline uint8_t nextEnabledInstanceIndex(const Document &document,
                                        uint8_t currentIndex) {
  if (document.instanceCount == 0)
    return kInvalidInstanceIndex;
  const uint8_t start = currentIndex < document.instanceCount ? currentIndex : 0;
  for (uint8_t offset = 1; offset <= document.instanceCount; ++offset) {
    const uint8_t candidate =
        static_cast<uint8_t>((start + offset) % document.instanceCount);
    if (document.instances[candidate].enabled)
      return candidate;
  }
  return defaultInstanceIndex(document);
}

inline uint8_t nextEnabledInstanceOfType(const Document &document,
                                         uint8_t currentIndex,
                                         ScreenType first,
                                         ScreenType second) {
  if (document.instanceCount == 0)
    return kInvalidInstanceIndex;
  const uint8_t start = currentIndex < document.instanceCount ? currentIndex : 0;
  for (uint8_t offset = 1; offset <= document.instanceCount; ++offset) {
    const uint8_t candidate =
        static_cast<uint8_t>((start + offset) % document.instanceCount);
    const ScreenInstance &instance = document.instances[candidate];
    if (instance.enabled && (instance.type == first || instance.type == second))
      return candidate;
  }
  return kInvalidInstanceIndex;
}

inline uint32_t mapProfileSignature(const ScreenInstance &instance) {
  uint8_t bytes[24]{};
  std::size_t size = 0;
  auto append = [&](uint8_t value) { bytes[size++] = value; };
  append(static_cast<uint8_t>(instance.type));
  const MapProfile &profile = instance.mapProfile;
  append(profile.minPolygonSize);
  append(profile.detailLevel);
  append(profile.routeLineWidth);
  append(profile.streetLineWidth);
  append(profile.positionMarkerScale);
  append(profile.zoomLevel);
  screen_configuration_protocol::writeUInt32LE(bytes + size,
                                                profile.visibilityMask);
  size += 4;
  append(profile.labelDensity);
  append(profile.labelLanguageMode);
  append(profile.labelTextSize);
  append(profile.labelOrientation);
  append(profile.rotationMode);
  append(profile.birdsEyeEnabled ? 1 : 0);
  append(profile.birdsEyePerspective);
  append(profile.buildings3DEnabled ? 1 : 0);
  return screen_configuration_protocol::crc32(bytes, size);
}

inline uint32_t screenPayloadSignature(const ScreenInstance &instance) {
  if (instance.type == ScreenType::Map ||
      instance.type == ScreenType::MapNavigation) {
    return mapProfileSignature(instance);
  }
  uint8_t bytes[1 + screen_configuration_protocol::RIDE_STATS_SLOT_COUNT]{};
  bytes[0] = static_cast<uint8_t>(instance.type);
  std::size_t size = 1;
  if (instance.type == ScreenType::RideStats) {
    for (const auto widget : instance.rideStatsLayout.slots)
      bytes[size++] = static_cast<uint8_t>(widget);
  }
  return screen_configuration_protocol::crc32(bytes, size);
}

Document makeMigratedDocument(const ::MapRenderSettings &legacy);

bool initialize(const ::MapRenderSettings &legacy);
bool isReady();
const Snapshot &activeSnapshot();
CommitOutcome commit(uint32_t requestID, uint32_t baseRevision,
                     const uint8_t *document, std::size_t length);
void applySnapshotToLegacyRuntime(::MapRenderSettings &settings);
void noteLegacySettingsChanged(uint32_t nowMs);
bool processLegacySettings(::MapRenderSettings &settings, uint32_t nowMs);
void resetTransferState();

} // namespace screen_configuration
