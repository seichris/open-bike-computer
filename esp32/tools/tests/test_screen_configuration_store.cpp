// Exercise the real persistence/legacy adapter with an in-memory NVS store.
#include "../../lib/ble_navigation/screen_configuration.cpp"
#include <cassert>

MapRenderSettings mapRenderSettings;

int main(int argc, char **argv) {
  using namespace screen_configuration;
  using namespace screen_configuration_protocol;
  assert(initialize(mapRenderSettings));
  Document document = activeSnapshot().document;
  document.instances[0].mapProfile.visibilityMask &= ~(1UL << 8);
  document.instances[0].mapProfile.visibilityMask |=
      map_profile_protocol::VISIBILITY_CONTOURS;
  document.instances[2].mapProfile.visibilityMask |=
      map_profile_protocol::VISIBILITY_CONTOURS;
  auto duplicate = document.instances[2];
  duplicate.id = 0x80000001;
  duplicate.mapProfile.zoomLevel = 5;
  document.instances[document.instanceCount++] = duplicate;
  document.defaultInstanceID = duplicate.id;
  auto disabled = duplicate;
  disabled.id += 1;
  disabled.enabled = false;
  document.instances[document.instanceCount++] = disabled;
  std::array<uint8_t, MAX_DOCUMENT_BYTES> bytes{};
  auto length = encodeDocument(document, bytes.data(), bytes.size());
  assert(commit(1, activeSnapshot().revision, bytes.data(), length).published);
  MapRenderSettings projected = mapRenderSettings;
  projectDocument(activeSnapshot().document, projected);
  assert((projected.mapStyle.visibilityMask &
          map_profile_protocol::VISIBILITY_CONTOURS) != 0);
  assert((projected.mapNavigationStyle.visibilityMask &
          map_profile_protocol::VISIBILITY_CONTOURS) != 0);

  if (argc > 1 && std::strcmp(argv[1], "downgrade") == 0) {
    const auto revision = activeSnapshot().revision;
    // Patch the persisted Map payload, maintaining both document and slot CRCs.
    for (auto &item : preferences_test::stores[kNamespace]) {
      if (item.first != "slotA" && item.first != "slotB") continue;
      auto &slot = item.second;
      const auto length = readUInt16LE(slot.data() + 12);
      auto *documentBytes = slot.data() + kSlotHeaderBytes;
      size_t offset = DOCUMENT_HEADER_BYTES;
      for (uint8_t i = 0; i < documentBytes[5]; ++i) {
        const auto type = static_cast<ScreenType>(documentBytes[offset + 4]);
        const auto payload = readUInt16LE(documentBytes + offset + 7);
        const auto start = offset + 9 + documentBytes[offset + 6];
        if (type == ScreenType::Map) {
          auto *mask = documentBytes + start + 7;
          writeUInt32LE(mask, readUInt32LE(mask) | (1u << 17));
        }
        offset = start + payload;
      }
      writeUInt32LE(documentBytes + length - 4, crc32(documentBytes, length - 4));
      writeUInt32LE(slot.data() + slot.size() - 4, crc32(slot.data(), slot.size() - 4));
    }
    ready = false;
    assert(initialize(mapRenderSettings));
    assert(activeSnapshot().revision == revision);
    assert(activeSnapshot().document.instanceCount == document.instanceCount);
    assert(activeSnapshot().document.defaultInstanceID == duplicate.id);
    assert(activeSnapshot().document.instances[5].mapProfile.zoomLevel == 5);
    assert(!activeSnapshot().document.instances[6].enabled);
    assert((activeSnapshot().document.instances[5].mapProfile.visibilityMask & (1u << 17)) == 0);
    ready = false;
    assert(initialize(mapRenderSettings)); // migration is durable, not repeated
    assert(activeSnapshot().revision == revision);
    return 0;
  }

  // This is the render-time projection installed while viewing duplicate Map.
  mapRenderSettings.mapStyle.zoomLevel = 5;
  if (argc > 1 && std::strcmp(argv[1], "legacy") == 0) {
    // A legacy app changes only rotation; stored primary zoom remains 3.
    Preferences legacy;
    assert(legacy.begin("mapSettings", false));
    assert(legacy.putUChar("mapRotMode", 1) == 1);
    legacy.end();
    mapRenderSettings.mapRotationMode = 1;
    noteLegacySettingsChanged(100, 6);
    resetTransferState(); // Reconnect cannot cancel already persisted changes.
    assert(processLegacySettings(mapRenderSettings, 400));
    assert(activeSnapshot().document.instances[2].mapProfile.zoomLevel == 3);
    assert(activeSnapshot().document.instances[2].mapProfile.rotationMode == 1);
    assert(activeSnapshot().document.instances[5].mapProfile.zoomLevel == 5);
    assert(!activeSnapshot().document.instances[6].enabled);
    assert(activeSnapshot().document.defaultInstanceID == duplicate.id);
    assert((activeSnapshot().document.instances[0].mapProfile.visibilityMask &
            (1UL << 8)) == 0);
    noteLegacySettingsChanged(500, 13);
    assert(processLegacySettings(mapRenderSettings, 800));
    assert(activeSnapshot().document.instances[6].enabled);
    assert(activeSnapshot().document.defaultInstanceID == duplicate.id);
  } else {
    // A rename must not replace the visible duplicate's render-time settings.
    assert(setName(document.instances[0], "Renamed", 7));
    length = encodeDocument(document, bytes.data(), bytes.size());
    assert(commit(2, activeSnapshot().revision, bytes.data(), length).published);
    assert(mapRenderSettings.mapStyle.zoomLevel == 5);
    Preferences legacy;
    assert(legacy.begin("mapSettings", true));
    assert(legacy.getUChar("zoomLevel", 0) == 3);
    legacy.end();
    // A failed save must likewise preserve the currently rendered profile.
    preferences_test::failPutKey = "slotB";
    assert(commit(3, activeSnapshot().revision, bytes.data(), length).result ==
           CommitResult::PersistenceFailed);
    assert(mapRenderSettings.mapStyle.zoomLevel == 5);
  }
}
