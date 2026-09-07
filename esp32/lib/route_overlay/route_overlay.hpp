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
#include "../maps/src/mapSurface.hpp"
#include "navigation_visual_style.hpp"
#include "lvgl.h"
#include <Arduino.h>
#include <array>
#include <cstdint>
#include <vector>

/**
 * @brief Geographic point in microdegrees (lat/lon * 1,000,000)
 */
struct GeoPoint {
  int32_t lat; // Latitude * 1,000,000 (microdegrees)
  int32_t lon; // Longitude * 1,000,000 (microdegrees)
};

static constexpr size_t ROUTE_SNAPSHOT_MAX_POINTS = 128;

/** Immutable, bounded copy captured by the UI before a render job starts. */
struct RouteSnapshot {
  std::array<GeoPoint, ROUTE_SNAPSHOT_MAX_POINTS> points{};
  uint16_t count = 0;
  uint32_t revision = 0;

  constexpr bool hasRoute() const { return count >= 2; }
};

/**
 * Maps points from the immutable base-frame projection into the live viewport.
 * The base image uses the same pivot, target, and rotation delta through LVGL.
 */
struct RoutePresentationTransform {
  double inputPivotX = 0.0;
  double inputPivotY = 0.0;
  double outputPivotX = 0.0;
  double outputPivotY = 0.0;
  double rotationRad = 0.0;
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
  bool parseRouteData(const uint8_t *data, size_t len);

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

  /** Capture a fixed-size immutable route for a worker or UI presentation. */
  RouteSnapshot snapshot() const;

  /**
   * Draw a snapshot to a raw surface.  No LVGL object is touched.  When a
   * presented rider coordinate is supplied, the first route segment begins at
   * that exact world point and continues from the nearest forward segment.
   */
  static void drawSnapshot(
      const RouteSnapshot &snapshot, map_surface::Rgb565Surface surface,
      const map_projection::Projection &projection, uint8_t baseLineWidth,
      const map_transform::WorldPoint *presentedWorld = nullptr,
      const RoutePresentationTransform *presentation = nullptr);

  /** Draw the route directly into RGB565+A8 without scanning the color plane. */
  static void drawSnapshot(
      const RouteSnapshot &snapshot, map_surface::Rgb565A8Surface surface,
      const map_projection::Projection &projection, uint8_t baseLineWidth,
      const map_transform::WorldPoint *presentedWorld = nullptr,
      const RoutePresentationTransform *presentation = nullptr);

  /**
   * @brief Clear all route points
   */
  void clear();

  /**
   * @brief Check if route data is loaded
   * @return true if route has at least 2 points
   */
  bool hasRoute() const;

  /**
   * @brief Get number of points in current route
   */
  size_t getPointCount() const;

  /** Monotonic content revision for invalidating prepared raster map cells. */
  uint32_t revision() const;

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
  mutable portMUX_TYPE routeMutex = portMUX_INITIALIZER_UNLOCKED;
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
