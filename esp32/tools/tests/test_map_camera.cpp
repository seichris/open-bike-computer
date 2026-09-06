#include "../../lib/maps/src/mapCamera.hpp"
#include "../../lib/ble_navigation/map_profile_protocol.hpp"
#include "../../lib/ble_navigation/device_capabilities_protocol.hpp"
#include <cassert>
#include <cmath>

int main() {
  using namespace map_camera;
  using map_projection::Mode;
  for (auto mode : {Mode::Flat, Mode::BirdsEye}) {
    for (int height : {366, 466, 410}) {
      for (int tilt = 0; tilt <= 4; ++tilt) {
        for (double heading : {0.0, 90.0, 180.0, 270.0, 359.0, 1.0}) {
          map_projection::Config config;
          config.viewportWidth = 658;
          config.viewportHeight = height + 192;
          config.anchorX = 329;
          config.anchorY = 96 + (mode == Mode::BirdsEye
              ? map_projection::birdsEyeAnchorY(height) : height / 2.0);
          config.mode = mode;
          config.worldOrigin = {10000, 20000};
          config.zoom = 3;
          config.rotationRad = -heading * map_presentation::kPi / 180;
          config.topEdgeScale = map_projection::birdsEyeTopEdgeScale(
              static_cast<map_projection::BirdsEyePerspective>(tilt));
          map_projection::Projection p(config);
          assert(std::fabs(map_presentation::signedHeadingDelta(
              0, markerAngle(p, config.worldOrigin, heading))) < 1e-6);
          const auto ground = p.groundForWorld({10050, 20030});
          const auto base = p.projectElevatedGround(ground, 0);
          const auto roof = p.projectElevatedGround(ground, 20);
          if (base.valid) {
            assert(roof.x == base.x);
            assert(roof.y < base.y);
          }
          const auto label = projectLabel(p, {99850, 20030}, {10150, 20070}, false);
          const auto along = projectLabel(p, {99850, 20030}, {10150, 20070}, true);
          assert(label.valid == along.valid);
          if (label.valid) {
            assert(label.angle == 0);
            assert(std::fabs(along.angle) <= map_presentation::kPi / 2);
            assert(label.x == along.x && label.y == along.y);
            const auto a = p.projectWorld({99850, 20030});
            const auto b = p.projectWorld({10150, 20070});
            if (a.valid && b.valid) {
              assert(std::fabs(label.x - (a.x + b.x) / 2) < 1e-8);
              assert(std::fabs(label.y - (a.y + b.y) / 2) < 1e-8);
            }
          }
          assert(!needsRefresh(p, config.worldOrigin, config.rotationRad));
          assert(needsRefresh(p, config.worldOrigin, config.rotationRad + 0.1));
          assert(needsRefresh(p, {10100, 20000}, config.rotationRad));
          auto different = config;
          different.rotationRad += 0.01;
          assert(projectionSignature(p) != projectionSignature(map_projection::Projection(different)));
          different = config;
          different.mode = mode == Mode::Flat ? Mode::BirdsEye : Mode::Flat;
          assert(projectionSignature(p) != projectionSignature(map_projection::Projection(different)));
        }
      }
    }
  }
  // Perspective rotation does not commute with rotating already projected pixels.
  map_projection::Config c;
  c.mode = Mode::BirdsEye;
  c.anchorX = 233; c.anchorY = 300;
  c.viewportWidth = c.viewportHeight = 466;
  map_projection::Projection first(c);
  c.rotationRad = map_presentation::kPi / 2;
  map_projection::Projection turned(c);
  const auto old = first.projectWorld({100, 100});
  const auto actual = turned.projectWorld({100, 100});
  const auto rotated = map_presentation::presentFramePoint(
      {old.x, old.y}, {233, 300}, {233, 300}, c.rotationRad);
  assert(std::hypot(actual.x - rotated.x, actual.y - rotated.y) > 1);

  assert(cropCovered(658, 658, 466, 466, 96, 16, true));
  assert(!cropCovered(594, 494, 466, 366, 64, 16, true));
  assert(cropCovered(598, 498, 466, 366, 66, 16, true));
  assert(cropCovered(694, 602, 502, 410, 96, 16, false));
  assert(!cropCovered(500, 410, 502, 410, 0, 16, false));

  PreparedScene scene;
  assert(!scene.covers(1, 0, 0, 10, 10));
  scene.prepared(1, -100, -100, 100, 100);
  assert(scene.covers(1, -20, -10, 40, 50));
  assert(!scene.covers(2, -20, -10, 40, 50));
  assert(!scene.covers(1, -101, -10, 40, 50));
  const auto generation = scene.generation;
  scene.invalidate();
  assert(!scene.covers(1, 0, 0, 10, 10));
  scene.prepared(2, -100, -100, 100, 100);
  assert(scene.generation == generation + 1);

  Lag lag;
  lag.observe(false, 1000000);
  assert(lag.age(2000000) == 0); // Static views do not expire.
  lag.observe(true, 100);
  lag.observe(true, 200); // Coalescing cannot forgive outstanding lag.
  assert(lag.age(601) == 501 && lag.expired(601));
  lag.reflected(150);
  assert(lag.age(601) == 451);
  lag.reflected(120); // Late old work cannot rewind reflected progress.
  assert(lag.age(601) == 451);
  lag.observe(false, 700);
  lag.observe(true, UINT32_MAX - 20);
  assert(lag.age(10) == 31);

  using namespace map_profile_protocol;
  assert(navigationRotation(-1) == 1 && navigationRotation(255) == 1);
  assert(navigationRotation(0) == 0 && navigationRotation(1) == 1);
  assert(!guidanceCourseUp(false, 1));
  assert(guidanceCourseUp(true, 0) == !STABLE_CAMERA_ENABLED);
  assert(guidanceCourseUp(true, 1));
  using device_capabilities_protocol::supportsMapNavigationOrientation;
  assert(!supportsMapNavigationOrientation(21, true));
  assert(supportsMapNavigationOrientation(22, true));
  assert(!supportsMapNavigationOrientation(22, false));
}
