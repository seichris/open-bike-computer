#include "../../lib/maps/src/mapNearbyLayout.hpp"
#include "../../lib/maps/src/mapNearbyViewport.hpp"
#include "../../lib/maps/src/mapNearbyIcons.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <cstring>

using map_nearby_layout::Input;

int main() {
  std::array<uint16_t, 16 * 16> color{};
  std::array<uint8_t, 16 * 16> alpha{};
  std::array<unsigned, 5> glyphPixels{};
  for (uint8_t category = 1; category <= 5; ++category) {
    map_nearby_icons::draw({color.data(), alpha.data(), 16, 16, 16, 16}, category);
    unsigned opaque = 0;
    for (size_t pixel = 0; pixel < color.size(); ++pixel) {
      assert(alpha[pixel] == 0 || alpha[pixel] == 255);
      if (alpha[pixel]) ++opaque;
      if (color[pixel] == 0xFFFF) ++glyphPixels[category - 1];
    }
    assert(glyphPixels[category - 1] > 20);
    assert(opaque > glyphPixels[category - 1] && opaque < color.size());
    for (uint8_t previous = 1; previous < category; ++previous)
      assert(map_nearby_icons::kGlyphs[previous - 1] != map_nearby_icons::kGlyphs[category - 1]);
  }
  map_nearby_icons::draw({color.data(), alpha.data(), 16, 16, 16, 16}, 0);
  for (auto value : alpha) assert(value == 0);
  struct Center { int32_t x, y; };
  for (bool originalFollow : {false, true}) {
    map_nearby_viewport::Bookmark bookmark;
    Center center{123, -456};
    bool follow = originalFollow;
    bookmark.capture(follow, center);
    center = {999, 888};
    follow = false;
    bookmark.capture(follow, center); // repeated entry cannot overwrite owner
    assert(bookmark.restore(follow, center));
    assert(follow == originalFollow && center.x == 123 && center.y == -456);
    assert(!bookmark.restore(follow, center));
  }
  // Asymmetric control insets and physical round clipping move the anchor,
  // but must not rotate the arrow away from the true projected bearing.
  Input bearing{1000, 450, 3, 4, true, 1, 100};
  auto bearingLayout = map_nearby_layout::arrange(&bearing, 1, 466, 466, true, 80, 20);
  const auto &arrow = bearingLayout.placements[0];
  assert(arrow.edge);
  assert(std::fabs(arrow.directionY / arrow.directionX - 4.0 / 3.0) < 1e-9);
  std::array<Input, 2> mixed{{
      {405, 230, 0, 0, true, 1, 100},
      {900, 230, 0, 0, true, 2, 200},
  }};
  auto mixedLayout = map_nearby_layout::arrange(mixed.data(), mixed.size(),
      466, 466, false, 0, 0);
  assert(mixedLayout.count == 1);
  assert(mixedLayout.placements[0].edge && mixedLayout.placements[0].members == 3);
  assert(mixedLayout.placements[0].nearestDistanceM == 100);
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
  Input atBoundary{25, 233, 0, 0, true, 1, 100};
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

  // Nearby ranks the nearest ten across all selected categories; a selected
  // category crowded out of them is named rather than silently missing.
  char absent[96]{};
  const uint8_t restaurants[10] = {2, 2, 2, 2, 2, 2, 2, 2, 2, 2};
  const uint32_t restaurantsAndToilets = (1U << 1) | (1U << 2);
  assert(map_nearby_layout::formatAbsentCategories(
      restaurantsAndToilets, restaurants, 10, 10.0, absent, sizeof(absent)));
  assert(std::strcmp(absent, "No toilets in nearest 10") == 0);
  const uint8_t both[3] = {2, 3, 2};
  assert(!map_nearby_layout::formatAbsentCategories(
      restaurantsAndToilets, both, 3, 10.0, absent, sizeof(absent)));
  assert(absent[0] == '\0');
  // Fewer than ten places means the search radius, not the ten, excluded it.
  const uint8_t toilets[2] = {3, 3};
  assert(map_nearby_layout::formatAbsentCategories(
      (1U << 2) | (1U << 3), toilets, 2, 25.0, absent, sizeof(absent)));
  assert(std::strcmp(absent, "No gas stations within 25 km") == 0);
  assert(map_nearby_layout::formatAbsentCategories(
      0x1FU, restaurants, 10, 10.0, absent, sizeof(absent)));
  assert(std::strcmp(absent,
      "No shops, toilets, gas stations, bike shops in nearest 10") == 0);
  char small[12]{};
  assert(!map_nearby_layout::formatAbsentCategories(
      restaurantsAndToilets, restaurants, 10, 10.0, small, sizeof(small)));
  assert(small[0] == '\0');
}
