#pragma once

#include <stdint.h>

namespace map_profile_protocol {

constexpr uint8_t CAPABILITY_MASK = 1 << 3;
constexpr uint8_t CLIENT_VERSION = 2;
constexpr uint8_t EXTENDED_VISIBILITY_CAPABILITY_MASK = 1 << 4;
constexpr uint8_t EXTENDED_VISIBILITY_CLIENT_VERSION = 3;

constexpr uint32_t VISIBILITY_BUILDINGS = 1u << 0;
constexpr uint32_t VISIBILITY_GREEN_SPACE = 1u << 1;
constexpr uint32_t VISIBILITY_PATHS = 1u << 2;
constexpr uint32_t VISIBILITY_MAJOR_ROADS = 1u << 3;
constexpr uint32_t VISIBILITY_LOCAL_STREETS = 1u << 4;
constexpr uint32_t VISIBILITY_WATER = 1u << 5;
constexpr uint32_t VISIBILITY_RAILWAYS = 1u << 6;
constexpr uint32_t VISIBILITY_OTHER_AREAS = 1u << 7;
constexpr uint32_t VISIBILITY_ROUTE_OVERLAY = 1u << 8;
constexpr uint32_t VISIBILITY_POSITION_MARKER = 1u << 9;
constexpr uint32_t VISIBILITY_SERVICE_ROADS = 1u << 10;
constexpr uint32_t VISIBILITY_TRACKS = 1u << 11;
constexpr uint32_t VISIBILITY_EXTENDED_MARKER = 1u << 12;
constexpr uint32_t VISIBILITY_LEGACY_FEATURE_MASK = 0xFF;
constexpr uint32_t VISIBILITY_EXTENDED_FEATURE_MASK =
    VISIBILITY_LEGACY_FEATURE_MASK | VISIBILITY_SERVICE_ROADS |
    VISIBILITY_TRACKS;
constexpr uint32_t VISIBILITY_OVERLAY_MASK =
    VISIBILITY_ROUTE_OVERLAY | VISIBILITY_POSITION_MARKER;
constexpr uint8_t MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL = 0;
constexpr uint32_t MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK =
    VISIBILITY_GREEN_SPACE | VISIBILITY_MAJOR_ROADS |
    VISIBILITY_LOCAL_STREETS | VISIBILITY_WATER;

inline bool clientSupportsIndependentProfiles(uint8_t clientVersion) {
  return clientVersion >= CLIENT_VERSION;
}

inline bool clientSupportsExtendedVisibility(uint8_t clientVersion) {
  return clientVersion >= EXTENDED_VISIBILITY_CLIENT_VERSION;
}

inline uint32_t normalizedFeatureVisibilityMask(uint32_t mask) {
  uint32_t normalized = mask & VISIBILITY_LEGACY_FEATURE_MASK;
  if ((mask & VISIBILITY_EXTENDED_MARKER) != 0) {
    normalized |= mask & (VISIBILITY_SERVICE_ROADS | VISIBILITY_TRACKS);
  } else {
    if ((normalized & VISIBILITY_LOCAL_STREETS) != 0)
      normalized |= VISIBILITY_SERVICE_ROADS;
    if ((normalized & VISIBILITY_PATHS) != 0)
      normalized |= VISIBILITY_TRACKS;
  }
  return normalized;
}

inline uint32_t visibilityMaskForMapVersion(uint32_t mask,
                                            uint8_t mapVersion) {
  if (mapVersion >= 2)
    return mask;

  const uint32_t localAndService =
      VISIBILITY_LOCAL_STREETS | VISIBILITY_SERVICE_ROADS;
  const uint32_t pathsAndTracks = VISIBILITY_PATHS | VISIBILITY_TRACKS;
  if ((mask & localAndService) != 0)
    mask |= localAndService;
  else
    mask &= ~localAndService;
  if ((mask & pathsAndTracks) != 0)
    mask |= pathsAndTracks;
  else
    mask &= ~pathsAndTracks;
  return mask;
}

inline bool isServiceRoadTypeId(uint8_t typeId) { return typeId == 10; }

inline bool isTrackTypeId(uint8_t typeId) { return typeId == 50; }

inline bool isPathTypeId(uint8_t typeId) {
  return typeId > 50 && typeId < 100;
}

inline bool isLocalStreetTypeId(uint8_t typeId) {
  return typeId >= 6 && typeId < 50 && !isServiceRoadTypeId(typeId);
}

inline bool isIndependentSetting(uint8_t settingId) {
  return settingId >= 16 && settingId <= 22;
}

inline bool isLegacySetting(uint8_t settingId) {
  return settingId == 1 || settingId == 2 || settingId == 3 ||
         settingId == 7 || settingId == 8 || settingId == 9 ||
         settingId == 10;
}

inline bool shouldMirrorLegacySetting(uint8_t settingId,
                                      bool independentProfilesEnabled) {
  return isLegacySetting(settingId) && !independentProfilesEnabled;
}

inline bool shouldApplyMirroredZoomToMapNavigation(
    bool mirrorLegacySetting, bool mapNavigationActive) {
  return mirrorLegacySetting && mapNavigationActive;
}

inline int32_t clampValue(uint8_t settingId, int32_t value) {
  int32_t minimum = 0;
  int32_t maximum = 0;
  switch (settingId) {
  case 1:
  case 16:
    maximum = 50;
    break;
  case 2:
  case 17:
    maximum = 2;
    break;
  case 3:
  case 18:
    minimum = 2;
    maximum = 48;
    break;
  case 7:
  case 19:
    maximum = 5;
    break;
  case 9:
  case 21:
    maximum = 24;
    break;
  case 10:
  case 22:
    minimum = 1;
    maximum = 5;
    break;
  default:
    return value;
  }
  return value < minimum ? minimum : (value > maximum ? maximum : value);
}

template <typename Profile>
inline const Profile &select(const Profile &mapStyle,
                             const Profile &mapNavigationStyle,
                             bool mapNavigationActive) {
  return mapNavigationActive ? mapNavigationStyle : mapStyle;
}

} // namespace map_profile_protocol
