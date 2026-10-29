// Arduino.h defines this macro before firmware includes the query helper.
#define radians(deg) ((deg) * 0.017453292519943295)
#include "../../lib/maps/src/mapNearbyQuery.hpp"
#include "../../lib/maps/src/mapNearbyCoverage.hpp"
#include "../../lib/maps/src/mapNearbyStorage.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <random>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
using map_nearby_coverage::Block;
using map_nearby_query::Position;

struct Window {
  int32_t firstX = 0, lastX = 0, firstY = 0, lastY = 0;
};

// The pre-resumable single-pass window and evaluation, kept as an oracle.
bool referenceWindow(Position rider, double radiusM, Window &window) {
  using namespace map_nearby_query;
  if (!valid(rider) || !std::isfinite(radiusM) || radiusM <= 0.0 ||
      radiusM > 25000.0 || std::fabs(rider.latitude) >= 85.05112878)
    return false;
  const double extremeLatitude = std::fabs(rider.latitude) +
      radiusM / kWgs84MinimumRadiusM * 180.0 / kPi;
  if (extremeLatitude >= 85.05112878) return false;
  const double minimumCosine = std::cos(degreesToRadians(extremeLatitude));
  const double x = kMercatorRadiusM * degreesToRadians(rider.longitude);
  const double y = kMercatorRadiusM *
      std::log(std::tan(kPi / 4.0 + degreesToRadians(rider.latitude) / 2.0));
  const double projectedRadius =
      radiusM * kMercatorRadiusM / (kWgs84MinimumRadiusM * minimumCosine) +
      kBlockSizeM;
  window.firstX = static_cast<int32_t>(std::floor((x - projectedRadius) / kBlockSizeM));
  window.lastX = static_cast<int32_t>(std::floor((x + projectedRadius) / kBlockSizeM));
  window.firstY = static_cast<int32_t>(std::floor((y - projectedRadius) / kBlockSizeM));
  window.lastY = static_cast<int32_t>(std::floor((y + projectedRadius) / kBlockSizeM));
  return true;
}

bool referenceComplete(const std::vector<Block> &blocks, Position rider,
                       double radiusM) {
  Window window;
  if (blocks.empty() || !referenceWindow(rider, radiusM, window)) return false;
  for (int32_t blockX = window.firstX; blockX <= window.lastX; ++blockX)
    for (int32_t blockY = window.firstY; blockY <= window.lastY; ++blockY) {
      map_poi_index::Entry entry;
      entry.blockX = blockX;
      entry.blockY = blockY;
      const double bound = map_nearby_query::blockLowerBoundMeters(rider, entry);
      if ((!std::isfinite(bound) || bound <= radiusM) &&
          !map_nearby_coverage::contains(blocks, {blockX, blockY}))
        return false;
    }
  return true;
}

std::vector<Block> squareCoverage(int32_t centerX, int32_t centerY,
                                  int32_t halfSize) {
  std::vector<Block> blocks;
  for (int32_t x = centerX - halfSize; x <= centerX + halfSize; ++x)
    for (int32_t y = centerY - halfSize; y <= centerY + halfSize; ++y)
      blocks.push_back({x, y});
  return blocks; // generated in canonical (x, y) order
}

std::vector<Block> windowCoverage(Position rider, double radiusM) {
  Window window;
  assert(referenceWindow(rider, radiusM, window));
  std::vector<Block> blocks;
  for (int32_t x = window.firstX; x <= window.lastX; ++x)
    for (int32_t y = window.firstY; y <= window.lastY; ++y)
      blocks.push_back({x, y});
  return blocks;
}

// Every split of the scan matches the single-pass oracle, and each step
// evaluates no more than its budget.
void testResumableCoverageMatchesSinglePass() {
  using map_nearby_coverage::CompletenessScan;
  std::mt19937 random(338);
  std::uniform_real_distribution<double> latitude(-70.0, 70.0);
  std::uniform_real_distribution<double> longitude(-180.0, 180.0);
  std::uniform_real_distribution<double> radius(100.0, 8000.0);
  size_t completeCases = 0, incompleteCases = 0;
  for (int trial = 0; trial < 400; ++trial) {
    const Position rider{latitude(random), longitude(random)};
    const double radiusM = radius(random);
    Window window;
    assert(referenceWindow(rider, radiusM, window));
    const int32_t centerX = (window.firstX + window.lastX) / 2;
    const int32_t centerY = (window.firstY + window.lastY) / 2;
    const int32_t span = (window.lastX - window.firstX) / 2 + 2;
    auto coverage = squareCoverage(
        centerX, centerY, std::uniform_int_distribution<int32_t>(0, span)(random));
    if (trial % 3 == 0 && coverage.size() > 1) // a hole may or may not matter
      coverage.erase(coverage.begin() + static_cast<std::ptrdiff_t>(
          std::uniform_int_distribution<size_t>(0, coverage.size() - 1)(random)));
    const bool expected = referenceComplete(coverage, rider, radiusM);
    expected ? ++completeCases : ++incompleteCases;
    assert(map_nearby_coverage::completeWithinRadius(coverage, rider, radiusM) ==
           expected);
    for (uint32_t budget : {1U, 7U, 64U, UINT32_MAX}) {
      CompletenessScan scan(coverage, rider, radiusM);
      uint32_t previous = 0;
      while (!scan.step(budget)) {
        assert(scan.evaluatedBlocks() - previous == budget);
        previous = scan.evaluatedBlocks();
      }
      assert(scan.evaluatedBlocks() - previous <= budget);
      assert(scan.complete() == expected);
      assert(scan.step(budget) && scan.evaluatedBlocks() >= previous);
    }
  }
  assert(completeCases >= 40 && incompleteCases >= 40);

  // Invalid inputs never claim completeness, in any number of steps.
  const std::vector<Block> one{{0, 0}};
  for (const auto &scan : {
           CompletenessScan(), CompletenessScan({}, {0.0, 0.0}, 1000.0),
           CompletenessScan(one, {NAN, 0.0}, 1000.0),
           CompletenessScan(one, {0.0, 0.0}, 25001.0),
           CompletenessScan(one, {85.06, 0.0}, 1000.0),
           CompletenessScan(one, {85.0, 0.0}, 25000.0)}) {
    assert(scan.done() && !scan.complete() && scan.evaluatedBlocks() == 0);
  }
}

// Near the Mercator limit a complete 25 km window spans thousands of blocks.
// It finishes only after many bounded steps, with the single-pass answer.
void testHighLatitudeWindowIsEvaluatedInBoundedSteps() {
  const Position rider{84.0, 10.0};
  const auto coverage = windowCoverage(rider, 25000.0);
  assert(coverage.size() > 10000);
  map_nearby_coverage::CompletenessScan scan(coverage, rider, 25000.0);
  size_t steps = 0;
  while (!scan.step(64)) ++steps;
  assert(scan.complete());
  assert(scan.evaluatedBlocks() == coverage.size());
  assert(steps + 1 >= coverage.size() / 64);
  assert(referenceComplete(coverage, rider, 25000.0));
}

void appendLe16(std::string &data, uint16_t value) {
  data.push_back(static_cast<char>(value & 0xffU));
  data.push_back(static_cast<char>(value >> 8U));
}

void appendLe32(std::string &data, uint32_t value) {
  for (unsigned shift = 0; shift < 32; shift += 8)
    data.push_back(static_cast<char>((value >> shift) & 0xffU));
}

uint32_t crc32(const std::string &data) {
  return map_nearby_storage::crcUpdate(
             0xffffffffU, reinterpret_cast<const uint8_t *>(data.data()),
             data.size()) ^ 0xffffffffU;
}

void writeFile(const std::string &path, const std::string &bytes) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  assert(out.good());
  out << bytes;
  assert(out.good());
}

// One block (0, 0) with a single shop about 141 m from the origin: an empty
// FMB6 geometry prefix, the EXT6 directory and section 6, plus its FPI1 entry.
std::string installedShopMap() {
  char pattern[] = "/tmp/open-bike-nearby-coverage-XXXXXX";
  const char *created = ::mkdtemp(pattern);
  assert(created != nullptr);
  const std::string root(created);
  assert(::mkdir((root + "/assets").c_str(), 0700) == 0);
  assert(::mkdir((root + "/+000+000").c_str(), 0700) == 0);
  std::string section;
  appendLe16(section, 1);
  appendLe16(section, 8);
  appendLe32(section, 1);
  appendLe16(section, 100);
  appendLe16(section, 100);
  section.append({1, 2, 0, 0});
  std::string block("FMB\x06\0\0\0\0", 8);
  block.append({'E', 'X', 'T', '6', 6, 0, 0, 0});
  block.append(5 * 16, '\0');
  block.append({6, 1, 0, 0});
  appendLe32(block, 112);
  appendLe32(block, static_cast<uint32_t>(section.size()));
  appendLe32(block, crc32(section));
  assert(block.size() == 112);
  block += section;
  writeFile(root + "/+000+000/0_0.fmb", block);
  std::string entry;
  appendLe32(entry, 0);
  appendLe32(entry, 0);
  appendLe32(entry, 1);
  appendLe16(entry, 1);
  for (int category = 1; category < 5; ++category) appendLe16(entry, 0);
  appendLe32(entry, 112);
  appendLe32(entry, static_cast<uint32_t>(section.size()));
  appendLe16(entry, 0);
  assert(entry.size() == 32);
  std::string index("FPI1", 4);
  appendLe16(index, 32);
  appendLe16(index, 0);
  appendLe32(index, 1);
  appendLe32(index, crc32(entry));
  writeFile(root + "/assets/nearby-pois.fpi", index + entry);
  return root;
}

size_t stepsUntilDone(map_nearby_storage::SearchCursor &cursor) {
  size_t slices = 0;
  while (!cursor.step()) {
    // Neither the nearest set nor a status is visible before coverage ends.
    assert(cursor.result().count == 0);
    assert(cursor.result().status == map_nearby_storage::Status::Unavailable);
    assert(++slices < 1000);
  }
  return slices;
}

void testCursorPublishesAfterResumableCoverage() {
  using map_nearby_storage::SearchCursor;
  using map_nearby_storage::Status;
  const std::string root = installedShopMap();
  const Position rider{0.0, 0.0};
  const auto window = windowCoverage(rider, 25000.0);
  assert(window.size() > 3 * 64);

  SearchCursor uncovered(root, rider, 1, 25000.0);
  const size_t searchSlices = stepsUntilDone(uncovered);
  assert(uncovered.result().status == Status::Ok);
  assert(uncovered.result().count == 1 && !uncovered.result().coverageComplete);

  SearchCursor covered(root, rider, 1, 25000.0, &window);
  const size_t coveredSlices = stepsUntilDone(covered);
  assert(coveredSlices >= searchSlices + window.size() / 64);
  assert(covered.result().status == Status::Ok);
  assert(covered.result().count == 1 && covered.result().coverageComplete);
  assert(covered.result().places[0].category == 1);
  assert(covered.result().searchedBlocks == 1);

  // A gap inside the circle ends the scan early and only drops the claim.
  auto gap = window;
  gap.erase(std::lower_bound(gap.begin(), gap.end(), Block{0, 0},
                             map_nearby_coverage::less));
  SearchCursor partial(root, rider, 1, 25000.0, &gap);
  assert(stepsUntilDone(partial) < coveredSlices);
  assert(partial.result().status == Status::Ok);
  assert(partial.result().count == 1 && !partial.result().coverageComplete);

  // After the record search the cursor is mid-coverage: cancelling there must
  // not publish the already complete nearest set.
  auto cancel = [](void *) { return true; };
  SearchCursor interrupted(root, rider, 1, 25000.0, &window);
  for (size_t slice = 0; slice <= searchSlices + 1; ++slice)
    assert(!interrupted.step());
  assert(interrupted.step(cancel));
  assert(interrupted.result().status == Status::Cancelled);
  assert(interrupted.result().count == 0 &&
         !interrupted.result().coverageComplete);
  assert(interrupted.step(cancel) && interrupted.done());

  assert(std::remove((root + "/+000+000/0_0.fmb").c_str()) == 0);
  assert(std::remove((root + "/assets/nearby-pois.fpi").c_str()) == 0);
  assert(::rmdir((root + "/+000+000").c_str()) == 0);
  assert(::rmdir((root + "/assets").c_str()) == 0);
  assert(::rmdir(root.c_str()) == 0);
}
} // namespace

int main() {
  using namespace map_nearby_query;
  // Canonical paths must round-trip signed boundaries and negative tile edges
  // without overflow, and must reject aliases and traversal before activation.
  const std::array<int32_t, 14> coordinates{{
      INT32_MIN, INT32_MIN + 1, -16001, -16000, -17, -16, -1,
      0, 1, 15, 16, 16000, INT32_MAX - 1, INT32_MAX}};
  for (int32_t expectedX : coordinates) {
    for (int32_t expectedY : coordinates) {
      int32_t x = 0, y = 0;
      const auto path = map_poi_index::blockPath("fixture", expectedX, expectedY);
      assert(map_poi_index::blockFromPath("fixture", path, x, y));
      assert(x == expectedX && y == expectedY);
    }
  }
  assert(map_poi_index::relativeBlockPath(-1, 16) == "-001+001/15_0.fmb");
  assert(map_poi_index::relativeBlockPath(INT32_MIN, INT32_MAX) ==
         "-134217728+134217727/0_15.fmb");
  for (const char *relative : {
      "+000+000/16_0.fmb", "+000+000/-1_0.fmb", "+000+000/+1_0.fmb",
      "+000+000/01_0.fmb", "+000+000/0_0.fmb/extra", "+000+000/0_0.fmb.fmb",
      "+00+000/0_0.fmb", "+0000+000/0_0.fmb", "-000+000/0_0.fmb",
      "+000+000/0_0.fmb/../0_0.fmb", "+134217728+000/0_0.fmb",
      "-134217729+000/15_0.fmb", "+000+134217728/0_0.fmb",
      "+999999999999999999999999+000/0_0.fmb", "+000+000/0_.fmb",
      "+000+000/0_ 1.fmb", "+000+000/0_1x.fmb"}) {
    int32_t x = 123, y = 456;
    assert(!map_poi_index::blockFromPath(
        "fixture", std::string("VECTMAP/fixture/") + relative, x, y));
    assert(x == 123 && y == 456);
  }
  int32_t wrongMapX = 0, wrongMapY = 0;
  assert(!map_poi_index::blockFromPath("fixture",
      "VECTMAP/other/+000+000/0_0.fmb", wrongMapX, wrongMapY));
  const Position origin{0.0, 0.0};
  assert(std::fabs(distanceMeters(origin, {0.0, 1.0}) - 111319.4908) < 0.1);
  assert(distanceMeters({80.0, 179.99}, {80.0, -179.99}) < 400.0);
  assert(!valid({NAN, 0.0}));
  assert(!valid({0.0, 181.0}));

  int32_t parsed = 0;
  size_t cursor = 0;
  assert(map_nearby_coverage::integer("-2147483648", cursor, parsed));
  assert(parsed == INT32_MIN);
  cursor = 0;
  assert(map_nearby_coverage::integer("2147483647", cursor, parsed));
  assert(parsed == INT32_MAX);
  cursor = 0;
  assert(!map_nearby_coverage::integer("-2147483649", cursor, parsed));
  cursor = 0;
  assert(!map_nearby_coverage::integer("2147483648", cursor, parsed));

  std::vector<map_nearby_coverage::Block> signedCoverage;
  assert(map_nearby_coverage::decodeManifest(
      "{\"nearbyCoverage\":{\"blockSizeMeters\":4096,"
      "\"blocks\":[[-1,0],[0,0],[1,0]],\"profileVersion\":1}}",
      signedCoverage));
  assert(signedCoverage.size() == 3);
  assert(map_nearby_coverage::contains(signedCoverage, {0, 0}));
  assert(!map_nearby_coverage::contains(signedCoverage, {0, 1}));
  assert(!map_nearby_coverage::decodeManifest(
      "{\"nearbyCoverage\":{\"blockSizeMeters\":4096,"
      "\"blocks\":[[0,0],[0,0]],\"profileVersion\":1}}",
      signedCoverage));
  assert(!map_nearby_coverage::decodeManifest(
      "{\"nearbyCoverage\":{\"profileVersion\":1,"
      "\"blockSizeMeters\":4096,\"blocks\":[[0,0]]}}",
      signedCoverage));
  for (int x = -10; x <= 10; ++x)
    for (int y = -10; y <= 10; ++y)
      signedCoverage.push_back({x, y});
  std::sort(signedCoverage.begin(), signedCoverage.end(),
            map_nearby_coverage::less);
  signedCoverage.erase(std::unique(signedCoverage.begin(), signedCoverage.end(),
      [](auto left, auto right) {
        return left.x == right.x && left.y == right.y;
      }), signedCoverage.end());
  assert(map_nearby_coverage::completeWithinRadius(signedCoverage, origin,
                                                   10000.0));
  signedCoverage.erase(std::lower_bound(signedCoverage.begin(),
      signedCoverage.end(), map_nearby_coverage::Block{0, 0},
      map_nearby_coverage::less));
  assert(!map_nearby_coverage::completeWithinRadius(signedCoverage, origin,
                                                    10000.0));
  assert(!map_nearby_coverage::completeWithinRadius(signedCoverage,
                                                    {80.0, 0.0}, 25000.0));

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
  NearestByCategory search(origin, 1, 10000.0);
  assert(search.consume(near, 0, records.data(), 12));
  assert(search.size() == 10);
  assert(search[0].recordOrdinal == 0);
  assert(search[9].recordOrdinal == 9);
  assert(search.canFinishBefore(search[9].directDistanceM + 1.0));
  NearestByCategory missingSecondCategory(origin, 3, 10000.0);
  assert(missingSecondCategory.consume(near, 0, records.data(), 12));
  assert(missingSecondCategory.size() == 10);
  assert(!missingSecondCategory.canFinishBefore(search[9].directDistanceM + 1.0));
  static_assert(sizeof(map_nearby_storage::SearchResult) <= 3072,
                "Nearby result copies must stay within the worker stack budget");
  static_assert(sizeof(NearestByCategory) <= 3072,
                "Nearby frontier must remain bounded per cursor");
  auto updatedDistance = search[0];
  updatedDistance.directDistanceM += 12.0;
  assert(sameRecord(search[0], updatedDistance));
  ++updatedDistance.recordOrdinal;
  assert(!sameRecord(search[0], updatedDistance));
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

  // Search across the anti-meridian at high latitude, not just compute a
  // wrapped distance. Both frontier pruning and result ordering must include
  // the nearby block on the opposite side of the longitude seam.
  const std::array<Position, 3> seamPlaces{{
      {80.0, 179.90}, {80.0, -179.99}, {80.0, -179.90}}};
  std::array<map_poi_index::Entry, seamPlaces.size()> seamIndex{};
  std::array<std::array<uint8_t, 8>, seamPlaces.size()> seamRecords{};
  for (size_t index = 0; index < seamPlaces.size(); ++index) {
    const double x = kMercatorRadiusM *
                     degreesToRadians(seamPlaces[index].longitude);
    const double y = kMercatorRadiusM * std::log(std::tan(
        kPi / 4.0 + degreesToRadians(seamPlaces[index].latitude) / 2.0));
    auto &entry = seamIndex[index];
    entry.blockX = static_cast<int32_t>(std::floor(x / kBlockSizeM));
    entry.blockY = static_cast<int32_t>(std::floor(y / kBlockSizeM));
    const auto localX = static_cast<uint16_t>(
        std::lround(x - double(entry.blockX) * kBlockSizeM));
    const auto localY = static_cast<uint16_t>(
        std::lround(y - double(entry.blockY) * kBlockSizeM));
    assert(localX <= 4095 && localY <= 4095);
    entry.categoryMask = 1;
    entry.categoryCounts = {1, 0, 0, 0, 0};
    entry.sectionOffset = 112;
    entry.sectionBytes = 16;
    seamRecords[index] = {
        static_cast<uint8_t>(localX), static_cast<uint8_t>(localX >> 8U),
        static_cast<uint8_t>(localY), static_cast<uint8_t>(localY >> 8U),
        1, 2, 0, 0};
  }
  assert(prepareFrontier(seamIndex.data(), seamIndex.size(), rider, 1,
                         25000.0, frontier));
  assert(frontier.size() == seamPlaces.size());
  NearestByCategory seamSearch(rider, 1, 25000.0);
  for (size_t index = 0; index < seamPlaces.size(); ++index)
    assert(seamSearch.consume(seamIndex[index], 0,
                              seamRecords[index].data(), 1));
  assert(seamSearch.size() == seamPlaces.size());
  assert(seamSearch[0].blockX == seamIndex[1].blockX);
  assert(seamSearch[1].blockX == seamIndex[0].blockX);
  assert(seamSearch[2].blockX == seamIndex[2].blockX);
  NearestByCategory seamRadiusSearch(rider, 1, 500.0);
  for (size_t index = 0; index < seamPlaces.size(); ++index)
    assert(seamRadiusSearch.consume(seamIndex[index], 0,
                                    seamRecords[index].data(), 1));
  assert(seamRadiusSearch.size() == 1);
  assert(seamRadiusSearch[0].blockX == seamIndex[1].blockX);

  // Equal-distance records must use stable record identity rather than SD
  // batch arrival order, including when they belong to different categories.
  auto tiedBlock = near;
  tiedBlock.categoryCounts = {1, 1, 0, 0, 0};
  tiedBlock.categoryMask = 3;
  tiedBlock.sectionBytes = 24;
  const std::array<uint8_t, 8> tiedShop{{0, 0, 0, 0, 1, 2, 0, 0}};
  const std::array<uint8_t, 8> tiedCafe{{0, 0, 0, 0, 2, 2, 0, 0}};
  NearestByCategory tiedSearch(origin, 3, 10000.0);
  assert(tiedSearch.consume(tiedBlock, 1, tiedCafe.data(), 1));
  assert(tiedSearch.consume(tiedBlock, 0, tiedShop.data(), 1));
  assert(tiedSearch.size() == 2);
  assert(tiedSearch[0].recordOrdinal == 0);
  assert(tiedSearch[1].recordOrdinal == 1);

  // Compare the bounded accumulator with a brute-force scan of every record.
  // Feed the distant block first so insertion order cannot mask rank errors.
  const std::array<int32_t, 4> blockXs{{8, 1, -1, 0}};
  std::array<map_poi_index::Entry, 4> denseIndex{};
  std::array<std::vector<uint8_t>, 4> denseRecords{};
  std::vector<Result> expected;
  constexpr uint32_t selectedCategories = (1U << 0) | (1U << 2) | (1U << 4);
  NearestByCategory denseSearch(origin, selectedCategories, 25000.0);
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
  std::array<size_t, 5> perCategory{};
  expected.erase(std::remove_if(expected.begin(), expected.end(),
      [&](const Result &result) { return perCategory[result.category - 1]++ >= 10; }),
      expected.end());
  assert(expected.size() == 30);
  assert(denseSearch.size() == expected.size());
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

  // Adding any other category preserves every restaurant identity.
  auto collect = [&](uint32_t mask) {
    NearestByCategory query(origin, mask, 25000.0);
    for (size_t block = 0; block < denseIndex.size(); ++block)
      assert(query.consume(denseIndex[block], 0, denseRecords[block].data(), 30));
    return query;
  };
  const auto restaurantsOnly = collect(1U << 1);
  assert(restaurantsOnly.size() == 10);
  for (uint32_t mask : {(1U << 1) | (1U << 2), (1U << 0) | (1U << 1), 0x1FU}) {
    const auto combined = collect(mask);
    assert(combined.size() == resultLimit(mask));
    size_t restaurant = 0;
    std::array<size_t, 5> counts{};
    for (size_t index = 0; index < combined.size(); ++index) {
      ++counts[combined[index].category - 1];
      if (index) assert(!better(combined[index], combined[index - 1]));
      if (combined[index].category == 2) {
        assert(restaurant < restaurantsOnly.size());
        assert(sameRecord(combined[index], restaurantsOnly[restaurant++]));
      }
    }
    assert(restaurant == restaurantsOnly.size());
    for (size_t category = 0; category < counts.size(); ++category)
      assert(counts[category] == ((mask & (1U << category)) ? 10U : 0U));
  }
  assert(resultLimit(0) == 0 && resultLimit(0x1F) == 50);

  testResumableCoverageMatchesSinglePass();
  assert(map_nearby_storage::openFailureStatus(ENOENT) ==
         map_nearby_storage::Status::Unavailable);
  for (int error : {EIO, EMFILE, ENFILE, EACCES, ENOMEM, ENOTDIR})
    assert(map_nearby_storage::openFailureStatus(error) ==
           map_nearby_storage::Status::ReadFailed);
  testHighLatitudeWindowIsEvaluatedInBoundedSteps();
  testCursorPublishesAfterResumableCoverage();

  std::cout << "Nearby query geometry and bounded per-category tests passed\n";
}
