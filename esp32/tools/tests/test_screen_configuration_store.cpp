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
