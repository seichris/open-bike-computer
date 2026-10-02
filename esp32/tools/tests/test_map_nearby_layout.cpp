#include "../../lib/maps/src/mapNearbyLayout.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <cstring>

using map_nearby_layout::Input;

int main() {
  std::array<Input, 5> places{{
      {233, 233, 0, 0, true, 1, 120},
      {238, 235, 0, 0, true, 2, 160},
      {800, 200, 0, 0, true, 3, 1200},
      {900, 210, 0, 0, true, 3, 1500},
      {0, 0, 0, -1, false, 5, 2000},
  }};
  const auto round = map_nearby_layout::arrange(
      places.data(), places.size(), 466, 466, true, 42, 42);
  assert(round.count == 3);
  assert(round.placements[0].count == 2 && !round.placements[0].edge);
  assert(round.placements[0].category == 0);
  assert(map_nearby_layout::displayCategory(
             round.placements[0], places.data(), places.size()) == 1);
  assert(round.placements[0].nearestDistanceM == 120);
  assert(round.placements[1].count == 2 && round.placements[1].edge);
  assert(round.placements[1].category == 3);
  assert(map_nearby_layout::displayCategory(
             round.placements[1], places.data(), places.size()) == 3);
  assert(round.placements[1].members == (1U << 2 | 1U << 3));
  for (size_t index = 0; index < round.count; ++index) {
    const auto &placed = round.placements[index];
    assert(placed.x >= 49 && placed.x <= 417);
    assert(placed.y >= 77 && placed.y <= 389);
    if (placed.edge) {
      // The 72x52 indicator rectangle is conservatively inside the circle.
      const double distance = std::hypot(placed.x - 233, placed.y - 233);
      assert(distance <= 177.0);
    }
  }

  const auto rectangle = map_nearby_layout::arrange(
      places.data(), places.size(), 466, 466, false, 20, 65);
  assert(rectangle.count == 3);
  for (size_t index = 0; index < rectangle.count; ++index) {
    const auto &placed = rectangle.placements[index];
    if (!placed.edge) continue;
    assert(placed.x >= 49 && placed.x <= 417);
    assert(placed.y >= 55 && placed.y <= 366);
  }

  std::array<bool, map_nearby_layout::kMaximumResults> previouslyOnMap{};
  previouslyOnMap[0] = true;
  Input atBoundary{19, 233, 0, 0, true, 1, 100};
  assert(map_nearby_layout::arrange(
             &atBoundary, 1, 466, 466, false, 0, 0, previouslyOnMap)
             .onMap[0]);
  assert(!map_nearby_layout::arrange(
              &atBoundary, 1, 466, 466, false, 0, 0)
              .onMap[0]);

  // No invalid projection behind a bird's-eye near plane becomes a map pin.
  Input behind{0, 0, -1, 1, false, 4, 500};
  const auto fallback = map_nearby_layout::arrange(
      &behind, 1, 466, 466, true, 42, 42);
  assert(fallback.count == 1 && fallback.placements[0].edge);
  assert(fallback.placements[0].x < 233 && fallback.placements[0].y > 233);

  bool kilometres = false;
  char distance[24]{};
  assert(map_nearby_layout::formatDirectDistance(
      999.0, kilometres, distance, sizeof(distance)));
  assert(std::strcmp(distance, "1000 m") == 0 && !kilometres);
  assert(map_nearby_layout::formatDirectDistance(
      1049.0, kilometres, distance, sizeof(distance)));
  assert(std::strcmp(distance, "1050 m") == 0 && !kilometres);
  assert(map_nearby_layout::formatDirectDistance(
      1051.0, kilometres, distance, sizeof(distance)));
  assert(std::strcmp(distance, "1.1 km") == 0 && kilometres);
  assert(map_nearby_layout::formatDirectDistance(
      1000.0, kilometres, distance, sizeof(distance)));
  assert(std::strcmp(distance, "1.0 km") == 0 && kilometres);
  assert(map_nearby_layout::formatDirectDistance(
      949.0, kilometres, distance, sizeof(distance)));
  assert(std::strcmp(distance, "950 m") == 0 && !kilometres);
  assert(map_nearby_layout::formatDirectDistance(
      NAN, kilometres, distance, sizeof(distance)));
  assert(std::strcmp(distance, "--") == 0 && !kilometres);
  char tooSmall[2]{};
  assert(!map_nearby_layout::formatDirectDistance(
      1200.0, kilometres, tooSmall, sizeof(tooSmall)));
}
