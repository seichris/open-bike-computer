#include "mapPoiLayout.hpp"

#include "../../ble_navigation/map_profile_protocol.hpp"

#include <algorithm>
#include <array>
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

bool intersectsReserved(
    const Candidate &candidate,
    const MapLabelLayoutVector<map_label_layout::ReservedRegion> &reserved) {
  constexpr float paddedSize = kIconSize + 2.0F * kIconPadding;
  for (const auto &region : reserved) {
    if (region.width > 0 && region.height > 0 &&
        intersects(candidate.x, candidate.y, paddedSize, paddedSize,
                   region.centerX, region.centerY, region.width, region.height))
      return true;
  }
  return false;
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

bool fitsViewport(float x, float y, Viewport screen) {
  constexpr float margin = (kIconSize + 2.0F * kIconPadding) * 0.5F;
  const bool fits = std::isfinite(x) && std::isfinite(y) &&
      x >= margin && y >= margin &&
      x + margin < screen.width && y + margin < screen.height;
  if (!fits || !std::isfinite(screen.clipRadius) || screen.clipRadius < 0) return false;
  if (screen.clipRadius == 0) return true;
  const float dx = std::fabs(x - screen.width * 0.5F) + margin;
  const float dy = std::fabs(y - screen.height * 0.5F) + margin;
  return dx * dx + dy * dy < screen.clipRadius * screen.clipRadius;
}

void retainBounded(MapPoiLayoutVector<Candidate> &candidates,
                   const Candidate &candidate, Viewport screen,
                   bool guidance,
                   const MapLabelLayoutVector<map_label_layout::ReservedRegion>
                       &reserved,
                   Diagnostics *diagnostics) {
  if (diagnostics != nullptr)
    ++diagnostics->gathered;
  if (!fitsViewport(candidate.x, candidate.y, screen)) {
    if (diagnostics != nullptr) ++diagnostics->offscreen;
    return;
  }
  // Unrenderable high-priority POIs must not evict visible lower-priority POIs.
  if (intersectsReserved(candidate, reserved)) {
    if (diagnostics != nullptr) ++diagnostics->collisionRejected;
    return;
  }
  if (candidates.size() < kMaximumCandidates) {
    candidates.push_back(candidate);
    return;
  }
  // Truncating by priority alone let one dense category fill the pool before
  // collision, so other enabled categories vanished even where they would
  // fit. Each category keeps an equal share: one under its share displaces
  // the worst candidate of a category over its share. Placement order and
  // the placement cap are unchanged.
  constexpr size_t kCategoryShare = kMaximumCandidates / 5;
  std::array<size_t, 6> counts{};
  const auto slot = [&counts](map_poi_block::Category category) {
    return std::min<size_t>(static_cast<size_t>(category), counts.size() - 1);
  };
  for (const auto &kept : candidates)
    ++counts[slot(kept.category)];
  const size_t own = slot(candidate.category);
  const bool underShare = counts[own] < kCategoryShare;
  size_t worst = candidates.size();
  for (size_t index = 0; index < candidates.size(); ++index) {
    const size_t category = slot(candidates[index].category);
    if (counts[category] <= kCategoryShare && (underShare || category != own))
      continue;
    if (worst == candidates.size() ||
        better(candidates[worst], candidates[index], guidance))
      worst = index;
  }
  if (worst < candidates.size() &&
      (underShare || better(candidate, candidates[worst], guidance)))
    candidates[worst] = candidate;
  if (diagnostics != nullptr)
    ++diagnostics->capacityDeferred;
}

MapPoiLayoutVector<Placement>
place(MapPoiLayoutVector<Candidate> candidates,
      Viewport screen, bool guidance,
      const MapLabelLayoutVector<map_label_layout::ReservedRegion> &reserved,
      Diagnostics *diagnostics) {
  Diagnostics local;
  local.gathered = candidates.size();
  // At most 256 candidates: stable insertion sort needs no temporary heap
  // allocation or general-purpose merge-sort implementation in the OTA image.
  for (size_t index = 1; index < candidates.size(); ++index) {
    const Candidate candidate = candidates[index];
    size_t position = index;
    while (position > 0 &&
           better(candidate, candidates[position - 1], guidance)) {
      candidates[position] = candidates[position - 1];
      --position;
    }
    candidates[position] = candidate;
  }
  const size_t maximum =
      guidance ? kMaximumGuidancePlacements : kMaximumMapPlacements;
  MapPoiLayoutVector<Placement> placements;
  placements.reserve(std::min(maximum, candidates.size()));
  const float paddedSize = kIconSize + 2.0F * kIconPadding;
  for (size_t index = 0; index < candidates.size(); ++index) {
    const Candidate &candidate = candidates[index];
    if (!fitsViewport(candidate.x, candidate.y, screen)) {
      ++local.offscreen;
      continue;
    }
    bool collision = intersectsReserved(candidate, reserved);
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
    const size_t collisionsBefore = diagnostics->collisionRejected;
    *diagnostics = local;
    diagnostics->gathered = std::max(gatheredBefore, local.gathered);
    diagnostics->capacityDeferred += capacityBefore;
    diagnostics->offscreen += offscreenBefore;
    diagnostics->collisionRejected += collisionsBefore;
  }
  return placements;
}

} // namespace map_poi_layout
