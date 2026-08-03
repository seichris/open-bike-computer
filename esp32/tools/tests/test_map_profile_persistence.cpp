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
  uint8_t streetLineWidth = 0;
  uint8_t positionMarkerScale = 0;
  uint8_t zoomLevel = 0;
  uint32_t visibilityMask = 0;
  uint8_t labelDensity = 0;
  uint8_t labelLanguageMode = 0;
  uint8_t labelTextSize = 0;
  uint8_t labelOrientation = 0;
};

class FakeStore {
public:
  bool isKey(const char *key) const { return values.find(key) != values.end(); }
  uint8_t getUChar(const char *key, uint8_t fallback) const {
    const auto value = values.find(key);
    return value == values.end() ? fallback
                                 : static_cast<uint8_t>(value->second);
  }
  uint32_t getUInt(const char *key, uint32_t fallback) const {
    const auto value = values.find(key);
    return value == values.end() ? fallback : value->second;
  }
  bool getBool(const char *key, bool fallback) const {
    const auto value = values.find(key);
    return value == values.end() ? fallback : value->second != 0;
  }
  void putUChar(const char *key, uint8_t value) { values[key] = value; }
  void putUInt(const char *key, uint32_t value) { values[key] = value; }
  void putBool(const char *key, bool value) { values[key] = value ? 1 : 0; }

private:
  std::unordered_map<std::string, uint32_t> values;
};

static TestProfile profile(uint8_t base, uint32_t visibilityMask) {
  TestProfile value;
  value.minPolygonSize = base;
  value.detailLevel = static_cast<uint8_t>(base + 1);
  value.routeLineWidth = static_cast<uint8_t>(base + 2);
  value.streetLineWidth = static_cast<uint8_t>(base + 3);
  value.positionMarkerScale = static_cast<uint8_t>(base + 4);
  value.zoomLevel = static_cast<uint8_t>(base + 5);
  value.visibilityMask = visibilityMask;
  value.labelDensity = base % 4;
  value.labelLanguageMode = base % 3;
  value.labelTextSize = base % 3;
  value.labelOrientation = base % 2;
  return value;
}

static void persistProfile(FakeStore &store, const TestProfile &map,
                           const TestProfile &navigation, bool mirror) {
  for (uint8_t settingId : {1, 2, 3, 7, 8, 9, 10}) {
    assert(map_profile_persistence::persistSetting(
        store, map, navigation,
        map_profile_protocol::VISIBILITY_OVERLAY_MASK, settingId, mirror));
  }
  for (uint8_t settingId :
       {map_profile_protocol::MAP_LABEL_DENSITY_SETTING_ID,
        map_profile_protocol::MAP_LABEL_LANGUAGE_MODE_SETTING_ID,
        map_profile_protocol::MAP_LABEL_TEXT_SIZE_SETTING_ID,
        map_profile_protocol::MAP_LABEL_ORIENTATION_SETTING_ID}) {
    assert(map_profile_persistence::persistSetting(
        store, map, navigation,
        map_profile_protocol::VISIBILITY_OVERLAY_MASK, settingId, mirror));
  }
}

int main() {
  using namespace map_profile_protocol;

  FakeStore freshStore;
  TestProfile loadedMap;
  TestProfile loadedNavigation;
  map_profile_persistence::load(freshStore, loadedMap, loadedNavigation);
  assert(map_profile_persistence::loadBirdsEyeEnabled(freshStore));
  assert(map_profile_persistence::loadBirdsEyePerspective(freshStore) ==
         MAP_NAVIGATION_DEFAULT_BIRDS_EYE_PERSPECTIVE);
  assert(loadedMap.detailLevel == MAP_DEFAULT_DETAIL_LEVEL);
  assert(loadedMap.routeLineWidth == MAP_DEFAULT_ROUTE_LINE_WIDTH);
  assert(loadedMap.streetLineWidth == DEFAULT_STREET_WIDTH);
  assert(loadedMap.positionMarkerScale == 2);
  assert(loadedMap.zoomLevel == MAP_DEFAULT_ZOOM_LEVEL);
  assert(loadedNavigation.detailLevel ==
         MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL);
  assert(loadedNavigation.routeLineWidth ==
         MAP_NAVIGATION_DEFAULT_ROUTE_LINE_WIDTH);
  assert(loadedNavigation.streetLineWidth == DEFAULT_STREET_WIDTH);
  assert(loadedNavigation.positionMarkerScale == 2);
  assert(loadedNavigation.zoomLevel == MAP_NAVIGATION_DEFAULT_ZOOM_LEVEL);
  assert(loadedNavigation.visibilityMask ==
         MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK);
  assert(loadedMap.labelDensity == DEFAULT_LABEL_DENSITY);
  assert(loadedMap.labelLanguageMode == DEFAULT_LABEL_LANGUAGE_MODE);
  assert(loadedMap.labelTextSize == DEFAULT_LABEL_TEXT_SIZE);
  assert(loadedMap.labelOrientation == DEFAULT_LABEL_ORIENTATION);
  assert(loadedNavigation.labelDensity ==
         MAP_NAVIGATION_DEFAULT_LABEL_DENSITY);
  assert(loadedNavigation.labelLanguageMode == DEFAULT_LABEL_LANGUAGE_MODE);
  assert(loadedNavigation.labelTextSize == DEFAULT_LABEL_TEXT_SIZE);
  assert(loadedNavigation.labelOrientation == DEFAULT_LABEL_ORIENTATION);

  FakeStore legacyStore;
  const TestProfile legacyMap = profile(1, VISIBILITY_LEGACY_FEATURE_MASK);
  legacyStore.putUChar("minPolySize", legacyMap.minPolygonSize);
  legacyStore.putUChar("detailLevel", legacyMap.detailLevel);
  legacyStore.putUChar("routeWidth", legacyMap.routeLineWidth);
  legacyStore.putUChar("streetBoost", 4);
  legacyStore.putUChar("markerScale", legacyMap.positionMarkerScale);
  legacyStore.putUChar("zoomLevel", legacyMap.zoomLevel);
  legacyStore.putUInt("visMask", legacyMap.visibilityMask);
  map_profile_persistence::load(legacyStore, loadedMap, loadedNavigation);
  assert(loadedMap.visibilityMask == VISIBILITY_EXTENDED_FEATURE_MASK);
  assert(loadedMap.streetLineWidth == 8);
  assert(legacyStore.getUChar("streetWidth", 0) == 8);
  assert(loadedNavigation.visibilityMask == VISIBILITY_EXTENDED_FEATURE_MASK);
  assert(loadedNavigation.streetLineWidth == 8);
  assert(loadedNavigation.zoomLevel == legacyMap.zoomLevel);
  assert(loadedNavigation.labelDensity ==
         MAP_NAVIGATION_DEFAULT_LABEL_DENSITY);

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
  for (uint8_t settingId :
       {MAP_NAVIGATION_LABEL_DENSITY_SETTING_ID,
        MAP_NAVIGATION_LABEL_LANGUAGE_MODE_SETTING_ID,
        MAP_NAVIGATION_LABEL_TEXT_SIZE_SETTING_ID,
        MAP_NAVIGATION_LABEL_ORIENTATION_SETTING_ID}) {
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
  assert(loadedMap.labelDensity == map.labelDensity);
  assert(loadedNavigation.labelDensity == navigation.labelDensity);
  assert(loadedNavigation.labelLanguageMode == navigation.labelLanguageMode);
  assert(loadedNavigation.labelTextSize == navigation.labelTextSize);
  assert(loadedNavigation.labelOrientation == navigation.labelOrientation);
  assert(independentStore.getUInt("visMask", 0) ==
         (map.visibilityMask | VISIBILITY_OVERLAY_MASK |
          VISIBILITY_EXTENDED_MARKER));

  map_profile_persistence::persistBirdsEyeEnabled(independentStore, false);
  assert(!map_profile_persistence::loadBirdsEyeEnabled(independentStore));
  map_profile_persistence::persistBirdsEyeEnabled(independentStore, true);
  assert(map_profile_persistence::loadBirdsEyeEnabled(independentStore));
  map_profile_persistence::persistBirdsEyePerspective(independentStore, 0);
  assert(map_profile_persistence::loadBirdsEyePerspective(independentStore) ==
         0);
  map_profile_persistence::persistBirdsEyePerspective(independentStore, 2);
  assert(map_profile_persistence::loadBirdsEyePerspective(independentStore) ==
         2);
  map_profile_persistence::persistBirdsEyePerspective(independentStore, 3);
  assert(map_profile_persistence::loadBirdsEyePerspective(independentStore) ==
         3);
  map_profile_persistence::persistBirdsEyePerspective(independentStore, 4);
  assert(map_profile_persistence::loadBirdsEyePerspective(independentStore) ==
         4);
  map_profile_persistence::persistBirdsEyePerspective(independentStore, 5);
  assert(map_profile_persistence::loadBirdsEyePerspective(independentStore) ==
         4);

  std::cout << "Map profile persistence tests passed\n";
  return 0;
}
