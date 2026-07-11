#include "../../lib/ble_navigation/map_profile_persistence.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <unordered_map>

struct TestProfile {
  uint8_t minPolygonSize = 0;
  uint8_t detailLevel = 0;
  uint8_t routeLineWidth = 0;
  uint8_t streetLineWidthBoost = 0;
  uint8_t positionMarkerScale = 0;
  uint8_t zoomLevel = 0;
  uint32_t visibilityMask = 0;
};

class FakeStore {
public:
  uint8_t getUChar(const char *key, uint8_t fallback) const {
    const auto value = values.find(key);
    return value == values.end() ? fallback
                                 : static_cast<uint8_t>(value->second);
  }
  uint32_t getUInt(const char *key, uint32_t fallback) const {
    const auto value = values.find(key);
    return value == values.end() ? fallback : value->second;
  }
  void putUChar(const char *key, uint8_t value) { values[key] = value; }
  void putUInt(const char *key, uint32_t value) { values[key] = value; }

private:
  std::unordered_map<std::string, uint32_t> values;
};

static TestProfile profile(uint8_t base, uint32_t visibilityMask) {
  return TestProfile{base, static_cast<uint8_t>(base + 1),
                     static_cast<uint8_t>(base + 2),
                     static_cast<uint8_t>(base + 3),
                     static_cast<uint8_t>(base + 4),
                     static_cast<uint8_t>(base + 5), visibilityMask};
}

static void persistProfile(FakeStore &store, const TestProfile &map,
                           const TestProfile &navigation, bool mirror) {
  for (uint8_t settingId : {1, 2, 3, 7, 8, 9, 10}) {
    assert(map_profile_persistence::persistSetting(
        store, map, navigation,
        map_profile_protocol::VISIBILITY_OVERLAY_MASK, settingId, mirror));
  }
}

int main() {
  using namespace map_profile_protocol;

  FakeStore legacyStore;
  const TestProfile legacyMap = profile(1, VISIBILITY_LEGACY_FEATURE_MASK);
  legacyStore.putUChar("minPolySize", legacyMap.minPolygonSize);
  legacyStore.putUChar("detailLevel", legacyMap.detailLevel);
  legacyStore.putUChar("routeWidth", legacyMap.routeLineWidth);
  legacyStore.putUChar("streetBoost", legacyMap.streetLineWidthBoost);
  legacyStore.putUChar("markerScale", legacyMap.positionMarkerScale);
  legacyStore.putUChar("zoomLevel", legacyMap.zoomLevel);
  legacyStore.putUInt("visMask", legacyMap.visibilityMask);
  TestProfile loadedMap;
  TestProfile loadedNavigation;
  map_profile_persistence::load(legacyStore, loadedMap, loadedNavigation);
  assert(loadedMap.visibilityMask == VISIBILITY_EXTENDED_FEATURE_MASK);
  assert(loadedNavigation.visibilityMask == VISIBILITY_EXTENDED_FEATURE_MASK);
  assert(loadedNavigation.zoomLevel == legacyMap.zoomLevel);

  FakeStore mirroredStore;
  const TestProfile mirrored = profile(2, VISIBILITY_EXTENDED_FEATURE_MASK);
  persistProfile(mirroredStore, mirrored, mirrored, true);
  map_profile_persistence::load(mirroredStore, loadedMap, loadedNavigation);
  assert(loadedMap.minPolygonSize == mirrored.minPolygonSize);
  assert(loadedNavigation.minPolygonSize == mirrored.minPolygonSize);
  assert(loadedNavigation.positionMarkerScale == mirrored.positionMarkerScale);
  assert(mirroredStore.getUInt("visMask", 0) ==
         (mirrored.visibilityMask | VISIBILITY_OVERLAY_MASK |
          VISIBILITY_EXTENDED_MARKER));

  FakeStore independentStore;
  const TestProfile map = profile(1, VISIBILITY_LOCAL_STREETS);
  const TestProfile originalNavigation = map;
  persistProfile(independentStore, map, originalNavigation, false);
  const TestProfile navigation =
      profile(7, VISIBILITY_SERVICE_ROADS | VISIBILITY_TRACKS);
  for (uint8_t settingId : {16, 17, 18, 19, 20, 21, 22}) {
    assert(map_profile_persistence::persistSetting(
        independentStore, map, navigation, VISIBILITY_POSITION_MARKER,
        settingId, false));
  }
  map_profile_persistence::load(independentStore, loadedMap,
                                loadedNavigation);
  assert(loadedMap.minPolygonSize == map.minPolygonSize);
  assert(loadedMap.visibilityMask == map.visibilityMask);
  assert(loadedNavigation.minPolygonSize == navigation.minPolygonSize);
  assert(loadedNavigation.visibilityMask == navigation.visibilityMask);
  assert(independentStore.getUInt("visMask", 0) ==
         (map.visibilityMask | VISIBILITY_OVERLAY_MASK |
          VISIBILITY_EXTENDED_MARKER));

  std::cout << "Map profile persistence tests passed\n";
  return 0;
}
