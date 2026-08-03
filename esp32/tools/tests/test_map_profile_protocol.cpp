#include "../../lib/ble_navigation/map_profile_protocol.hpp"

#include <cassert>

struct TestProfile {
  int sentinel;
};

int main() {
  using namespace map_profile_protocol;

  assert(CAPABILITY_MASK == (1 << 3));
  assert(EXTENDED_VISIBILITY_CAPABILITY_MASK == (1 << 4));
  assert(!clientSupportsIndependentProfiles(0));
  assert(!clientSupportsIndependentProfiles(1));
  assert(clientSupportsIndependentProfiles(2));
  assert(clientSupportsIndependentProfiles(3));
  assert(!clientSupportsExtendedVisibility(2));
  assert(clientSupportsExtendedVisibility(3));
  assert(BIRDS_EYE_EXTENDED_CAPABILITY_MASK == (1 << 0));
  assert(BIRDS_EYE_CLIENT_VERSION == 7);
  assert(BIRDS_EYE_PERSPECTIVE_EXTENDED_CAPABILITY_MASK == (1 << 1));
  assert(BIRDS_EYE_PERSPECTIVE_CLIENT_VERSION == 8);
  assert(BIRDS_EYE_STRONGER_PERSPECTIVE_EXTENDED_CAPABILITY_MASK == (1 << 2));
  assert(BIRDS_EYE_STRONGER_PERSPECTIVE_CLIENT_VERSION == 9);
  assert(MAP_NAVIGATION_BIRDS_EYE_SETTING_ID == 25);
  assert(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID == 26);
  assert(MAP_NAVIGATION_DEFAULT_BIRDS_EYE_PERSPECTIVE == 1);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID, -1) ==
         0);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID, 4) ==
         4);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID, 5) ==
         4);
  assert(!clientSupportsBirdsEyeProjection(6));
  assert(clientSupportsBirdsEyeProjection(7));
  assert(!clientSupportsBirdsEyePerspective(7));
  assert(clientSupportsBirdsEyePerspective(8));
  assert(!clientSupportsStrongerBirdsEyePerspective(8));
  assert(clientSupportsStrongerBirdsEyePerspective(9));
  assert(extendedCapabilityFlagsForClient(6) == 0);
  assert(extendedCapabilityFlagsForClient(7) ==
         BIRDS_EYE_EXTENDED_CAPABILITY_MASK);
  assert(extendedCapabilityFlagsForClient(8) ==
         (BIRDS_EYE_EXTENDED_CAPABILITY_MASK |
          BIRDS_EYE_PERSPECTIVE_EXTENDED_CAPABILITY_MASK));
  assert(extendedCapabilityFlagsForClient(9) ==
         (BIRDS_EYE_EXTENDED_CAPABILITY_MASK |
          BIRDS_EYE_PERSPECTIVE_EXTENDED_CAPABILITY_MASK |
          BIRDS_EYE_STRONGER_PERSPECTIVE_EXTENDED_CAPABILITY_MASK));
  assert(DEFAULT_STREET_WIDTH == 4);
  assert(MAP_DEFAULT_DETAIL_LEVEL == 2);
  assert(MAP_DEFAULT_ROUTE_LINE_WIDTH == 4);
  assert(MAP_DEFAULT_ZOOM_LEVEL == 3);
  assert(MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL == 0);
  assert(MAP_NAVIGATION_DEFAULT_ROUTE_LINE_WIDTH == 15);
  assert(MAP_NAVIGATION_DEFAULT_ZOOM_LEVEL == 3);
  assert(DEFAULT_LABEL_DENSITY == 2);
  assert(MAP_NAVIGATION_DEFAULT_LABEL_DENSITY == 0);
  assert(DEFAULT_LABEL_LANGUAGE_MODE == 2);
  assert(DEFAULT_LABEL_TEXT_SIZE == 0);
  assert(DEFAULT_LABEL_ORIENTATION == 1);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_MAJOR_ROADS) !=
         0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_LOCAL_STREETS) !=
         0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_BUILDINGS) == 0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_GREEN_SPACE) ==
         0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_SERVICE_ROADS) ==
         0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_PATHS) == 0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_TRACKS) == 0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_RAILWAYS) == 0);
  assert((MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK & VISIBILITY_OTHER_AREAS) ==
         0);

  const uint32_t allLegacyFeatures = VISIBILITY_LEGACY_FEATURE_MASK;
  assert(normalizedFeatureVisibilityMask(allLegacyFeatures) ==
         VISIBILITY_EXTENDED_FEATURE_MASK);
  assert(normalizedFeatureVisibilityMask(VISIBILITY_LOCAL_STREETS) ==
         (VISIBILITY_LOCAL_STREETS | VISIBILITY_SERVICE_ROADS));
  assert(normalizedFeatureVisibilityMask(VISIBILITY_PATHS) ==
         (VISIBILITY_PATHS | VISIBILITY_TRACKS));
  const uint32_t extendedServiceOnly =
      VISIBILITY_EXTENDED_MARKER | VISIBILITY_SERVICE_ROADS;
  assert(normalizedFeatureVisibilityMask(extendedServiceOnly) ==
         VISIBILITY_SERVICE_ROADS);
  const uint32_t extendedTrackOnly =
      VISIBILITY_EXTENDED_MARKER | VISIBILITY_TRACKS;
  assert(normalizedFeatureVisibilityMask(extendedTrackOnly) ==
         VISIBILITY_TRACKS);
  assert(visibilityMaskForMapVersion(VISIBILITY_SERVICE_ROADS, 1) ==
         (VISIBILITY_LOCAL_STREETS | VISIBILITY_SERVICE_ROADS));
  assert(visibilityMaskForMapVersion(VISIBILITY_TRACKS, 1) ==
         (VISIBILITY_PATHS | VISIBILITY_TRACKS));
  assert(visibilityMaskForMapVersion(VISIBILITY_SERVICE_ROADS, 2) ==
         VISIBILITY_SERVICE_ROADS);
  assert(isLocalStreetTypeId(6));
  assert(isLocalStreetTypeId(7));
  assert(!isLocalStreetTypeId(10));
  assert(isServiceRoadTypeId(10));
  assert(!isServiceRoadTypeId(7));
  assert(isTrackTypeId(50));
  assert(!isPathTypeId(50));
  assert(isPathTypeId(51));
  assert(isPathTypeId(54));

  assert(shouldMirrorLegacySetting(1, false));
  assert(shouldMirrorLegacySetting(10, false));
  assert(!shouldMirrorLegacySetting(1, true));
  assert(!shouldMirrorLegacySetting(16, false));
  assert(isIndependentSetting(16));
  assert(isIndependentSetting(22));
  assert(isIndependentSetting(MAP_NAVIGATION_LABEL_DENSITY_SETTING_ID));
  assert(isIndependentSetting(MAP_NAVIGATION_LABEL_ORIENTATION_SETTING_ID));
  assert(isLabelSetting(MAP_LABEL_DENSITY_SETTING_ID));
  assert(isLabelSetting(MAP_NAVIGATION_LABEL_ORIENTATION_SETTING_ID));
  assert(!isLabelSetting(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID));
  assert(!isIndependentSetting(15));
  assert(!shouldApplyMirroredZoomToMapNavigation(false, true));
  assert(!shouldApplyMirroredZoomToMapNavigation(true, false));
  assert(shouldApplyMirroredZoomToMapNavigation(true, true));

  assert(clampValue(1, -1) == 0);
  assert(clampValue(16, 51) == 50);
  assert(clampValue(2, 3) == 2);
  assert(clampValue(17, -1) == 0);
  assert(clampValue(3, 1) == 2);
  assert(clampValue(18, 49) == 48);
  assert(clampValue(7, 6) == 5);
  assert(clampValue(19, -1) == 0);
  assert(clampValue(9, 25) == 20);
  assert(clampValue(21, -4) == -3);
  assert(clampValue(10, 0) == 1);
  assert(clampValue(22, 6) == 5);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_SETTING_ID, -1) == 0);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_SETTING_ID, 2) == 1);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID, -1) ==
         0);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID, 1) ==
         1);
  assert(clampValue(MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID, 3) ==
         3);
  assert(clampValue(MAP_LABEL_DENSITY_SETTING_ID, 4) == 3);
  assert(clampValue(MAP_LABEL_LANGUAGE_MODE_SETTING_ID, 3) == 2);
  assert(clampValue(MAP_LABEL_TEXT_SIZE_SETTING_ID, -1) == 0);
  assert(clampValue(MAP_LABEL_ORIENTATION_SETTING_ID, 2) == 1);
  assert(clampValue(MAP_NAVIGATION_LABEL_DENSITY_SETTING_ID, -1) == 0);
  assert(clampValue(MAP_NAVIGATION_LABEL_ORIENTATION_SETTING_ID, 2) == 1);
  assert(absoluteStreetWidthFromLegacyBoost(-3) == 1);
  assert(absoluteStreetWidthFromLegacyBoost(0) == 4);
  assert(absoluteStreetWidthFromLegacyBoost(4) == 8);
  assert(absoluteStreetWidthFromLegacyBoost(24) == 24);
  assert(clampAbsoluteStreetWidth(0) == 1);
  assert(clampAbsoluteStreetWidth(25) == 24);
  assert(legacyStreetWidthBoostFromAbsolute(1) == -3);
  assert(legacyStreetWidthBoostFromAbsolute(4) == 0);
  assert(legacyStreetWidthBoostFromAbsolute(24) == 20);

  const TestProfile map{1};
  const TestProfile mapNavigation{2};
  assert(&select(map, mapNavigation, false) == &map);
  assert(&select(map, mapNavigation, true) == &mapNavigation);
  return 0;
}
