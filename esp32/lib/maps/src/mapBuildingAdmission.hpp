#pragma once

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

struct Quotas {
  size_t maximumRecords = 96;
  size_t maximumPoints = 8192;
  uint64_t maximumProjectedPixels = 220000;
  size_t maximumExtrudedRecords = 32;
  size_t maximumExtrudedPoints = 3072;
  uint64_t maximumExtrudedPixels = 90000;
};

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
    const bool fitsBase = records < quotas.maximumRecords &&
                          candidate.pointCount <=
                              quotas.maximumPoints - points &&
                          candidate.projectedPixels <=
                              quotas.maximumProjectedPixels - pixels;
    if (fitsBase) {
      decision.admitted = true;
      records++;
      points += candidate.pointCount;
      pixels += candidate.projectedPixels;
      const bool fitsExtrusion =
          candidate.extrusionEligible &&
          extrudedRecords < quotas.maximumExtrudedRecords &&
          candidate.pointCount <=
              quotas.maximumExtrudedPoints - extrudedPoints &&
          candidate.projectedPixels <=
              quotas.maximumExtrudedPixels - extrudedPixels;
      if (fitsExtrusion) {
        decision.extruded = true;
        extrudedRecords++;
        extrudedPoints += candidate.pointCount;
        extrudedPixels += candidate.projectedPixels;
        local.extruded++;
      } else {
        local.flat++;
      }
      local.selected++;
    } else {
      local.deferred++;
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
