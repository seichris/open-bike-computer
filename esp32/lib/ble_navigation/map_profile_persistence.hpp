#pragma once

#include "map_profile_protocol.hpp"

#include <stdint.h>

namespace map_profile_persistence {

template <typename Store, typename Profile>
inline void load(Store &store, Profile &mapStyle,
                 Profile &mapNavigationStyle) {
  const bool hasStoredMapStyle =
      store.isKey("minPolySize") || store.isKey("detailLevel") ||
      store.isKey("routeWidth") || store.isKey("streetWidth") ||
      store.isKey("streetBoost") ||
      store.isKey("markerScale") || store.isKey("zoomLevel") ||
      store.isKey("visMask");

  mapStyle.minPolygonSize = store.getUChar("minPolySize", 0);
  mapStyle.detailLevel = store.getUChar(
      "detailLevel", map_profile_protocol::MAP_DEFAULT_DETAIL_LEVEL);
  mapStyle.routeLineWidth = store.getUChar(
      "routeWidth", map_profile_protocol::MAP_DEFAULT_ROUTE_LINE_WIDTH);
  mapStyle.streetLineWidth = static_cast<uint8_t>(
      store.isKey("streetWidth")
          ? map_profile_protocol::clampAbsoluteStreetWidth(store.getUChar(
                "streetWidth", map_profile_protocol::DEFAULT_STREET_WIDTH))
          : map_profile_protocol::absoluteStreetWidthFromLegacyBoost(
                store.getUChar("streetBoost", 0)));
  mapStyle.positionMarkerScale = store.getUChar("markerScale", 2);
  mapStyle.zoomLevel = store.getUChar(
      "zoomLevel", map_profile_protocol::MAP_DEFAULT_ZOOM_LEVEL);
  const uint32_t storedMapVisibility = store.getUInt("visMask", 0x3FF);
  mapStyle.visibilityMask =
      map_profile_protocol::normalizedFeatureVisibilityMask(storedMapVisibility);
  mapStyle.labelDensity = static_cast<uint8_t>(map_profile_protocol::clampValue(
      25, store.getUChar("labelDensity",
                         map_profile_protocol::DEFAULT_LABEL_DENSITY)));
  mapStyle.labelLanguageMode = static_cast<uint8_t>(
      map_profile_protocol::clampValue(
          26, store.getUChar(
                  "labelLang",
                  map_profile_protocol::DEFAULT_LABEL_LANGUAGE_MODE)));
  mapStyle.labelTextSize = static_cast<uint8_t>(map_profile_protocol::clampValue(
      27, store.getUChar("labelSize",
                         map_profile_protocol::DEFAULT_LABEL_TEXT_SIZE)));
  mapStyle.labelOrientation = static_cast<uint8_t>(
      map_profile_protocol::clampValue(
          28, store.getUChar(
                  "labelOrient",
                  map_profile_protocol::DEFAULT_LABEL_ORIENTATION)));

  mapNavigationStyle.minPolygonSize =
      store.getUChar("navMinPoly", mapStyle.minPolygonSize);
  mapNavigationStyle.detailLevel =
      store.getUChar(
          "navDetail",
          hasStoredMapStyle
              ? mapStyle.detailLevel
              : map_profile_protocol::MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL);
  mapNavigationStyle.routeLineWidth =
      store.getUChar("navRouteW",
                     hasStoredMapStyle
                         ? mapStyle.routeLineWidth
                         : map_profile_protocol::
                               MAP_NAVIGATION_DEFAULT_ROUTE_LINE_WIDTH);
  if (store.isKey("navStreetW")) {
    mapNavigationStyle.streetLineWidth = static_cast<uint8_t>(
        map_profile_protocol::clampAbsoluteStreetWidth(store.getUChar(
            "navStreetW", map_profile_protocol::DEFAULT_STREET_WIDTH)));
  } else if (store.isKey("navStreetB")) {
    mapNavigationStyle.streetLineWidth = static_cast<uint8_t>(
        map_profile_protocol::absoluteStreetWidthFromLegacyBoost(
            store.getUChar("navStreetB", 0)));
  } else {
    mapNavigationStyle.streetLineWidth = mapStyle.streetLineWidth;
  }
  mapNavigationStyle.positionMarkerScale =
      store.getUChar("navMarkerS", mapStyle.positionMarkerScale);
  mapNavigationStyle.zoomLevel = store.getUChar(
      "navZoom", hasStoredMapStyle
                     ? mapStyle.zoomLevel
                     : map_profile_protocol::MAP_NAVIGATION_DEFAULT_ZOOM_LEVEL);
  mapNavigationStyle.visibilityMask =
      map_profile_protocol::normalizedFeatureVisibilityMask(store.getUInt(
          "navVis",
          (hasStoredMapStyle
               ? mapStyle.visibilityMask
               : map_profile_protocol::MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK) |
              map_profile_protocol::VISIBILITY_EXTENDED_MARKER));
  mapNavigationStyle.labelDensity = static_cast<uint8_t>(
      map_profile_protocol::clampValue(
          29, store.getUChar("navLabelDen", mapStyle.labelDensity)));
  mapNavigationStyle.labelLanguageMode = static_cast<uint8_t>(
      map_profile_protocol::clampValue(
          30, store.getUChar("navLabelLng", mapStyle.labelLanguageMode)));
  mapNavigationStyle.labelTextSize = static_cast<uint8_t>(
      map_profile_protocol::clampValue(
          31, store.getUChar("navLabelSiz", mapStyle.labelTextSize)));
  mapNavigationStyle.labelOrientation = static_cast<uint8_t>(
      map_profile_protocol::clampValue(
          32, store.getUChar("navLabelOri", mapStyle.labelOrientation)));

  if (!store.isKey("streetWidth"))
    store.putUChar("streetWidth", mapStyle.streetLineWidth);
  if (!store.isKey("navStreetW"))
    store.putUChar("navStreetW", mapNavigationStyle.streetLineWidth);
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
    store.putUChar("streetWidth", mapStyle.streetLineWidth);
    store.putUChar(
        "streetBoost",
        static_cast<uint8_t>(mapStyle.streetLineWidth >
                                     map_profile_protocol::DEFAULT_STREET_WIDTH
                                 ? mapStyle.streetLineWidth -
                                       map_profile_protocol::DEFAULT_STREET_WIDTH
                                 : 0));
    if (mirrorLegacySetting) {
      store.putUChar("navStreetW", mapNavigationStyle.streetLineWidth);
      store.putUChar(
          "navStreetB",
          static_cast<uint8_t>(
              mapNavigationStyle.streetLineWidth >
                      map_profile_protocol::DEFAULT_STREET_WIDTH
                  ? mapNavigationStyle.streetLineWidth -
                        map_profile_protocol::DEFAULT_STREET_WIDTH
                  : 0));
    }
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
    store.putUChar("navStreetW", mapNavigationStyle.streetLineWidth);
    store.putUChar(
        "navStreetB",
        static_cast<uint8_t>(
            mapNavigationStyle.streetLineWidth >
                    map_profile_protocol::DEFAULT_STREET_WIDTH
                ? mapNavigationStyle.streetLineWidth -
                      map_profile_protocol::DEFAULT_STREET_WIDTH
                : 0));
    return true;
  case 22:
    store.putUChar("navMarkerS", mapNavigationStyle.positionMarkerScale);
    return true;
  case 25:
    store.putUChar("labelDensity", mapStyle.labelDensity);
    return true;
  case 26:
    store.putUChar("labelLang", mapStyle.labelLanguageMode);
    return true;
  case 27:
    store.putUChar("labelSize", mapStyle.labelTextSize);
    return true;
  case 28:
    store.putUChar("labelOrient", mapStyle.labelOrientation);
    return true;
  case 29:
    store.putUChar("navLabelDen", mapNavigationStyle.labelDensity);
    return true;
  case 30:
    store.putUChar("navLabelLng", mapNavigationStyle.labelLanguageMode);
    return true;
  case 31:
    store.putUChar("navLabelSiz", mapNavigationStyle.labelTextSize);
    return true;
  case 32:
    store.putUChar("navLabelOri", mapNavigationStyle.labelOrientation);
    return true;
  default:
    return false;
  }
}

} // namespace map_profile_persistence
