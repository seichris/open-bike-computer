#include "../../lib/maps/src/map_projection.hpp"

#include <cassert>
#include <cmath>
#include <cstdint>

namespace {

constexpr double kPi = 3.14159265358979323846;

map_projection::Projection makeProjection(
    map_projection::Mode mode, uint16_t width = 466,
    uint16_t height = 466, uint8_t zoom = 3, double rotation = 0.0) {
  map_projection::Config config;
  config.viewportWidth = width;
  config.viewportHeight = height;
  config.worldOrigin = {100000.0, 200000.0};
  config.zoom = zoom;
  config.rotationRad = rotation;
  config.anchorX = width / 2;
  config.anchorY = mode == map_projection::Mode::BirdsEye
                       ? map_projection::birdsEyeAnchorY(height)
                       : height / 2;
  config.mode = mode;
  return map_projection::Projection(config);
}

void assertNear(double actual, double expected, double tolerance = 1e-8) {
  assert(std::fabs(actual - expected) <= tolerance);
}

void assertFlatParity() {
  for (uint8_t zoom = 0; zoom <= 5; ++zoom) {
    for (const double rotation : {0.0, -0.7, 1.2}) {
      auto projection = makeProjection(map_projection::Mode::Flat, 466, 366,
                                       zoom, rotation);
      for (const map_transform::WorldPoint point : {
               map_transform::WorldPoint{100000.0, 200000.0},
               map_transform::WorldPoint{100123.0, 199944.0},
               map_transform::WorldPoint{99831.0, 200412.0}}) {
        const auto expectedDelta = map_transform::worldToScreen(
            {point.x - 100000.0, point.y - 200000.0}, zoom, rotation);
        const auto projected = projection.projectWorld(point);
        assert(projected.valid);
        assert(map_transform::quantizePixel(projected.x) ==
               233 + map_transform::quantizePixel(expectedDelta.x));
        assert(map_transform::quantizePixel(projected.y) ==
               183 + map_transform::quantizePixel(expectedDelta.y));
        assertNear(projected.depthScale, 1.0);
      }
    }
  }
}

void assertPerspectiveBehavior() {
  const auto projection = makeProjection(map_projection::Mode::BirdsEye);
  const auto center = projection.projectWorld({100000.0, 200000.0});
  assert(center.valid);
  assertNear(center.x, projection.anchorX());
  assertNear(center.y, projection.anchorY());

  const auto near = projection.projectGround({100.0, 20.0});
  const auto far = projection.projectGround({100.0, 200.0});
  assert(near.valid && far.valid);
  assert(far.y < near.y);
  assert(std::fabs(far.x - projection.anchorX()) <
         std::fabs(near.x - projection.anchorX()));
  assert(far.depthScale < near.depthScale);

  const auto behind = projection.projectGround({0.0, -100.0});
  assert(behind.valid);
  assert(behind.depthScale > 1.0);
  assert(behind.depthScale <= 1.35);
  const auto invalid = projection.projectGround(
      {0.0, projection.nearPlaneForward() - 1.0});
  assert(!invalid.valid);
}

void assertClippingAndInverseBounds() {
  const auto projection = makeProjection(map_projection::Mode::BirdsEye);
  map_projection::GroundPoint start{30.0,
                                    projection.nearPlaneForward() - 100.0};
  map_projection::GroundPoint end{50.0,
                                  projection.nearPlaneForward() + 100.0};
  assert(projection.clipSegmentToNearPlane(start, end));
  assertNear(start.forward, projection.nearPlaneForward());
  assertNear(start.lateral, 40.0);
  assert(projection.projectGround(start).valid);

  map_projection::GroundPoint rejectedStart{
      0.0, projection.nearPlaneForward() - 2.0};
  map_projection::GroundPoint rejectedEnd{
      1.0, projection.nearPlaneForward() - 1.0};
  assert(!projection.clipSegmentToNearPlane(rejectedStart, rejectedEnd));

  const std::vector<map_projection::GroundPoint> polygon = {
      {-20.0, projection.nearPlaneForward() - 20.0},
      {20.0, projection.nearPlaneForward() - 20.0},
      {20.0, projection.nearPlaneForward() + 20.0},
      {-20.0, projection.nearPlaneForward() + 20.0}};
  std::vector<map_projection::GroundPoint> clippedPolygon;
  map_projection::clipPolygonToNearPlane(projection, polygon,
                                         clippedPolygon);
  assert(clippedPolygon.size() == 4);
  for (const auto &point : clippedPolygon)
    assert(point.forward >= projection.nearPlaneForward());

  const auto bounds = projection.worldBounds(4.0);
  for (const double x : {0.0, 466.0}) {
    for (const double y : {0.0, 466.0}) {
      const auto world = projection.worldForGround(
          projection.groundForScreen(x, y));
      assert(world.x >= bounds.min.x && world.x <= bounds.max.x);
      assert(world.y >= bounds.min.y && world.y <= bounds.max.y);
    }
  }
}

void assertRotationAndBlockBudget() {
  for (const auto &dimensions : {
           std::pair<uint16_t, uint16_t>{466, 366},
           std::pair<uint16_t, uint16_t>{466, 466},
           std::pair<uint16_t, uint16_t>{410, 430},
           std::pair<uint16_t, uint16_t>{410, 502}}) {
    for (uint8_t zoom = 1; zoom <= 5; ++zoom) {
      for (int heading = 0; heading < 360; heading += 5) {
        const auto projection = makeProjection(
            map_projection::Mode::BirdsEye, dimensions.first,
            dimensions.second, zoom, -heading * kPi / 180.0);
        const auto bounds = projection.worldBounds(4.0);
        assert(bounds.max.x - bounds.min.x < 4096.0);
        assert(bounds.max.y - bounds.min.y < 4096.0);
      }
    }
  }

  const auto rotated = makeProjection(map_projection::Mode::BirdsEye, 466,
                                      466, 3, -kPi / 2.0);
  const auto ahead = rotated.projectWorld({100000.0, 200100.0});
  assert(ahead.valid);
  assert(ahead.x < rotated.anchorX());
}

void assertLineWidthScaling() {
  const auto projection = makeProjection(map_projection::Mode::BirdsEye);
  assert(projection.scaledLineWidth(15, 0.6, 48) == 9);
  assert(projection.scaledLineWidth(1, 0.1, 48) == 1);
  assert(projection.scaledLineWidth(48, 1.35, 48) == 48);
}

} // namespace

int main() {
  assertFlatParity();
  assertPerspectiveBehavior();
  assertClippingAndInverseBounds();
  assertRotationAndBlockBudget();
  assertLineWidthScaling();
  return 0;
}
