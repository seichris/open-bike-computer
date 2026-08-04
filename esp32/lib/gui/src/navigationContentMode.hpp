#pragma once

#include <cstdint>

namespace navigation_content_mode {

enum class Mode : uint8_t {
  FavoriteDestinations,
  ActiveGuidance,
};

constexpr Mode forNavigationState(bool hasNavigationData) {
  return hasNavigationData ? Mode::ActiveGuidance
                           : Mode::FavoriteDestinations;
}

// The dedicated Navigation screen owns destination selection. Map +
// Navigation remains a map-first screen and only adds its maneuver overlay
// once guidance is active.
constexpr bool showsMapGuidanceOverlay(bool hasNavigationData) {
  return hasNavigationData;
}

constexpr bool hidesMapGuidanceOverlay(bool hasNavigationData) {
  return !showsMapGuidanceOverlay(hasNavigationData);
}

// Bird's-eye is a screen profile, not a route-overlay feature. Keeping it
// active before a route starts lets Map + Navigation render its configured
// perspective (including 3D buildings) as soon as the screen opens.
constexpr bool usesMapGuidanceBirdsEye(bool isMapGuidanceScreen,
                                      bool birdsEyeEnabled) {
  return isMapGuidanceScreen && birdsEyeEnabled;
}

constexpr bool extrudesMapGuidanceBuildings(bool buildingsVisible,
                                            bool isMapGuidanceScreen,
                                            bool birdsEyeProjection,
                                            bool buildings3DEnabled) {
  return buildingsVisible && isMapGuidanceScreen && birdsEyeProjection &&
         buildings3DEnabled;
}

} // namespace navigation_content_mode
