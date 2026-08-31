#include "mapPoiLayout.hpp"

#include "../../ble_navigation/map_profile_protocol.hpp"

#include <algorithm>
#include <cmath>
#include <tuple>

namespace map_poi_layout {
namespace {

uint8_t semanticPriority(map_poi_block::Category category, bool guidance) {
  using Category = map_poi_block::Category;
  if (guidance) {
    switch (category) {
    case Category::BicycleServices:
      return 0;
    case Category::GasStations:
      return 1;
    case Category::PublicToilets:
      return 2;
    case Category::RestaurantsAndCafes:
      return 3;
    case Category::Shops:
      return 4;
    }
  }
  switch (category) {
  case Category::BicycleServices:
    return 0;
  case Category::RestaurantsAndCafes:
    return 1;
  case Category::PublicToilets:
    return 2;
  case Category::GasStations:
    return 3;
  case Category::Shops:
    return 4;
  }
  return 5;
}

bool intersects(float leftX, float leftY, float leftWidth, float leftHeight,
                float rightX, float rightY, float rightWidth,
                float rightHeight) {
  return std::fabs(leftX - rightX) * 2.0F < leftWidth + rightWidth &&
         std::fabs(leftY - rightY) * 2.0F < leftHeight + rightHeight;
}

} // namespace

uint32_t visibilityBit(map_poi_block::Category category) {
  using namespace map_profile_protocol;
  switch (category) {
  case map_poi_block::Category::Shops:
    return VISIBILITY_POI_SHOPS;
  case map_poi_block::Category::RestaurantsAndCafes:
    return VISIBILITY_POI_RESTAURANTS_AND_CAFES;
  case map_poi_block::Category::PublicToilets:
    return VISIBILITY_POI_PUBLIC_TOILETS;
  case map_poi_block::Category::GasStations:
    return VISIBILITY_POI_GAS_STATIONS;
  case map_poi_block::Category::BicycleServices:
    return VISIBILITY_POI_BICYCLE_SERVICES;
  }
  return 0;
}

bool better(const Candidate &left, const Candidate &right, bool guidance) {
  return std::make_tuple(semanticPriority(left.category, guidance), left.rank,
                         left.riderDistanceSquared, left.blockOrder,
                         left.recordOrder) <
         std::make_tuple(semanticPriority(right.category, guidance), right.rank,
                         right.riderDistanceSquared, right.blockOrder,
                         right.recordOrder);
}

void retainBounded(MapPoiLayoutVector<Candidate> &candidates,
                   const Candidate &candidate, bool guidance,
                   Diagnostics *diagnostics) {
  if (diagnostics != nullptr)
    ++diagnostics->gathered;
  if (candidates.size() < kMaximumCandidates) {
    candidates.push_back(candidate);
    return;
  }
  size_t worst = 0;
  for (size_t index = 1; index < candidates.size(); ++index)
    if (better(candidates[worst], candidates[index], guidance))
      worst = index;
  if (better(candidate, candidates[worst], guidance))
    candidates[worst] = candidate;
  if (diagnostics != nullptr)
    ++diagnostics->capacityDeferred;
}

MapPoiLayoutVector<Placement>
place(MapPoiLayoutVector<Candidate> candidates,
      map_label_layout::Bounds screen, bool guidance,
      const MapLabelLayoutVector<map_label_layout::ReservedRegion> &reserved,
      Diagnostics *diagnostics) {
  Diagnostics local;
  local.gathered = candidates.size();
  std::stable_sort(candidates.begin(), candidates.end(),
                   [&](const Candidate &left, const Candidate &right) {
                     return better(left, right, guidance);
                   });
  const size_t maximum =
      guidance ? kMaximumGuidancePlacements : kMaximumMapPlacements;
  MapPoiLayoutVector<Placement> placements;
  placements.reserve(std::min(maximum, candidates.size()));
  const float paddedSize = kIconSize + 2.0F * kIconPadding;
  for (size_t index = 0; index < candidates.size(); ++index) {
    const Candidate &candidate = candidates[index];
    if (!std::isfinite(candidate.x) || !std::isfinite(candidate.y) ||
        candidate.x - paddedSize * 0.5F < 0 ||
        candidate.y - paddedSize * 0.5F < 0 ||
        candidate.x + paddedSize * 0.5F >= screen.width ||
        candidate.y + paddedSize * 0.5F >= screen.height) {
      ++local.offscreen;
      continue;
    }
    bool collision = false;
    for (const auto &region : reserved) {
      if (region.width > 0 && region.height > 0 &&
          intersects(candidate.x, candidate.y, paddedSize, paddedSize,
                     region.centerX, region.centerY, region.width,
                     region.height)) {
        collision = true;
        break;
      }
    }
    if (!collision) {
      for (const Placement &placement : placements) {
        if (intersects(candidate.x, candidate.y, paddedSize, paddedSize,
                       placement.candidate.x, placement.candidate.y,
                       paddedSize, paddedSize)) {
          collision = true;
          break;
        }
      }
    }
    if (collision) {
      ++local.collisionRejected;
      continue;
    }
    if (placements.size() >= maximum) {
      local.capacityDeferred += candidates.size() - index;
      break;
    }
    placements.push_back({candidate});
    const size_t category = static_cast<size_t>(candidate.category) - 1U;
    ++local.acceptedCategories[category];
  }
  local.accepted = placements.size();
  if (diagnostics != nullptr) {
    const size_t gatheredBefore = diagnostics->gathered;
    const size_t capacityBefore = diagnostics->capacityDeferred;
    const size_t offscreenBefore = diagnostics->offscreen;
    *diagnostics = local;
    diagnostics->gathered = std::max(gatheredBefore, local.gathered);
    diagnostics->capacityDeferred += capacityBefore;
    diagnostics->offscreen += offscreenBefore;
  }
  return placements;
}

} // namespace map_poi_layout
