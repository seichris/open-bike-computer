/**
 * @file route_overlay.cpp
 * @brief Route overlay implementation for iOS route geometry rendering
 *
 * Parses compressed route data from BLE and renders as thick blue line
 * overlay on the vector map canvas.
 */

#include "route_overlay.hpp"
#include "../ble_navigation/ble_navigation.hpp"
#include "../../utils/src/gpsMath.hpp"
#include <Arduino.h>
#include <algorithm>
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

  if (len < 8) {
    Serial.println(
        "Route data too short (need at least 8 bytes for start point)");
    return;
  }

  // Log hex dump of first 32 bytes for debugging
  Serial.print("Route data hex dump (first 32 bytes): ");
  for (size_t i = 0; i < std::min(len, (size_t)32); i++) {
    Serial.printf("%02X ", data[i]);
  }
  Serial.println();

  // Read start point (8 bytes: 4 lat + 4 lon, little-endian)
  int32_t lat, lon;
  memcpy(&lat, data, 4);
  memcpy(&lon, data + 4, 4);

  points.push_back({lat, lon});
  Serial.printf("Route start point: lat=%d (%.6f°), lon=%d (%.6f°)\n", lat,
                lat / 1000000.0, lon, lon / 1000000.0);

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
  if (points.size() > 1) {
    const auto &last = points.back();
    Serial.printf("Route end point: lat=%d (%.6f°), lon=%d (%.6f°)\n", last.lat,
                  last.lat / 1000000.0, last.lon, last.lon / 1000000.0);
  }
}

void RouteOverlay::clear() {
  points.clear();
  Serial.println("Route overlay cleared");
}

#ifndef DEG2RAD
#define DEG2RAD(a) ((a) / (180.0 / M_PI))
#endif

int16_t RouteOverlay::geoToScreenX(int32_t lonMicro, int32_t centerMercatorX,
                                   uint8_t zoom, int16_t screenWidth) {
  // Convert microdegrees to degrees
  double lon = lonMicro / 1000000.0;

  // Use the exact same projection as maps.cpp: lon2x(lon) = DEG2RAD(lon) *
  // EARTH_RADIUS
  double worldX = DEG2RAD(lon) * EARTH_RADIUS;
  double centerWorldX = (double)centerMercatorX;

  // Transform to screen space using the same logic as Maps::toScreenCoord
  // Transform to screen space using the same logic as Maps::toScreenCoord
  // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
  int16_t screenX;
  if (zoom == 0) {
    screenX =
        (int16_t)(round((worldX - centerWorldX) * 2.0) + (screenWidth / 2.0));
  } else if (zoom == 1) {
    screenX =
        (int16_t)(round((worldX - centerWorldX) * 1.5) + (screenWidth / 2.0));
  } else {
    int divisor = zoom - 1;
    screenX = (int16_t)(round((worldX - centerWorldX) / divisor) +
                        (screenWidth / 2.0));
  }

  return screenX;
}

int16_t RouteOverlay::geoToScreenY(int32_t latMicro, int32_t centerMercatorY,
                                   uint8_t zoom, int16_t screenHeight,
                                   int16_t screenWidth) {
  // Convert microdegrees to degrees
  double lat = latMicro / 1000000.0;

  // Use the exact same projection as maps.cpp: lat2y(lat) =
  // log(tan(DEG2RAD(lat) / 2 + M_PI / 4)) * EARTH_RADIUS
  double worldY = log(tan(DEG2RAD(lat) / 2.0 + M_PI / 4.0)) * EARTH_RADIUS;
  double centerWorldY = (double)centerMercatorY;

  // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
  int16_t screenY;
  if (zoom == 0) {
    screenY =
        (int16_t)(round(-(worldY - centerWorldY) * 2.0) + (screenHeight / 2.0));
  } else if (zoom == 1) {
    screenY =
        (int16_t)(round(-(worldY - centerWorldY) * 1.5) + (screenHeight / 2.0));
  } else {
    int divisor = zoom - 1;
    screenY = (int16_t)(round(-(worldY - centerWorldY) / divisor) +
                        (screenHeight / 2.0));
  }

  return screenY;
}

void RouteOverlay::drawLineSegment(uint16_t *buf, int32_t bufW, int32_t bufH,
                                   uint32_t stride, int16_t x1, int16_t y1,
                                   int16_t x2, int16_t y2, uint16_t color) {
  // Bresenham's line algorithm with bounds checking
  int dx = abs(x2 - x1), sx = x1 < x2 ? 1 : -1;
  int dy = -abs(y2 - y1), sy = y1 < y2 ? 1 : -1;
  int err = dx + dy, e2;

  while (true) {
    // Bounds check before writing
    if (x1 >= 0 && x1 < bufW && y1 >= 0 && y1 < bufH) {
      buf[y1 * stride + x1] = color;
    }

    if (x1 == x2 && y1 == y2)
      break;

    e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x1 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y1 += sy;
    }
  }
}

void RouteOverlay::drawThickLine(uint16_t *buf, int32_t bufW, int32_t bufH,
                                 uint32_t stride, int16_t x1, int16_t y1,
                                 int16_t x2, int16_t y2, uint16_t color,
                                 int16_t thickness) {
  // Calculate line direction
  float dx = x2 - x1;
  float dy = y2 - y1;
  float len = sqrtf(dx * dx + dy * dy);

  if (len < 1.0f) {
    // Just draw a point
    if (x1 >= 0 && x1 < bufW && y1 >= 0 && y1 < bufH) {
      buf[y1 * stride + x1] = color;
    }
    return;
  }

  // Normalize direction
  dx /= len;
  dy /= len;

  // Perpendicular direction for thickness
  float px = -dy;
  float py = dx;

  // Draw multiple parallel lines for thickness
  int16_t halfThick = thickness / 2;
  for (int16_t t = -halfThick; t <= halfThick; t++) {
    int16_t ox = (int16_t)(px * t);
    int16_t oy = (int16_t)(py * t);

    drawLineSegment(buf, bufW, bufH, stride, x1 + ox, y1 + oy, x2 + ox, y2 + oy,
                    color);
  }
}

void RouteOverlay::drawRoute(lv_obj_t *canvas, int32_t centerMercatorX,
                             int32_t centerMercatorY, uint8_t zoom,
                             uint16_t mapScrWidth, uint16_t mapScrHeight,
                             double rotationRad) {
  if (points.size() < 2) {
    Serial.println("RouteOverlay: Not enough points to draw (need >= 2)");
    return; // Need at least 2 points to draw a line
  }

  Serial.printf("RouteOverlay::drawRoute: centerMerc=(%d,%d) zoom=%d "
                "points=%d rot=%.2frad\n",
                centerMercatorX, centerMercatorY, zoom, points.size(),
                rotationRad);

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

  Serial.printf("RouteOverlay: Canvas buffer W=%d H=%d stride=%d\n", bufW, bufH,
                stride);

  // Pre-calculate rotation values
  double cosA = cos(rotationRad);
  double sinA = sin(rotationRad);
  int16_t halfW = bufW / 2;
  int16_t halfH = bufH / 2;

  int drawnCount = 0;
  // Draw route segments
  for (size_t i = 0; i < points.size() - 1; i++) {
    // Convert geographic coordinates to screen pixels
    int16_t x1 = geoToScreenX(points[i].lon, centerMercatorX, zoom, bufW);
    int16_t y1 = geoToScreenY(points[i].lat, centerMercatorY, zoom, bufH, bufW);
    int16_t x2 = geoToScreenX(points[i + 1].lon, centerMercatorX, zoom, bufW);
    int16_t y2 =
        geoToScreenY(points[i + 1].lat, centerMercatorY, zoom, bufH, bufW);

    // Apply rotation transform if rotationRad is non-zero
    if (rotationRad != 0.0) {
      // Transform point 1
      double dx1 = x1 - halfW;
      double dy1 = y1 - halfH;
      x1 = (int16_t)(dx1 * cosA - dy1 * sinA + halfW);
      y1 = (int16_t)(dx1 * sinA + dy1 * cosA + halfH);

      // Transform point 2
      double dx2 = x2 - halfW;
      double dy2 = y2 - halfH;
      x2 = (int16_t)(dx2 * cosA - dy2 * sinA + halfW);
      y2 = (int16_t)(dx2 * sinA + dy2 * cosA + halfH);
    }

    // LOGGING: Debug Center Offset for the first segment
    if (i == 0) {
      ESP_LOGI(
          "RouteOverlay",
          "DEBUG_OFFSET: Center(%d,%d) StartPixel(%d,%d) Diff(%d,%d) Rot(%.2f)",
          halfW, halfH, x1, y1, x1 - halfW, y1 - halfH, rotationRad);
    }

    // Log first few segments for debugging
    if (i < 3) {
      ESP_LOGI("RouteOverlay",
               "  Segment %d: (%.6f,%.6f)->(%.6f,%.6f) screen(%d,%d)->(%d,%d)",
               (int)i, points[i].lat / 1000000.0, points[i].lon / 1000000.0,
               points[i + 1].lat / 1000000.0, points[i + 1].lon / 1000000.0, x1,
               y1, x2, y2);
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
    int16_t routeLineWidth =
        std::max<int16_t>(1, (int16_t)mapRenderSettings.routeLineWidth);
    drawThickLine(buf, bufW, bufH, stride, x1, y1, x2, y2, ROUTE_COLOR,
                  routeLineWidth);
    drawnCount++;
  }

  ESP_LOGI("RouteOverlay", "Route drawn: %d/%d segments (some off-screen)",
           drawnCount, (int)points.size() - 1);
}
