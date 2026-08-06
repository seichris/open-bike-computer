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

#ifndef DEG2RAD
#define DEG2RAD(a) ((a) / (180.0 / M_PI))
#endif

// Global instance
RouteOverlay routeOverlay;

namespace {

map_transform::WorldPoint routeWorldPoint(const GeoPoint &point) {
  const double lon = point.lon / 1000000.0;
  const double lat = point.lat / 1000000.0;
  return {DEG2RAD(lon) * EARTH_RADIUS,
          log(tan(DEG2RAD(lat) / 2.0 + M_PI / 4.0)) * EARTH_RADIUS};
}

} // namespace

void RouteOverlay::parseRouteData(const uint8_t *data, size_t len) {
  points.clear();
  revisionCounter++;
  liveProgressValid = false;
  liveProgress = 0.0;

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
  liveProgressValid = false;
  liveProgress = 0.0;
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
  double firstSegmentDistanceSq = DBL_MAX;

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
    if (i == 0) {
      firstSegmentDistanceSq = distanceSq;
    }
    if (distanceSq < bestDistanceSq) {
      bestDistanceSq = distanceSq;
      bestSegment = i;
    }
  }

  if (bestDistanceSq == DBL_MAX) {
    return false;
  }

  // Geometry windows start with the rider's current route position. Keep the
  // first segment while the rider is still close to it, even if a later turn
  // is geometrically almost as close. This prevents a course-up rotation from
  // anticipating a corner because the outgoing segment is visible ahead. Once
  // the rider has left the first segment by more than the GPS tolerance, the
  // nearest-segment search naturally advances to the next segment.
  constexpr double kHeadingContinuityToleranceMeters = 8.0;
  constexpr double kMetersPerDegree = 111320.0;
  const double continuityToleranceDegrees =
      kHeadingContinuityToleranceMeters / kMetersPerDegree;
  if (firstSegmentDistanceSq != DBL_MAX &&
      firstSegmentDistanceSq <=
          continuityToleranceDegrees * continuityToleranceDegrees) {
    bestSegment = 0;
  }

  const double segmentHeading =
      calcCourse(points[bestSegment].lat / 1000000.0,
                 points[bestSegment].lon / 1000000.0,
                 points[bestSegment + 1].lat / 1000000.0,
                 points[bestSegment + 1].lon / 1000000.0);
  headingDeg = static_cast<uint16_t>(round(segmentHeading)) % 360;
  return true;
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

void RouteOverlay::drawLiveHead(
    lv_obj_t *canvas, const map_projection::Projection &projection,
    map_transform::WorldPoint presentedWorld) {
  if (canvas == nullptr || points.size() < 2)
    return;

  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  if (draw_buf == nullptr || draw_buf->data == nullptr ||
      draw_buf->header.cf != LV_COLOR_FORMAT_RGB565A8) {
    return;
  }

  const int32_t bufW = draw_buf->header.w;
  const int32_t bufH = draw_buf->header.h;
  const uint32_t colorStride = draw_buf->header.stride / sizeof(uint16_t);
  const uint32_t alphaStride = colorStride;
  const size_t colorBytes = static_cast<size_t>(draw_buf->header.stride) *
                            static_cast<size_t>(bufH);
  const size_t alphaBytes = static_cast<size_t>(alphaStride) *
                            static_cast<size_t>(bufH);
  memset(draw_buf->data, 0, colorBytes + alphaBytes);

  size_t closestSegment = 0;
  double closestT = 0.0;
  double bestDistanceSq = DBL_MAX;
  for (size_t i = 0; i + 1 < points.size(); ++i) {
    const auto start = routeWorldPoint(points[i]);
    const auto end = routeWorldPoint(points[i + 1]);
    const double segmentX = end.x - start.x;
    const double segmentY = end.y - start.y;
    const double segmentLengthSq =
        (segmentX * segmentX) + (segmentY * segmentY);
    if (segmentLengthSq <= 0.0)
      continue;

    double t = ((presentedWorld.x - start.x) * segmentX +
                (presentedWorld.y - start.y) * segmentY) /
               segmentLengthSq;
    t = std::max(0.0, std::min(1.0, t));
    const double closestX = start.x + segmentX * t;
    const double closestY = start.y + segmentY * t;
    const double dx = presentedWorld.x - closestX;
    const double dy = presentedWorld.y - closestY;
    const double distanceSq = (dx * dx) + (dy * dy);
    if (distanceSq < bestDistanceSq) {
      bestDistanceSq = distanceSq;
      closestSegment = i;
      closestT = t;
    }
  }
  if (bestDistanceSq == DBL_MAX)
    return;

  double progress = static_cast<double>(closestSegment) + closestT;
  if (liveProgressValid && progress < liveProgress)
    progress = liveProgress;
  else
    liveProgress = progress;
  liveProgressValid = true;

  closestSegment = std::min(
      static_cast<size_t>(std::floor(progress)), points.size() - 2);
  closestT = std::max(0.0, std::min(1.0, progress - closestSegment));
  const auto routeStart = routeWorldPoint(points[closestSegment]);
  const auto routeEnd = routeWorldPoint(points[closestSegment + 1]);
  const map_transform::WorldPoint projectedRoutePoint = {
      routeStart.x + (routeEnd.x - routeStart.x) * closestT,
      routeStart.y + (routeEnd.y - routeStart.y) * closestT};

  const uint8_t baseRouteLineWidth = static_cast<uint8_t>(std::min<int16_t>(
      std::max<int16_t>(1, (int16_t)currentMapStyleSettings().routeLineWidth),
      48));
  auto drawSegment = [&](map_transform::WorldPoint first,
                         map_transform::WorldPoint second) {
    auto groundFirst = projection.groundForWorld(first);
    auto groundSecond = projection.groundForWorld(second);
    if (!projection.clipSegmentToNearPlane(groundFirst, groundSecond))
      return;
    const auto projectedFirst = projection.projectGround(groundFirst);
    const auto projectedSecond = projection.projectGround(groundSecond);
    if (!projectedFirst.valid || !projectedSecond.valid)
      return;

    const int16_t firstX = static_cast<int16_t>(
        map_transform::quantizePixel(projectedFirst.x));
    const int16_t firstY = static_cast<int16_t>(
        map_transform::quantizePixel(projectedFirst.y));
    const int16_t secondX = static_cast<int16_t>(
        map_transform::quantizePixel(projectedSecond.x));
    const int16_t secondY = static_cast<int16_t>(
        map_transform::quantizePixel(projectedSecond.y));

    const int16_t margin = 50;
    if ((firstX < -margin && secondX < -margin) ||
        (firstX >= bufW + margin && secondX >= bufW + margin) ||
        (firstY < -margin && secondY < -margin) ||
        (firstY >= bufH + margin && secondY >= bufH + margin)) {
      return;
    }

    const int16_t routeLineWidth = projection.scaledLineWidth(
        baseRouteLineWidth,
        (projectedFirst.depthScale + projectedSecond.depthScale) / 2.0, 48);
    drawThickLine(
        reinterpret_cast<uint16_t *>(draw_buf->data), bufW, bufH, colorStride,
        firstX, firstY, secondX, secondY,
        navigation_visual_style::ROUTE_BLUE_RGB565, routeLineWidth);

    // Only inspect the dirty line rectangle. A full-screen color scan at 30 Hz
    // would make the presentation loop compete with the vector renderer.
    auto *colors = reinterpret_cast<uint16_t *>(draw_buf->data);
    auto *alpha = static_cast<uint8_t *>(draw_buf->data) + colorBytes;
    const int32_t dirtyMargin = static_cast<int32_t>(routeLineWidth) + 2;
    const int32_t minX = std::max<int32_t>(
        0, std::min<int32_t>(firstX, secondX) - dirtyMargin);
    const int32_t maxX = std::min<int32_t>(
        bufW - 1, std::max<int32_t>(firstX, secondX) + dirtyMargin);
    const int32_t minY = std::max<int32_t>(
        0, std::min<int32_t>(firstY, secondY) - dirtyMargin);
    const int32_t maxY = std::min<int32_t>(
        bufH - 1, std::max<int32_t>(firstY, secondY) + dirtyMargin);
    for (int32_t y = minY; y <= maxY; ++y) {
      for (int32_t x = minX; x <= maxX; ++x) {
        const size_t index = static_cast<size_t>(y) * colorStride + x;
        if (colors[index] == navigation_visual_style::ROUTE_BLUE_RGB565)
          alpha[static_cast<size_t>(y) * alphaStride + x] = 255;
      }
    }
  };

  // Start at the exact presented marker position, connect to the nearest
  // route point when GPS is slightly off the polyline, then draw only forward
  // route geometry. This removes both stale leading gaps and trailing tails.
  drawSegment(presentedWorld, projectedRoutePoint);
  drawSegment(projectedRoutePoint, routeEnd);
  for (size_t i = closestSegment + 1; i + 1 < points.size(); ++i) {
    drawSegment(routeWorldPoint(points[i]), routeWorldPoint(points[i + 1]));
  }

}
