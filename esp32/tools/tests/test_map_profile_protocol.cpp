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
  assert(!isIndependentSetting(15));

  assert(clampValue(1, -1) == 0);
  assert(clampValue(16, 51) == 50);
  assert(clampValue(2, 3) == 2);
  assert(clampValue(17, -1) == 0);
  assert(clampValue(3, 1) == 2);
  assert(clampValue(18, 49) == 48);
  assert(clampValue(7, 6) == 5);
  assert(clampValue(19, -1) == 0);
  assert(clampValue(9, 25) == 24);
  assert(clampValue(21, -1) == 0);
  assert(clampValue(10, 0) == 1);
  assert(clampValue(22, 6) == 5);

  const TestProfile map{1};
  const TestProfile mapNavigation{2};
  assert(&select(map, mapNavigation, false) == &map);
  assert(&select(map, mapNavigation, true) == &mapNavigation);
  return 0;
}
