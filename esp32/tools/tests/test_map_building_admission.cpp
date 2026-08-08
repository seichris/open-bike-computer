#include "../../lib/maps/src/mapBuildingAdmission.hpp"

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <vector>

namespace {

std::vector<map_building_admission::Candidate> fixture() {
  using namespace map_building_admission;
  return {
      {{25.0, 0, 0, 2}, 20, 100, true, 2},
      {{1.0, 1, 0, 7}, 20, 100, true, 7},
      {{9.0, -1, 0, 4}, 20, 100, true, 4},
      {{4.0, 0, 1, 3}, 20, 100, false, 3},
      {{16.0, 0, -1, 5}, 20, 100, true, 5},
  };
}

std::vector<map_building_admission::Decision>
sortedDecisions(std::vector<map_building_admission::Decision> decisions) {
  std::sort(decisions.begin(), decisions.end(), [](const auto &a, const auto &b) {
    return a.sourceIndex < b.sourceIndex;
  });
  return decisions;
}

} // namespace


static void testBoundedNearestRetentionIsOrderIndependent() {
  using namespace map_building_admission;
  std::vector<Candidate> forward;
  std::vector<Candidate> reverse;
  std::vector<Candidate> input;
  for (size_t index = 0; index < 20; ++index) {
    Candidate candidate;
    candidate.key = {static_cast<double>((index * 7) % 20),
                     static_cast<int32_t>(index % 3),
                     static_cast<int32_t>(index % 5),
                     static_cast<uint32_t>(index)};
    candidate.sourceIndex = index;
    input.push_back(candidate);
  }
  for (const auto &candidate : input)
    retainNearest(forward, candidate, 6);
  for (auto item = input.rbegin(); item != input.rend(); ++item)
    retainNearest(reverse, *item, 6);
  const auto byKey = [](const Candidate &left, const Candidate &right) {
    return nearer(left.key, right.key);
  };
  std::sort(forward.begin(), forward.end(), byKey);
  std::sort(reverse.begin(), reverse.end(), byKey);
  assert(forward.size() == 6);
  assert(reverse.size() == 6);
  for (size_t index = 0; index < forward.size(); ++index) {
    assert(forward[index].key.distanceSquared ==
           reverse[index].key.distanceSquared);
    assert(forward[index].key.recordIndex == reverse[index].key.recordIndex);
  }
}

int main() {
  testBoundedNearestRetentionIsOrderIndependent();
  using namespace map_building_admission;
  Quotas quotas;
  quotas.maximumRecords = 3;
  quotas.maximumPoints = 60;
  quotas.maximumProjectedPixels = 300;
  quotas.maximumExtrudedRecords = 1;
  quotas.maximumExtrudedPoints = 20;
  quotas.maximumExtrudedPixels = 100;

  Diagnostics diagnostics;
  const auto expected = sortedDecisions(select(fixture(), quotas, &diagnostics));
  assert(diagnostics.candidates == 5);
  assert(diagnostics.selected == 3);
  assert(diagnostics.extruded == 1);
  assert(diagnostics.flat == 2);
  assert(diagnostics.deferred == 2);

  // Every cache/block traversal permutation yields exactly the same spatial
  // admission and deterministic 3D-to-flat degradation.
  auto permuted = fixture();
  std::sort(permuted.begin(), permuted.end(), [](const auto &left,
                                                  const auto &right) {
    return left.sourceIndex < right.sourceIndex;
  });
  do {
    const auto actual = sortedDecisions(select(permuted, quotas));
    assert(expected.size() == actual.size());
    for (size_t i = 0; i < expected.size(); ++i) {
      assert(expected[i].sourceIndex == actual[i].sourceIndex);
      assert(expected[i].admitted == actual[i].admitted);
      assert(expected[i].extruded == actual[i].extruded);
    }
  } while (std::next_permutation(
      permuted.begin(), permuted.end(), [](const auto &left,
                                           const auto &right) {
        return left.sourceIndex < right.sourceIndex;
      }));

  // Nearest records survive overflow.  The nearest eligible record is 3D;
  // the next two remain ordinary flat buildings instead of disappearing.
  auto bySource = expected;
  const auto find = [&](size_t source) -> const Decision & {
    return *std::find_if(bySource.begin(), bySource.end(), [&](const auto &d) {
      return d.sourceIndex == source;
    });
  };
  assert(find(7).admitted && find(7).extruded);
  assert(find(3).admitted && !find(3).extruded);
  assert(find(4).admitted && !find(4).extruded);
  assert(!find(5).admitted);
  assert(!find(2).admitted);
  return 0;
}
