/**
 * @file route_overlay.cpp
 * @brief Route overlay implementation for iOS route geometry rendering
 *
 * Parses compressed route data from BLE and renders as thick blue line
 * overlay on the vector map canvas.
 */

#include "route_overlay.hpp"
#include "../ble_navigation/ble_navigation.hpp"
#include "../maps/src/mapTransform.hpp"
#include "../utils/src/line_rasterizer.hpp"
#include "../../utils/src/gpsMath.hpp"
#include <Arduino.h>
#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstring>

// Global instance
RouteOverlay routeOverlay;

// Screen center (466x466 display)
static constexpr int16_t SCREEN_CENTER_X = 233;
static constexpr int16_t SCREEN_CENTER_Y = 233;

// Meters per microdegree at mid-latitudes (approximate)
// At equator: 1° lat ≈ 111km, 1 microdegree ≈ 0.111m
// At 45°: 1° lon ≈ 78km, so we use an average
static constexpr double METERS_PER_MICRODEGREE_LAT = 0.000111; // ~0.111m
static constexpr double METERS_PER_MICRODEGREE_LON =
    0.000085; // ~0.085m at 40° lat

void RouteOverlay::parseRouteData(const uint8_t *data, size_t len) {
  points.clear();
  revisionCounter++;

  if (len < 8) {
    Serial.println(
        "Route data too short (need at least 8 bytes for start point)");
    return;
  }

  // Read start point (8 bytes: 4 lat + 4 lon, little-endian)
  int32_t lat, lon;
  memcpy(&lat, data, 4);
  memcpy(&lon, data + 4, 4);

  points.push_back({lat, lon});

  // Read delta points (4 bytes each: 2 lat + 2 lon, little-endian)
  size_t offset = 8;
  while (offset + 4 <= len) {
    int16_t dLat, dLon;
    memcpy(&dLat, data + offset, 2);
    memcpy(&dLon, data + offset + 2, 2);

    lat += dLat;
    lon += dLon;

    points.push_back({lat, lon});
    offset += 4;
  }

  Serial.printf("Route parsed: %d points from %d bytes\n", points.size(), len);
}

void RouteOverlay::clear() {
  points.clear();
  revisionCounter++;
  Serial.println("Route overlay cleared");
}

bool RouteOverlay::headingNear(double lat, double lon,
                               uint16_t &headingDeg) const {
  if (points.size() < 2) {
    return false;
  }

  const double cosLat = cos(DEG2RAD(lat));
  double bestDistanceSq = DBL_MAX;
  size_t bestSegment = 0;

  for (size_t i = 0; i + 1 < points.size(); i++) {
    const double lat1 = points[i].lat / 1000000.0;
    const double lon1 = points[i].lon / 1000000.0;
    const double lat2 = points[i + 1].lat / 1000000.0;
    const double lon2 = points[i + 1].lon / 1000000.0;

    const double x1 = (lon1 - lon) * cosLat;
    const double y1 = lat1 - lat;
    const double x2 = (lon2 - lon) * cosLat;
    const double y2 = lat2 - lat;
    const double segX = x2 - x1;
    const double segY = y2 - y1;
    const double segLenSq = (segX * segX) + (segY * segY);
    if (segLenSq <= 0.0) {
      continue;
    }

    double t = -((x1 * segX) + (y1 * segY)) / segLenSq;
    t = std::max(0.0, std::min(1.0, t));
    const double closestX = x1 + (segX * t);
    const double closestY = y1 + (segY * t);
    const double distanceSq = (closestX * closestX) + (closestY * closestY);
    if (distanceSq < bestDistanceSq) {
      bestDistanceSq = distanceSq;
      bestSegment = i;
    }
  }

  if (bestDistanceSq == DBL_MAX) {
    return false;
  }

  const double segmentHeading =
      calcCourse(points[bestSegment].lat / 1000000.0,
                 points[bestSegment].lon / 1000000.0,
                 points[bestSegment + 1].lat / 1000000.0,
                 points[bestSegment + 1].lon / 1000000.0);
  headingDeg = static_cast<uint16_t>(round(segmentHeading)) % 360;
  return true;
}

#ifndef DEG2RAD
#define DEG2RAD(a) ((a) / (180.0 / M_PI))
#endif

int16_t RouteOverlay::geoToScreenX(int32_t lonMicro, int32_t centerMercatorX,
                                   uint8_t zoom, int16_t screenWidth,
                                   int16_t anchorX) {
  (void)screenWidth;

  // Convert microdegrees to degrees
  double lon = lonMicro / 1000000.0;

  // Use the exact same projection as maps.cpp: lon2x(lon) = DEG2RAD(lon) *
  // EARTH_RADIUS
  double worldX = DEG2RAD(lon) * EARTH_RADIUS;
  double centerWorldX = (double)centerMercatorX;

  return static_cast<int16_t>(
      round((worldX - centerWorldX) *
            map_transform::worldToScreenScale(zoom)) +
      anchorX);
}

int16_t RouteOverlay::geoToScreenY(int32_t latMicro, int32_t centerMercatorY,
                                   uint8_t zoom, int16_t screenHeight,
                                   int16_t screenWidth, int16_t anchorY) {
  (void)screenHeight;
  (void)screenWidth;

  // Convert microdegrees to degrees
  double lat = latMicro / 1000000.0;

  // Use the exact same projection as maps.cpp: lat2y(lat) =
  // log(tan(DEG2RAD(lat) / 2 + M_PI / 4)) * EARTH_RADIUS
  double worldY = log(tan(DEG2RAD(lat) / 2.0 + M_PI / 4.0)) * EARTH_RADIUS;
  double centerWorldY = (double)centerMercatorY;

  return static_cast<int16_t>(
      round(-(worldY - centerWorldY) *
            map_transform::worldToScreenScale(zoom)) +
      anchorY);
}

void RouteOverlay::drawThickLine(uint16_t *buf, int32_t bufW, int32_t bufH,
                                 uint32_t stride, int16_t x1, int16_t y1,
                                 int16_t x2, int16_t y2, uint16_t color,
                                 int16_t thickness) {
  const uint8_t lineWidth =
      static_cast<uint8_t>(std::max<int16_t>(1, thickness));
  line_rasterizer::drawFilledLine(buf, bufW, bufH, stride, x1, y1, x2, y2,
                                  color, lineWidth);
}

void RouteOverlay::drawRoute(lv_obj_t *canvas, int32_t centerMercatorX,
                             int32_t centerMercatorY, uint8_t zoom,
                             uint16_t mapScrWidth, uint16_t mapScrHeight,
                             double rotationRad, int16_t anchorX,
                             int16_t anchorY) {
  (void)mapScrWidth;
  (void)mapScrHeight;

  if (points.size() < 2) {
    Serial.println("RouteOverlay: Not enough points to draw (need >= 2)");
    return; // Need at least 2 points to draw a line
  }

  Serial.printf("RouteOverlay::drawRoute: zoom=%d points=%d rot=%.2frad\n",
                zoom, points.size(), rotationRad);

  // Get canvas buffer
  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  if (!draw_buf) {
    Serial.println("RouteOverlay: Could not get canvas draw buffer");
    return;
  }

  uint16_t *buf = (uint16_t *)draw_buf->data;
  int32_t bufW = draw_buf->header.w;
  int32_t bufH = draw_buf->header.h;
  uint32_t stride =
      draw_buf->header.stride / 2; // stride is in bytes, we need pixels
  if (anchorX < 0) {
    anchorX = bufW / 2;
  }
  if (anchorY < 0) {
    anchorY = bufH / 2;
  }

  Serial.printf("RouteOverlay: Canvas buffer W=%d H=%d stride=%d\n", bufW, bufH,
                stride);

  // Pre-calculate rotation values
  double cosA = cos(rotationRad);
  double sinA = sin(rotationRad);

  int drawnCount = 0;
  // Draw route segments
  for (size_t i = 0; i < points.size() - 1; i++) {
    // Convert geographic coordinates to screen pixels
    int16_t x1 =
        geoToScreenX(points[i].lon, centerMercatorX, zoom, bufW, anchorX);
    int16_t y1 = geoToScreenY(points[i].lat, centerMercatorY, zoom, bufH, bufW,
                              anchorY);
    int16_t x2 =
        geoToScreenX(points[i + 1].lon, centerMercatorX, zoom, bufW, anchorX);
    int16_t y2 = geoToScreenY(points[i + 1].lat, centerMercatorY, zoom, bufH,
                              bufW, anchorY);

    // Apply rotation transform if rotationRad is non-zero
    if (rotationRad != 0.0) {
      // Transform point 1
      double dx1 = x1 - anchorX;
      double dy1 = y1 - anchorY;
      x1 = (int16_t)(dx1 * cosA - dy1 * sinA + anchorX);
      y1 = (int16_t)(dx1 * sinA + dy1 * cosA + anchorY);

      // Transform point 2
      double dx2 = x2 - anchorX;
      double dy2 = y2 - anchorY;
      x2 = (int16_t)(dx2 * cosA - dy2 * sinA + anchorX);
      y2 = (int16_t)(dx2 * sinA + dy2 * cosA + anchorY);
    }

    // LOGGING: Debug Center Offset for the first segment
    if (i == 0) {
      ESP_LOGI(
          "RouteOverlay",
          "DEBUG_OFFSET: Center(%d,%d) StartPixel(%d,%d) Diff(%d,%d) Rot(%.2f)",
          anchorX, anchorY, x1, y1, x1 - anchorX, y1 - anchorY, rotationRad);
    }

    // Skip if both endpoints are far off-screen
    const int16_t margin = 50;
    if ((x1 < -margin && x2 < -margin) ||
        (x1 > bufW + margin && x2 > bufW + margin) ||
        (y1 < -margin && y2 < -margin) ||
        (y1 > bufH + margin && y2 > bufH + margin)) {
      continue;
    }

    // Draw thick line segment
    int16_t routeLineWidth = std::min<int16_t>(
        std::max<int16_t>(
            1, (int16_t)currentMapStyleSettings().routeLineWidth),
        48);
    drawThickLine(buf, bufW, bufH, stride, x1, y1, x2, y2, ROUTE_COLOR,
                  routeLineWidth);
    drawnCount++;
  }

  ESP_LOGI("RouteOverlay", "Route drawn: %d/%d segments (some off-screen)",
           drawnCount, (int)points.size() - 1);
}
