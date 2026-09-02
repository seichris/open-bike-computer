#pragma once

#include "mapLabelLayout.hpp"
#include "mapPoiBlock.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T> using MapPoiLayoutVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapPoiLayoutVector = std::vector<T>;
#endif

namespace map_poi_layout {

constexpr size_t kMaximumCandidates = 256;
constexpr size_t kMaximumMapPlacements = 48;
constexpr size_t kMaximumGuidancePlacements = 32;
constexpr float kIconSize = 14.0F;
constexpr float kIconPadding = 3.0F;

struct Candidate {
  float x = 0;
  float y = 0;
  double riderDistanceSquared = 0;
  map_poi_block::Category category = map_poi_block::Category::Shops;
  uint16_t blockOrder = 0;
  uint16_t recordOrder = 0;
  uint8_t rank = 0;
};

struct Placement {
  Candidate candidate;
};

struct Diagnostics {
  size_t gathered = 0;
  size_t offscreen = 0;
  size_t collisionRejected = 0;
  size_t capacityDeferred = 0;
  size_t accepted = 0;
  std::array<size_t, 5> acceptedCategories = {};
};

uint32_t visibilityBit(map_poi_block::Category category);
bool better(const Candidate &left, const Candidate &right, bool guidance);
void retainBounded(MapPoiLayoutVector<Candidate> &candidates,
                   const Candidate &candidate, bool guidance,
                   Diagnostics *diagnostics = nullptr);
MapPoiLayoutVector<Placement>
place(MapPoiLayoutVector<Candidate> candidates,
      map_label_layout::Bounds screen, bool guidance,
      const MapLabelLayoutVector<map_label_layout::ReservedRegion> &reserved,
      Diagnostics *diagnostics = nullptr);

} // namespace map_poi_layout
