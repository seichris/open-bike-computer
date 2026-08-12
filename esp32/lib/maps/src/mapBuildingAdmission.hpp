#pragma once

#include "../../renderer_tuning/renderer_tuning.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace map_building_admission {

struct SpatialKey {
  double distanceSquared = 0.0;
  int32_t blockX = 0;
  int32_t blockY = 0;
  uint32_t recordIndex = 0;
};

inline bool nearer(const SpatialKey &left, const SpatialKey &right) {
  if (left.distanceSquared != right.distanceSquared)
    return left.distanceSquared < right.distanceSquared;
  if (left.blockX != right.blockX)
    return left.blockX < right.blockX;
  if (left.blockY != right.blockY)
    return left.blockY < right.blockY;
  return left.recordIndex < right.recordIndex;
}

using Quotas = renderer_tuning::BuildingQuotas;

struct Candidate {
  SpatialKey key{};
  size_t pointCount = 0;
  uint64_t projectedPixels = 0;
  bool extrusionEligible = false;
  size_t sourceIndex = 0;
};


/**
 * Retain the globally nearest candidates in bounded memory. The heap root is
 * the farthest retained item, so discovery order and map-cache order cannot
 * influence the final set.
 */
template <typename CandidateVector>
inline void retainNearest(CandidateVector &retained,
                          const Candidate &candidate, size_t maximumCandidates) {
  if (maximumCandidates == 0)
    return;
  const auto heapCompare = [](const Candidate &left, const Candidate &right) {
    return nearer(left.key, right.key);
  };
  if (retained.size() < maximumCandidates) {
    retained.push_back(candidate);
    std::push_heap(retained.begin(), retained.end(), heapCompare);
    return;
  }
  if (!nearer(candidate.key, retained.front().key))
    return;
  std::pop_heap(retained.begin(), retained.end(), heapCompare);
  retained.back() = candidate;
  std::push_heap(retained.begin(), retained.end(), heapCompare);
}

struct Decision {
  size_t sourceIndex = 0;
  bool admitted = false;
  bool extruded = false;
};

struct Diagnostics {
  size_t candidates = 0;
  size_t selected = 0;
  size_t extruded = 0;
  size_t flat = 0;
  size_t deferred = 0;
  size_t selectedPoints = 0;
  uint64_t selectedPixels = 0;
  uint8_t limiterFlags = 0;
};

enum Limiter : uint8_t {
  LimiterNone = 0,
  LimiterRecords = 1U << 0,
  LimiterPoints = 1U << 1,
  LimiterProjectedPixels = 1U << 2,
  LimiterExtrudedRecords = 1U << 3,
  LimiterExtrudedPoints = 1U << 4,
  LimiterExtrudedPixels = 1U << 5,
};

/**
 * Globally sort by rider distance and stable record identity before applying
 * budgets.  The result is therefore invariant under map-block/cache iteration
 * order.  Records that fit the 2D budget but miss the tighter extrusion budget
 * remain admitted as deterministic flat roofs/footprints.
 */
template <typename CandidateVector>
inline std::vector<Decision> select(CandidateVector candidates,
                                    const Quotas &quotas,
                                    Diagnostics *diagnostics = nullptr) {
  std::stable_sort(candidates.begin(), candidates.end(),
                   [](const Candidate &left, const Candidate &right) {
                     return nearer(left.key, right.key);
                   });

  std::vector<Decision> decisions;
  decisions.reserve(candidates.size());
  size_t records = 0;
  size_t points = 0;
  uint64_t pixels = 0;
  size_t extrudedRecords = 0;
  size_t extrudedPoints = 0;
  uint64_t extrudedPixels = 0;
  Diagnostics local{};
  local.candidates = candidates.size();

  for (const Candidate &candidate : candidates) {
    Decision decision{candidate.sourceIndex, false, false};
    const bool fitsRecords = records < quotas.maximumRecords;
    const bool fitsPoints = points <= quotas.maximumPoints &&
                            candidate.pointCount <=
                                quotas.maximumPoints - points;
    const bool fitsPixels = pixels <= quotas.maximumProjectedPixels &&
                            candidate.projectedPixels <=
                                quotas.maximumProjectedPixels - pixels;
    const bool fitsBase = fitsRecords && fitsPoints && fitsPixels;
    if (fitsBase) {
      decision.admitted = true;
      records++;
      points += candidate.pointCount;
      pixels += candidate.projectedPixels;
      const bool fitsExtrudedRecords =
          extrudedRecords < quotas.maximumExtrudedRecords;
      const bool fitsExtrudedPoints =
          extrudedPoints <= quotas.maximumExtrudedPoints &&
          candidate.pointCount <=
              quotas.maximumExtrudedPoints - extrudedPoints;
      const bool fitsExtrudedPixels =
          extrudedPixels <= quotas.maximumExtrudedPixels &&
          candidate.projectedPixels <=
              quotas.maximumExtrudedPixels - extrudedPixels;
      const bool fitsExtrusion = candidate.extrusionEligible &&
                                 fitsExtrudedRecords && fitsExtrudedPoints &&
                                 fitsExtrudedPixels;
      if (fitsExtrusion) {
        decision.extruded = true;
        extrudedRecords++;
        extrudedPoints += candidate.pointCount;
        extrudedPixels += candidate.projectedPixels;
        local.extruded++;
      } else {
        local.flat++;
        if (candidate.extrusionEligible) {
          if (!fitsExtrudedRecords)
            local.limiterFlags |= LimiterExtrudedRecords;
          if (!fitsExtrudedPoints)
            local.limiterFlags |= LimiterExtrudedPoints;
          if (!fitsExtrudedPixels)
            local.limiterFlags |= LimiterExtrudedPixels;
        }
      }
      local.selected++;
    } else {
      local.deferred++;
      if (!fitsRecords)
        local.limiterFlags |= LimiterRecords;
      if (!fitsPoints)
        local.limiterFlags |= LimiterPoints;
      if (!fitsPixels)
        local.limiterFlags |= LimiterProjectedPixels;
    }
    decisions.push_back(decision);
  }
  local.selectedPoints = points;
  local.selectedPixels = pixels;
  if (diagnostics != nullptr)
    *diagnostics = local;
  return decisions;
}

} // namespace map_building_admission
