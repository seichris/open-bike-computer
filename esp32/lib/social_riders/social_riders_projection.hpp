#pragma once
#include "../maps/src/map_projection.hpp"
#include <algorithm>
#include <cmath>
namespace social_riders {
struct RelativeLocation {
  bool valid = false;
  double meters = 0;
  double east = 0;
  double north = 0;
};

inline bool validCoordinate(double latitude, double longitude) {
  return std::isfinite(latitude) && std::isfinite(longitude) &&
         std::abs(latitude) <= 90 && std::abs(longitude) <= 180;
}

// Spherical inverse, independent of Mercator tiles and their latitude limits.
// Trigonometric longitude differences also take the short antimeridian path.
inline RelativeLocation relativeLocation(double fromLat, double fromLon,
                                         double toLat, double toLon) {
  if (!validCoordinate(fromLat, fromLon) || !validCoordinate(toLat, toLon))
    return {};
  constexpr double radians = 3.14159265358979323846 / 180;
  const double a = fromLat * radians, b = toLat * radians;
  const double dl = (toLon - fromLon) * radians;
  const double hav = std::pow(std::sin((b-a)/2), 2) +
      std::cos(a) * std::cos(b) * std::pow(std::sin(dl/2), 2);
  const double meters = 6371008.8 * 2 *
      std::asin(std::sqrt(std::max(0.0, std::min(1.0, hav))));
  const double east = std::cos(b) * std::sin(dl);
  const double north = std::cos(a) * std::sin(b) -
      std::sin(a) * std::cos(b) * std::cos(dl);
  const double norm = std::hypot(east, north);
  // Coincident friends belong in the center. An antipode has no unique bearing.
  if (meters < 0.01) return {true, meters, 0, 0};
  if (norm < 1e-12) return {};
  return {true, meters, east / norm, north / norm};
}

struct ScreenDirection { double x, y; };
inline ScreenDirection screenDirection(const RelativeLocation &location,
                                       double headingDegrees) {
  const double heading = headingDegrees * 3.14159265358979323846 / 180;
  return {location.east * std::cos(heading) - location.north * std::sin(heading),
          -location.north * std::cos(heading) - location.east * std::sin(heading)};
}

// Clip the ray from the visible screen center, including off-center navigation
// and bird's-eye near-plane cases. Distances still use the rider's actual GPS.
inline map_projection::ProjectedPoint projectRider(
    const map_projection::Projection &projection,
    map_transform::WorldPoint world, double centerX, double centerY) {
  auto result=projection.projectWorld(world);
  if(result.valid)return result;
  auto start=projection.groundForScreen(centerX,centerY);
  auto end=projection.groundForWorld(world);
  if(!projection.clipSegmentToNearPlane(start,end))return {};
  return projection.projectGround(end);
}
}
