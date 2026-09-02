#include "../../lib/ble_navigation/map_profile_protocol.hpp"
#include "../../lib/maps/src/mapPoiLayout.hpp"

#include <cassert>
#include <iostream>

int main() {
  using map_poi_block::Category;
  using namespace map_poi_layout;

  assert(visibilityBit(Category::Shops) ==
         map_profile_protocol::VISIBILITY_POI_SHOPS);
  assert(visibilityBit(Category::BicycleServices) ==
         map_profile_protocol::VISIBILITY_POI_BICYCLE_SERVICES);

  Candidate shop{50, 50, 10, Category::Shops, 0, 0, 0};
  Candidate bicycle{50, 50, 20, Category::BicycleServices, 0, 1, 0};
  assert(better(bicycle, shop, false));
  assert(better(bicycle, shop, true));

  MapPoiLayoutVector<Candidate> bounded;
  bounded.reserve(kMaximumCandidates);
  Diagnostics boundedDiagnostics;
  for (size_t index = 0; index < kMaximumCandidates + 20; ++index) {
    Candidate candidate;
    candidate.x = 30 + static_cast<float>(index % 10) * 22;
    candidate.y = 30 + static_cast<float>(index / 10) * 22;
    candidate.riderDistanceSquared = static_cast<double>(index);
    candidate.category = Category::Shops;
    candidate.recordOrder = static_cast<uint16_t>(index);
    retainBounded(bounded, candidate, false, &boundedDiagnostics);
  }
  assert(bounded.size() == kMaximumCandidates);
  assert(boundedDiagnostics.gathered == kMaximumCandidates + 20);
  assert(boundedDiagnostics.capacityDeferred == 20);

  MapPoiLayoutVector<Candidate> candidates;
  candidates.push_back(shop);
  candidates.push_back(bicycle); // wins the same-position collision
  candidates.push_back({5, 5, 0, Category::PublicToilets, 0, 2, 0});
  candidates.push_back({150, 150, 0, Category::GasStations, 0, 3, 0});
  MapLabelLayoutVector<map_label_layout::ReservedRegion> reserved;
  reserved.push_back({150, 150, 30, 30});
  Diagnostics diagnostics;
  const auto placements =
      place(std::move(candidates), {200, 200}, false, reserved, &diagnostics);
  assert(placements.size() == 1);
  assert(placements[0].candidate.category == Category::BicycleServices);
  assert(diagnostics.offscreen == 1);
  assert(diagnostics.collisionRejected == 2);
  assert(diagnostics.acceptedCategories[4] == 1);

  MapPoiLayoutVector<Candidate> many;
  for (size_t index = 0; index < 60; ++index) {
    many.push_back({20.0F + static_cast<float>(index % 10) * 24.0F,
                    20.0F + static_cast<float>(index / 10) * 24.0F,
                    static_cast<double>(index), Category::Shops, 0,
                    static_cast<uint16_t>(index), 0});
  }
  const auto guidancePlacements =
      place(std::move(many), {300, 200}, true, {}, &diagnostics);
  assert(guidancePlacements.size() == kMaximumGuidancePlacements);
  assert(diagnostics.capacityDeferred > 0);

  std::cout << "map POI layout tests passed\n";
  return 0;
}
