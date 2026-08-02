/**
 * @file route_overlay.cpp
 * @brief Route overlay implementation for iOS route geometry rendering
 *
 * Parses compressed route data from BLE and renders as thick blue line
 * overlay on the vector map canvas.
 */

#include "route_overlay.hpp"

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 1
#endif
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

void RouteOverlay::drawThickLine(uint16_t *buf, int32_t bufW, int32_t bufH,
                                 uint32_t stride, int16_t x1, int16_t y1,
                                 int16_t x2, int16_t y2, uint16_t color,
                                 int16_t thickness) {
  const uint8_t lineWidth =
      static_cast<uint8_t>(std::max<int16_t>(1, thickness));
  line_rasterizer::drawFilledLine(buf, bufW, bufH, stride, x1, y1, x2, y2,
                                  color, lineWidth);
}

void RouteOverlay::drawRoute(
    lv_obj_t *canvas, const map_projection::Projection &projection) {
  if (points.size() < 2) {
    Serial.println("RouteOverlay: Not enough points to draw (need >= 2)");
    return; // Need at least 2 points to draw a line
  }

#if FIRMWARE_DIAGNOSTICS
  Serial.printf("RouteOverlay::drawRoute: zoom=%d points=%d rot=%.2frad "
                "mode=%s\n",
                projection.config().zoom, points.size(),
                projection.config().rotationRad,
                projection.isBirdsEye() ? "birds-eye" : "flat");
#endif

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
#if FIRMWARE_DIAGNOSTICS
  Serial.printf("RouteOverlay: Canvas buffer W=%d H=%d stride=%d\n", bufW, bufH,
                stride);
#endif

  int drawnCount = 0;
  // Draw route segments
  for (size_t i = 0; i < points.size() - 1; i++) {
    auto worldPoint = [](const GeoPoint &point) {
      const double lon = point.lon / 1000000.0;
      const double lat = point.lat / 1000000.0;
      return map_transform::WorldPoint{
          DEG2RAD(lon) * EARTH_RADIUS,
          log(tan(DEG2RAD(lat) / 2.0 + M_PI / 4.0)) * EARTH_RADIUS};
    };
    auto ground1 = projection.groundForWorld(worldPoint(points[i]));
    auto ground2 = projection.groundForWorld(worldPoint(points[i + 1]));
    if (!projection.clipSegmentToNearPlane(ground1, ground2))
      continue;
    const auto projected1 = projection.projectGround(ground1);
    const auto projected2 = projection.projectGround(ground2);
    if (!projected1.valid || !projected2.valid)
      continue;
    const double x1 = projected1.x;
    const double y1 = projected1.y;
    const double x2 = projected2.x;
    const double y2 = projected2.y;

    // LOGGING: Debug Center Offset for the first segment
    if (i == 0) {
      ESP_LOGI(
          "RouteOverlay",
          "DEBUG_OFFSET: Center(%d,%d) StartPixel(%.1f,%.1f) "
          "Diff(%.1f,%.1f) Rot(%.2f)",
          static_cast<int>(projection.anchorX()),
          static_cast<int>(projection.anchorY()), x1, y1,
          x1 - projection.anchorX(), y1 - projection.anchorY(),
          projection.config().rotationRad);
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
    const uint8_t baseRouteLineWidth = static_cast<uint8_t>(std::min<int16_t>(
        std::max<int16_t>(
            1, (int16_t)currentMapStyleSettings().routeLineWidth),
        48));
    const uint8_t routeLineWidth = projection.scaledLineWidth(
        baseRouteLineWidth,
        (projected1.depthScale + projected2.depthScale) / 2.0, 48);
    drawThickLine(buf, bufW, bufH, stride,
                  static_cast<int16_t>(map_transform::quantizePixel(x1)),
                  static_cast<int16_t>(map_transform::quantizePixel(y1)),
                  static_cast<int16_t>(map_transform::quantizePixel(x2)),
                  static_cast<int16_t>(map_transform::quantizePixel(y2)),
                  navigation_visual_style::ROUTE_BLUE_RGB565,
                  routeLineWidth);
    drawnCount++;
  }

  ESP_LOGI("RouteOverlay", "Route drawn: %d/%d segments (some off-screen)",
           drawnCount, (int)points.size() - 1);
}
