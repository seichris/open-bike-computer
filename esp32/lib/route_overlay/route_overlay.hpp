#pragma once

/**
 * @file route_overlay.hpp
 * @brief Route overlay for displaying Apple Maps route on OSM vector map
 *
 * Receives compressed route geometry from iOS app via BLE and renders
 * as a thick blue line overlay on the existing vector map.
 */

#include "../utils/src/psram_allocator.hpp"
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
   * Uses the current map center and zoom to transform geographic
   * coordinates to screen pixels.
   *
   * @param canvas LVGL canvas object to draw on
   * @param centerLat Map center latitude in microdegrees
   * @param centerMercatorX Map center X in Mercator units (meters)
   * @param centerMercatorY Map center Y in Mercator units (meters)
   * @param zoom Current zoom level (higher = more zoomed in)
   * @param mapScrWidth Map screen width (for coordinate centering)
   * @param mapScrHeight Map screen height (for Y-axis flip)
   */
  void drawRoute(lv_obj_t *canvas, int32_t centerMercatorX,
                 int32_t centerMercatorY, uint8_t zoom, uint16_t mapScrWidth,
                 uint16_t mapScrHeight, double rotationRad = 0.0);

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

private:
  std::vector<GeoPoint, PsramAllocator<GeoPoint>> points;

  static constexpr uint16_t ROUTE_COLOR =
      0x1F9F; // Bright blue (RGB565, byte-swapped for LVGL)

  /**
   * @brief Convert longitude to screen X coordinate
   */
  int16_t geoToScreenX(int32_t lon, int32_t centerLon, uint8_t zoom,
                       int16_t screenWidth);

  /**
   * @brief Convert latitude to screen Y coordinate
   */
  int16_t geoToScreenY(int32_t lat, int32_t centerLat, uint8_t zoom,
                       int16_t screenHeight, int16_t screenWidth);

  /**
   * @brief Draw a single line segment with thickness
   */
  void drawThickLine(uint16_t *buf, int32_t bufW, int32_t bufH, uint32_t stride,
                     int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                     uint16_t color, int16_t thickness);

  /**
   * @brief Draw a single pixel-width line (Bresenham's algorithm)
   */
  void drawLineSegment(uint16_t *buf, int32_t bufW, int32_t bufH,
                       uint32_t stride, int16_t x1, int16_t y1, int16_t x2,
                       int16_t y2, uint16_t color);
};

// Global route overlay instance
extern RouteOverlay routeOverlay;
