#pragma once

/**
 * @file route_overlay.hpp
 * @brief Route overlay for displaying Apple Maps route on OSM vector map
 *
 * Receives compressed route geometry from iOS app via BLE and renders
 * as a thick blue line overlay on the existing vector map.
 */

#include "../utils/src/psram_allocator.hpp"
#include "../maps/src/map_projection.hpp"
#include "navigation_visual_style.hpp"
#include "lvgl.h"
#include <Arduino.h>
#include <cstdint>
#include <vector>

/**
 * @brief Geographic point in microdegrees (lat/lon * 1,000,000)
 */
struct GeoPoint {
  int32_t lat; // Latitude * 1,000,000 (microdegrees)
  int32_t lon; // Longitude * 1,000,000 (microdegrees)
};

/**
 * @brief Route overlay manager for rendering iOS route on ESP32 map
 */
class RouteOverlay {
public:
  RouteOverlay() = default;

  /**
   * @brief Parse compressed route geometry received from iOS via BLE
   *
   * Format: [StartLat:4][StartLon:4][DeltaLat:2][DeltaLon:2]...
   * All values are little-endian.
   *
   * @param data Pointer to compressed route data
   * @param len Length of data in bytes
   */
  void parseRouteData(const uint8_t *data, size_t len);

  /**
   * @brief Draw route overlay on LVGL canvas
   *
   * Uses the same immutable projection as the base vector map so the route
   * remains aligned in both flat and bird's-eye modes.
   *
   * @param canvas LVGL canvas object to draw on
   * @param projection Projection snapshot used for the current map frame
   */
  void drawRoute(lv_obj_t *canvas,
                 const map_projection::Projection &projection);

  /**
   * @brief Clear all route points
   */
  void clear();

  /**
   * @brief Check if route data is loaded
   * @return true if route has at least 2 points
   */
  bool hasRoute() const { return points.size() >= 2; }

  /**
   * @brief Get number of points in current route
   */
  size_t getPointCount() const { return points.size(); }

  /** Monotonic content revision for invalidating prepared raster map cells. */
  uint32_t revision() const { return revisionCounter; }

  /**
   * @brief Estimate route bearing near a current GPS position.
   *
   * @param lat Current latitude in degrees
   * @param lon Current longitude in degrees
   * @param headingDeg Output route segment bearing in degrees, 0-359
   * @return true when a usable route segment was found
   */
  bool headingNear(double lat, double lon, uint16_t &headingDeg) const;

private:
  std::vector<GeoPoint, PsramAllocator<GeoPoint>> points;
  uint32_t revisionCounter = 0;

  /**
   * @brief Draw a single line segment with thickness
   */
  void drawThickLine(uint16_t *buf, int32_t bufW, int32_t bufH, uint32_t stride,
                     int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                     uint16_t color, int16_t thickness);

};

// Global route overlay instance
extern RouteOverlay routeOverlay;
