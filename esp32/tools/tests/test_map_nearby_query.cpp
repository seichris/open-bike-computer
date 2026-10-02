// Arduino.h defines this macro before firmware includes the query helper.
#define radians(deg) ((deg) * 0.017453292519943295)
#include "../../lib/maps/src/mapNearbyQuery.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <vector>

int main() {
  using namespace map_nearby_query;
  const Position origin{0.0, 0.0};
  assert(std::fabs(distanceMeters(origin, {0.0, 1.0}) - 111319.4908) < 0.1);
  assert(distanceMeters({80.0, 179.99}, {80.0, -179.99}) < 400.0);
  assert(!valid({NAN, 0.0}));
  assert(!valid({0.0, 181.0}));

  map_poi_index::Entry near{};
  near.blockX = 0;
  near.blockY = 0;
  near.categoryCounts = {12, 0, 0, 0, 0};
  near.categoryMask = 1;
  near.sectionOffset = 112;
  near.sectionBytes = 8 + 12 * 8;
  auto middle = near;
  middle.blockX = 1;
  auto far = near;
  far.blockX = 10;
  const std::array<map_poi_index::Entry, 3> index = {far, middle, near};
  MapNearbyVector<FrontierItem> frontier;
  assert(prepareFrontier(index.data(), index.size(), origin, 1, 10000.0,
                         frontier));
  assert(frontier.size() == 2);
  assert(frontier[0].index == 2);
  assert(frontier[1].index == 1);
  assert(frontier[0].lowerBoundM() <=
         distanceMeters(origin, {0.0, 0.0}));
  assert(!prepareFrontier(index.data(), index.size(), origin, 0, 10000.0,
                          frontier));
  assert(!prepareFrontier(index.data(), index.size(), origin, 1, 25001.0,
                          frontier));

  std::vector<uint8_t> records;
  for (uint16_t ordinal = 0; ordinal < 12; ++ordinal) {
    const uint16_t x = static_cast<uint16_t>(ordinal * 100);
    records.insert(records.end(), {static_cast<uint8_t>(x),
                                   static_cast<uint8_t>(x >> 8U),
                                   0, 0, 1, 2, 0, 0});
  }
  NearestTen search(origin, 1, 10000.0);
  assert(search.consume(near, 0, records.data(), 12));
  assert(search.size() == 10);
  assert(search[0].recordOrdinal == 0);
  assert(search[9].recordOrdinal == 9);
  for (size_t item = 1; item < search.size(); ++item)
    assert(search[item - 1].directDistanceM <=
           search[item].directDistanceM);
  assert(search.canFinishBefore(10000.1));
  assert(!search.canFinishBefore(0.0));
  assert(!search.consume(near, 0, records.data(), 257));
  records[4] = 6;
  assert(!search.consume(near, 0, records.data(), 1));

  // A conservative grid lower bound may be loose, but it must never exceed
  // the direct distance to any point in the block, even at high latitude or
  // across the anti-meridian.
  const Position rider{80.0, 179.99};
  const double riderX = kMercatorRadiusM * degreesToRadians(rider.longitude);
  const double riderY = kMercatorRadiusM *
      std::log(std::tan(kPi / 4.0 + degreesToRadians(rider.latitude) / 2.0));
  map_poi_index::Entry highLatitude{};
  highLatitude.blockX = static_cast<int32_t>(std::floor(riderX / kBlockSizeM));
  highLatitude.blockY = static_cast<int32_t>(std::floor(riderY / kBlockSizeM));
  highLatitude.categoryMask = 1;
  highLatitude.categoryCounts = {1, 0, 0, 0, 0};
  highLatitude.sectionOffset = 112;
  highLatitude.sectionBytes = 16;
  for (double dx : {0.0, 4095.0}) {
    for (double dy : {0.0, 4095.0}) {
      Position corner;
      assert(mercatorPosition(double(highLatitude.blockX) * kBlockSizeM + dx,
                              double(highLatitude.blockY) * kBlockSizeM + dy,
                              corner));
      assert(blockLowerBoundMeters(rider, highLatitude) <=
             distanceMeters(rider, corner));
    }
  }
  assert(distanceMeters({80.0, 179.99}, {80.0, -179.99}) <
         distanceMeters({80.0, 179.99}, {80.0, 179.90}));

  // Compare the bounded accumulator with a brute-force scan of every record.
  // Feed the distant block first so insertion order cannot mask rank errors.
  const std::array<int32_t, 4> blockXs{{8, 1, -1, 0}};
  std::array<map_poi_index::Entry, 4> denseIndex{};
  std::array<std::vector<uint8_t>, 4> denseRecords{};
  std::vector<Result> expected;
  constexpr uint32_t selectedCategories = (1U << 0) | (1U << 2) | (1U << 4);
  NearestTen denseSearch(origin, selectedCategories, 25000.0);
  for (size_t block = 0; block < denseIndex.size(); ++block) {
    auto &entry = denseIndex[block];
    entry.blockX = blockXs[block];
    entry.blockY = 0;
    entry.sectionOffset = 112;
    for (uint16_t ordinal = 0; ordinal < 30; ++ordinal) {
      const uint16_t localX = static_cast<uint16_t>((ordinal * 137U) % 4096U);
      const uint16_t localY = static_cast<uint16_t>((ordinal * 211U) % 4096U);
      const uint8_t category = static_cast<uint8_t>((ordinal + block) % 5U + 1U);
      denseRecords[block].insert(denseRecords[block].end(), {
          static_cast<uint8_t>(localX), static_cast<uint8_t>(localX >> 8U),
          static_cast<uint8_t>(localY), static_cast<uint8_t>(localY >> 8U),
          category, 5, 0, 0});
      ++entry.categoryCounts[category - 1U];
      entry.categoryMask |= 1U << (category - 1U);
      Position position;
      assert(mercatorPosition(double(entry.blockX) * kBlockSizeM + localX,
                              double(entry.blockY) * kBlockSizeM + localY,
                              position));
      const double distance = distanceMeters(origin, position);
      if ((selectedCategories & (1U << (category - 1U))) != 0 &&
          distance <= 25000.0)
        expected.push_back({position, distance, entry.blockX, entry.blockY,
                            ordinal, category});
    }
    entry.sectionBytes = static_cast<uint32_t>(8U + denseRecords[block].size());
    assert(denseSearch.consume(entry, 0, denseRecords[block].data(), 30));
  }
  std::sort(expected.begin(), expected.end(), better);
  assert(denseSearch.size() == kMaximumResults);
  for (size_t index = 0; index < denseSearch.size(); ++index) {
    assert(denseSearch[index].blockX == expected[index].blockX);
    assert(denseSearch[index].recordOrdinal == expected[index].recordOrdinal);
    assert(denseSearch[index].category == expected[index].category);
    assert(std::fabs(denseSearch[index].directDistanceM -
                     expected[index].directDistanceM) < 1e-6);
  }
  assert(prepareFrontier(denseIndex.data(), denseIndex.size(), origin,
                         selectedCategories, 25000.0, frontier));
  assert(frontier.size() == 3);

  std::cout << "Nearby query geometry and bounded nearest-ten tests passed\n";
}
