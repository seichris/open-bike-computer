#pragma once
#include "../maps/src/map_projection.hpp"
namespace social_riders {
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
