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
#include "../maps/src/mapRouteGeometry.hpp"
#include "../maps/src/mapPresentation.hpp"
#include "../utils/src/line_rasterizer.hpp"
#include "../../utils/src/gpsMath.hpp"
#include <Arduino.h>
#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstring>
#include <utility>

// Global instance
RouteOverlay routeOverlay;

bool RouteOverlay::parseRouteData(const uint8_t *data, size_t len) try {
  std::vector<GeoPoint, PsramAllocator<GeoPoint>> parsed;
  if (data != nullptr && len >= 8) {
    parsed.reserve(1U + (len - 8U) / 4U);
    int32_t lat = 0;
    int32_t lon = 0;
    memcpy(&lat, data, 4);
    memcpy(&lon, data + 4, 4);
    parsed.push_back({lat, lon});

    size_t offset = 8;
    while (offset + 4 <= len) {
      int16_t dLat = 0;
      int16_t dLon = 0;
      memcpy(&dLat, data + offset, 2);
      memcpy(&dLon, data + offset + 2, 2);
      lat += dLat;
      lon += dLon;
      parsed.push_back({lat, lon});
      offset += 4;
    }
  }

  const size_t parsedCount = parsed.size();
  portENTER_CRITICAL(&routeMutex);
  points.swap(parsed);
  ++revisionCounter;
  portEXIT_CRITICAL(&routeMutex);

  if (data == nullptr || len < 8) {
    Serial.println(
        "Route data too short (need at least 8 bytes for start point)");
    return true;
  }
  Serial.printf("Route parsed: %u points from %u bytes\n",
                static_cast<unsigned>(parsedCount),
                static_cast<unsigned>(len));
  return true;
} catch (const std::bad_alloc &) {
  Serial.println("ROUTE_RESOURCE_REJECTED: preserving prior route");
  return false;
}

void RouteOverlay::clear() {
  std::vector<GeoPoint, PsramAllocator<GeoPoint>> released;
  portENTER_CRITICAL(&routeMutex);
  points.swap(released);
  ++revisionCounter;
  portEXIT_CRITICAL(&routeMutex);
  Serial.println("Route overlay cleared");
}

bool RouteOverlay::hasRoute() const {
  portENTER_CRITICAL(&routeMutex);
  const bool result = points.size() >= 2;
  portEXIT_CRITICAL(&routeMutex);
  return result;
}

size_t RouteOverlay::getPointCount() const {
  portENTER_CRITICAL(&routeMutex);
  const size_t result = points.size();
  portEXIT_CRITICAL(&routeMutex);
  return result;
}

uint32_t RouteOverlay::revision() const {
  portENTER_CRITICAL(&routeMutex);
  const uint32_t result = revisionCounter;
  portEXIT_CRITICAL(&routeMutex);
  return result;
}

bool RouteOverlay::headingNear(double lat, double lon,
                               uint16_t &headingDeg) const {
  const RouteSnapshot route = snapshot();
  if (!route.hasRoute())
    return false;

  const double cosLat = cos(DEG2RAD(lat));
  double bestDistanceSq = DBL_MAX;
  size_t bestSegment = 0;
  for (size_t i = 0; i + 1 < route.count; ++i) {
    const double lat1 = route.points[i].lat / 1000000.0;
    const double lon1 = route.points[i].lon / 1000000.0;
    const double lat2 = route.points[i + 1].lat / 1000000.0;
    const double lon2 = route.points[i + 1].lon / 1000000.0;
    const double x1 = (lon1 - lon) * cosLat;
    const double y1 = lat1 - lat;
    const double x2 = (lon2 - lon) * cosLat;
    const double y2 = lat2 - lat;
    const double segX = x2 - x1;
    const double segY = y2 - y1;
    const double segLenSq = (segX * segX) + (segY * segY);
    if (segLenSq <= 0.0)
      continue;
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
  if (bestDistanceSq == DBL_MAX)
    return false;

  const double segmentHeading =
      calcCourse(route.points[bestSegment].lat / 1000000.0,
                 route.points[bestSegment].lon / 1000000.0,
                 route.points[bestSegment + 1].lat / 1000000.0,
                 route.points[bestSegment + 1].lon / 1000000.0);
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

namespace {
map_transform::WorldPoint routeWorldPoint(const GeoPoint &point) {
  const double lon = point.lon / 1000000.0;
  const double lat = point.lat / 1000000.0;
  return {DEG2RAD(lon) * EARTH_RADIUS,
          log(tan(DEG2RAD(lat) / 2.0 + M_PI / 4.0)) * EARTH_RADIUS};
}
}

RouteSnapshot RouteOverlay::snapshot() const {
  RouteSnapshot result;
  portENTER_CRITICAL(&routeMutex);
  result.revision = revisionCounter;
  result.count = static_cast<uint16_t>(
      std::min(points.size(), static_cast<size_t>(ROUTE_SNAPSHOT_MAX_POINTS)));
  for (uint16_t index = 0; index < result.count; ++index)
    result.points[index] = points[index];
  portEXIT_CRITICAL(&routeMutex);
  return result;
}

namespace {

template <typename DrawSegment>
void drawRouteSnapshotImpl(
    const RouteSnapshot &snapshot,
    const map_projection::Projection &projection, uint8_t baseLineWidth,
    const map_transform::WorldPoint *presentedWorld,
    const RoutePresentationTransform *presentation, DrawSegment drawSegment) {
  if (!snapshot.hasRoute())
    return;

  std::array<map_transform::WorldPoint, ROUTE_SNAPSHOT_MAX_POINTS + 1> path{};
  size_t pathCount = 0;
  const auto pointAt = [&](size_t index) {
    return routeWorldPoint(snapshot.points[index]);
  };
  if (presentedWorld != nullptr) {
    size_t storedCount = 0;
    (void)map_route_geometry::emitAnchored(
        *presentedWorld, snapshot.count, pointAt, [&](auto point) {
          if (storedCount < path.size())
            path[storedCount++] = point;
        });
    pathCount = storedCount;
  } else {
    pathCount = snapshot.count;
    for (size_t index = 0; index < pathCount; ++index)
      path[index] = pointAt(index);
  }
  if (pathCount < 2)
    return;

  const uint8_t width = static_cast<uint8_t>(
      std::max<int>(1, std::min<int>(48, baseLineWidth)));
  const auto present = [&](double x, double y) {
    if (presentation == nullptr)
      return map_presentation::ScreenPoint{x, y};
    return map_presentation::presentFramePoint(
        {x, y},
        {presentation->inputPivotX, presentation->inputPivotY},
        {presentation->outputPivotX, presentation->outputPivotY},
        presentation->rotationRad);
  };

  for (size_t index = 0; index + 1 < pathCount; ++index) {
    auto ground1 = projection.groundForWorld(path[index]);
    auto ground2 = projection.groundForWorld(path[index + 1]);
    if (!projection.clipSegmentToNearPlane(ground1, ground2))
      continue;
    const auto projected1 = projection.projectGround(ground1);
    const auto projected2 = projection.projectGround(ground2);
    if (!projected1.valid || !projected2.valid)
      continue;
    const uint8_t lineWidth = projection.scaledLineWidth(
        width, (projected1.depthScale + projected2.depthScale) / 2.0, 48);
    const auto point1 = present(projected1.x, projected1.y);
    const auto point2 = present(projected2.x, projected2.y);
    drawSegment(
        static_cast<int16_t>(map_transform::quantizePixel(point1.x)),
        static_cast<int16_t>(map_transform::quantizePixel(point1.y)),
        static_cast<int16_t>(map_transform::quantizePixel(point2.x)),
        static_cast<int16_t>(map_transform::quantizePixel(point2.y)),
        lineWidth);
  }
}

} // namespace

void RouteOverlay::drawSnapshot(
    const RouteSnapshot &snapshot, map_surface::Rgb565Surface surface,
    const map_projection::Projection &projection, uint8_t baseLineWidth,
    const map_transform::WorldPoint *presentedWorld,
    const RoutePresentationTransform *presentation) {
  if (!surface.valid())
    return;
  drawRouteSnapshotImpl(
      snapshot, projection, baseLineWidth, presentedWorld, presentation,
      [&](int16_t x1, int16_t y1, int16_t x2, int16_t y2,
          uint8_t lineWidth) {
        line_rasterizer::drawFilledLine(
            surface.pixels, surface.width, surface.height,
            static_cast<uint32_t>(surface.stridePixels), x1, y1, x2, y2,
            navigation_visual_style::ROUTE_BLUE_RGB565, lineWidth);
      });
}

void RouteOverlay::drawSnapshot(
    const RouteSnapshot &snapshot, map_surface::Rgb565A8Surface surface,
    const map_projection::Projection &projection, uint8_t baseLineWidth,
    const map_transform::WorldPoint *presentedWorld,
    const RoutePresentationTransform *presentation) {
  if (!surface.valid())
    return;
  drawRouteSnapshotImpl(
      snapshot, projection, baseLineWidth, presentedWorld, presentation,
      [&](int16_t x1, int16_t y1, int16_t x2, int16_t y2,
          uint8_t lineWidth) {
        line_rasterizer::drawFilledLine(
            surface.pixels, surface.width, surface.height,
            static_cast<uint32_t>(surface.colorStridePixels), x1, y1, x2, y2,
            navigation_visual_style::ROUTE_BLUE_RGB565, lineWidth);
        line_rasterizer::drawFilledLine(
            surface.alpha, surface.width, surface.height,
            static_cast<uint32_t>(surface.alphaStrideBytes), x1, y1, x2, y2,
            uint8_t{255}, lineWidth);
      });
}

void RouteOverlay::drawRoute(
    lv_obj_t *canvas, const map_projection::Projection &projection) {
  if (canvas == nullptr)
    return;
  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
  if (drawBuffer == nullptr)
    return;
  map_surface::Rgb565Surface surface{
      reinterpret_cast<uint16_t *>(drawBuffer->data),
      static_cast<int32_t>(drawBuffer->header.w),
      static_cast<int32_t>(drawBuffer->header.h),
      static_cast<size_t>(drawBuffer->header.stride / sizeof(uint16_t))};
  drawSnapshot(snapshot(), surface, projection,
               static_cast<uint8_t>(std::min<int>(
                   48, std::max<int>(1,
                       currentMapStyleSettings().routeLineWidth))));
}
