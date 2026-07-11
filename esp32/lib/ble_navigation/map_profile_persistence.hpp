#pragma once

#include "map_profile_protocol.hpp"

#include <stdint.h>

namespace map_profile_persistence {

template <typename Store, typename Profile>
inline void load(Store &store, Profile &mapStyle,
                 Profile &mapNavigationStyle) {
  const bool hasStoredMapStyle =
      store.isKey("minPolySize") || store.isKey("detailLevel") ||
      store.isKey("routeWidth") || store.isKey("streetBoost") ||
      store.isKey("markerScale") || store.isKey("zoomLevel") ||
      store.isKey("visMask");

  mapStyle.minPolygonSize = store.getUChar("minPolySize", 0);
  mapStyle.detailLevel = store.getUChar("detailLevel", 2);
  mapStyle.routeLineWidth = store.getUChar("routeWidth", 4);
  mapStyle.streetLineWidthBoost = store.getUChar("streetBoost", 0);
  mapStyle.positionMarkerScale = store.getUChar("markerScale", 2);
  mapStyle.zoomLevel = store.getUChar("zoomLevel", 4);
  const uint32_t storedMapVisibility = store.getUInt("visMask", 0x3FF);
  mapStyle.visibilityMask =
      map_profile_protocol::normalizedFeatureVisibilityMask(storedMapVisibility);

  mapNavigationStyle.minPolygonSize =
      store.getUChar("navMinPoly", mapStyle.minPolygonSize);
  mapNavigationStyle.detailLevel =
      store.getUChar(
          "navDetail",
          hasStoredMapStyle
              ? mapStyle.detailLevel
              : map_profile_protocol::MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL);
  mapNavigationStyle.routeLineWidth =
      store.getUChar("navRouteW", mapStyle.routeLineWidth);
  mapNavigationStyle.streetLineWidthBoost =
      store.getUChar("navStreetB", mapStyle.streetLineWidthBoost);
  mapNavigationStyle.positionMarkerScale =
      store.getUChar("navMarkerS", mapStyle.positionMarkerScale);
  mapNavigationStyle.zoomLevel = store.getUChar("navZoom", mapStyle.zoomLevel);
  mapNavigationStyle.visibilityMask =
      map_profile_protocol::normalizedFeatureVisibilityMask(store.getUInt(
          "navVis",
          (hasStoredMapStyle
               ? mapStyle.visibilityMask
               : map_profile_protocol::MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK) |
              map_profile_protocol::VISIBILITY_EXTENDED_MARKER));
}

template <typename Store, typename Profile>
inline bool persistSetting(Store &store, const Profile &mapStyle,
                           const Profile &mapNavigationStyle,
                           uint32_t navigationOverlayVisibilityMask,
                           uint8_t settingId, bool mirrorLegacySetting) {
  switch (settingId) {
  case 1:
    store.putUChar("minPolySize", mapStyle.minPolygonSize);
    if (mirrorLegacySetting)
      store.putUChar("navMinPoly", mapNavigationStyle.minPolygonSize);
    return true;
  case 2:
    store.putUChar("detailLevel", mapStyle.detailLevel);
    if (mirrorLegacySetting)
      store.putUChar("navDetail", mapNavigationStyle.detailLevel);
    return true;
  case 3:
    store.putUChar("routeWidth", mapStyle.routeLineWidth);
    if (mirrorLegacySetting)
      store.putUChar("navRouteW", mapNavigationStyle.routeLineWidth);
    return true;
  case 7:
    store.putUChar("zoomLevel", mapStyle.zoomLevel);
    if (mirrorLegacySetting)
      store.putUChar("navZoom", mapNavigationStyle.zoomLevel);
    return true;
  case 8:
    store.putUInt("visMask",
                  mapStyle.visibilityMask | navigationOverlayVisibilityMask |
                      map_profile_protocol::VISIBILITY_EXTENDED_MARKER);
    if (mirrorLegacySetting) {
      store.putUInt("navVis", mapNavigationStyle.visibilityMask |
                                    map_profile_protocol::VISIBILITY_EXTENDED_MARKER);
    }
    return true;
  case 9:
    store.putUChar("streetBoost", mapStyle.streetLineWidthBoost);
    if (mirrorLegacySetting)
      store.putUChar("navStreetB", mapNavigationStyle.streetLineWidthBoost);
    return true;
  case 10:
    store.putUChar("markerScale", mapStyle.positionMarkerScale);
    if (mirrorLegacySetting)
      store.putUChar("navMarkerS", mapNavigationStyle.positionMarkerScale);
    return true;
  case 16:
    store.putUChar("navMinPoly", mapNavigationStyle.minPolygonSize);
    return true;
  case 17:
    store.putUChar("navDetail", mapNavigationStyle.detailLevel);
    return true;
  case 18:
    store.putUChar("navRouteW", mapNavigationStyle.routeLineWidth);
    return true;
  case 19:
    store.putUChar("navZoom", mapNavigationStyle.zoomLevel);
    return true;
  case 20:
    store.putUInt("navVis", mapNavigationStyle.visibilityMask |
                                map_profile_protocol::VISIBILITY_EXTENDED_MARKER);
    return true;
  case 21:
    store.putUChar("navStreetB", mapNavigationStyle.streetLineWidthBoost);
    return true;
  case 22:
    store.putUChar("navMarkerS", mapNavigationStyle.positionMarkerScale);
    return true;
  default:
    return false;
  }
}

} // namespace map_profile_persistence
