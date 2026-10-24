#pragma once

#include "mapNearbyQuery.hpp"

#include <cmath>
#include <cstdint>
#include <string_view>
#include <vector>

// Signed target-5 selection coverage, including blocks that emitted no FMB.
// FPI1 only lists nonempty POI blocks and cannot answer this question.
namespace map_nearby_coverage {
constexpr size_t kMaximumBlocks = 1024;

struct Block {
  int32_t x = 0;
  int32_t y = 0;
};

inline bool less(Block left, Block right) {
  return left.x != right.x ? left.x < right.x : left.y < right.y;
}

inline void skipSpace(std::string_view text, size_t &cursor) {
  while (cursor < text.size() &&
         (text[cursor] == ' ' || text[cursor] == '\n' ||
          text[cursor] == '\r' || text[cursor] == '\t')) ++cursor;
}

inline bool consume(std::string_view text, size_t &cursor, char value) {
  skipSpace(text, cursor);
  if (cursor >= text.size() || text[cursor] != value) return false;
  ++cursor;
  return true;
}

inline bool integer(std::string_view text, size_t &cursor, int32_t &value) {
  skipSpace(text, cursor);
  if (cursor >= text.size()) return false;
  const bool negative = text[cursor] == '-';
  if (negative) ++cursor;
  if (cursor >= text.size() || text[cursor] < '0' || text[cursor] > '9')
    return false;
  if (text[cursor] == '0' && cursor + 1 < text.size() &&
      text[cursor + 1] >= '0' && text[cursor + 1] <= '9') return false;
  // Accumulate negatively so INT32_MIN is representable without 64-bit math.
  const int32_t limit = negative ? INT32_MIN : -INT32_MAX;
  int32_t number = 0;
  do {
    const int32_t digit = text[cursor++] - '0';
    if (number < limit / 10 ||
        (number == limit / 10 && digit > -(limit % 10))) return false;
    number = number * 10 - digit;
  } while (cursor < text.size() && text[cursor] >= '0' &&
           text[cursor] <= '9');
  value = negative ? number : -number;
  return true;
}

inline bool field(std::string_view text, size_t &cursor,
                  std::string_view name) {
  skipSpace(text, cursor);
  if (text.substr(cursor, name.size()) != name) return false;
  cursor += name.size();
  return consume(text, cursor, ':');
}

inline bool decodeManifestInto(std::string_view manifest,
                               std::vector<Block> &blocks) {
  blocks.clear();
  constexpr std::string_view needle = "\"nearbyCoverage\"";
  size_t cursor = manifest.find(needle);
  // Only the key is followed by a colon; skip a string value equal to it,
  // such as a user's map display name.
  while (cursor != std::string_view::npos) {
    size_t value = cursor + needle.size();
    if (consume(manifest, value, ':')) {
      cursor = value;
      break;
    }
    cursor = manifest.find(needle, cursor + 1);
  }
  if (cursor == std::string_view::npos || !consume(manifest, cursor, '{'))
    return false;
  // Both the archive producer and the signed stream serialize sorted keys.
  // Requiring that order keeps the device reader small and fail-closed.
  int32_t size = 0;
  if (!field(manifest, cursor, "\"blockSizeMeters\"") ||
      !integer(manifest, cursor, size) || size != 4096 ||
      !consume(manifest, cursor, ',') ||
      !field(manifest, cursor, "\"blocks\"") ||
      !consume(manifest, cursor, '['))
    return false;
  bool afterComma = false;
  while (true) {
    skipSpace(manifest, cursor);
    if (cursor >= manifest.size()) return false;
    if (manifest[cursor] == ']') {
      if (afterComma) return false;
      ++cursor;
      break;
    }
    if (blocks.size() >= kMaximumBlocks || !consume(manifest, cursor, '['))
      return false;
    Block block;
    if (!integer(manifest, cursor, block.x) ||
        !consume(manifest, cursor, ',') ||
        !integer(manifest, cursor, block.y) ||
        !consume(manifest, cursor, ']') ||
        block.x < -4893 || block.x > 4893 ||
        block.y < -4893 || block.y > 4893 ||
        (!blocks.empty() && !less(blocks.back(), block))) return false;
    blocks.push_back(block);
    afterComma = false;
    skipSpace(manifest, cursor);
    if (cursor < manifest.size() && manifest[cursor] == ',') {
      ++cursor;
      afterComma = true;
      continue;
    }
    if (cursor < manifest.size() && manifest[cursor] == ']') {
      ++cursor;
      break;
    }
    return false;
  }
  int32_t profile = 0;
  return !blocks.empty() && consume(manifest, cursor, ',') &&
         field(manifest, cursor, "\"profileVersion\"") &&
         integer(manifest, cursor, profile) && profile == 1 &&
         consume(manifest, cursor, '}');
}

inline bool decodeManifest(std::string_view manifest,
                           std::vector<Block> &blocks) {
  if (!decodeManifestInto(manifest, blocks)) {
    blocks.clear();
    return false;
  }
  return true;
}

inline bool contains(const std::vector<Block> &blocks, Block block) {
  size_t first = 0;
  size_t count = blocks.size();
  while (count != 0) {
    const size_t half = count / 2;
    const size_t middle = first + half;
    if (less(blocks[middle], block)) {
      first = middle + 1;
      count -= half + 1;
    } else {
      count = half;
    }
  }
  return first < blocks.size() && blocks[first].x == block.x &&
         blocks[first].y == block.y;
}

// Conservative: warn whenever any block that might meet the WGS-84 search
// circle was not selected. Extra warnings near boundaries are acceptable;
// falsely claiming a searched-but-undownloaded area is not.
//
// Resumable so the sole map worker never evaluates a whole window in one slice:
// a 25 km window near the Mercator limit spans about 21,000 blocks. Any split
// into bounded steps yields the same answer as one uninterrupted evaluation.
class CompletenessScan {
 public:
  // A default scan is finished and incomplete.
  CompletenessScan() = default;
  CompletenessScan(const std::vector<Block> &blocks,
                   map_nearby_query::Position rider, double radiusM)
      : blocks_(&blocks), rider_(rider), radiusM_(radiusM) {
    using namespace map_nearby_query;
    if (blocks.empty() || !valid(rider) || !std::isfinite(radiusM) ||
        radiusM <= 0.0 || radiusM > 25000.0 ||
        std::fabs(rider.latitude) >= 85.05112878) return;
    const double angle = radiusM / kWgs84MinimumRadiusM;
    const double latitudeDelta = angle * 180.0 / kPi;
    const double extremeLatitude = std::fabs(rider.latitude) + latitudeDelta;
    if (extremeLatitude >= 85.05112878) return;
    const double minimumCosine = std::cos(degreesToRadians(extremeLatitude));
    const double x = kMercatorRadiusM * degreesToRadians(rider.longitude);
    const double y = kMercatorRadiusM *
        std::log(std::tan(kPi / 4.0 + degreesToRadians(rider.latitude) / 2.0));
    const double projectedRadius =
        radiusM * kMercatorRadiusM / (kWgs84MinimumRadiusM * minimumCosine) +
        kBlockSizeM;
    firstX_ = static_cast<int32_t>(std::floor((x - projectedRadius) / kBlockSizeM));
    lastX_ = static_cast<int32_t>(std::floor((x + projectedRadius) / kBlockSizeM));
    firstY_ = static_cast<int32_t>(std::floor((y - projectedRadius) / kBlockSizeM));
    lastY_ = static_cast<int32_t>(std::floor((y + projectedRadius) / kBlockSizeM));
    blockX_ = firstX_;
    blockY_ = firstY_;
    done_ = false;
  }

  bool done() const { return done_; }
  bool complete() const { return done_ && complete_; }
  uint32_t evaluatedBlocks() const { return evaluated_; }

  // Evaluates at most `budget` window blocks; returns done().
  bool step(uint32_t budget) {
    for (; !done_ && budget != 0; --budget) {
      ++evaluated_;
      // The selection test is a binary search; only unselected blocks need
      // the trigonometric distance bound, which is costly on the ESP32-S3.
      if (!contains(*blocks_, {blockX_, blockY_})) {
        map_poi_index::Entry entry;
        entry.blockX = blockX_;
        entry.blockY = blockY_;
        const double bound =
            map_nearby_query::blockLowerBoundMeters(rider_, entry);
        if (!std::isfinite(bound) || bound <= radiusM_) {
          done_ = true;
          return true;
        }
      }
      if (blockY_ != lastY_) ++blockY_;
      else if (blockX_ != lastX_) {
        ++blockX_;
        blockY_ = firstY_;
      } else {
        complete_ = true;
        done_ = true;
      }
    }
    return done_;
  }

 private:
  const std::vector<Block> *blocks_ = nullptr;
  map_nearby_query::Position rider_{};
  double radiusM_ = 0.0;
  int32_t firstX_ = 0, lastX_ = 0, firstY_ = 0, lastY_ = 0;
  int32_t blockX_ = 0, blockY_ = 0;
  uint32_t evaluated_ = 0;
  bool done_ = true;
  bool complete_ = false;
};

inline bool completeWithinRadius(const std::vector<Block> &blocks,
                                 map_nearby_query::Position rider,
                                 double radiusM) {
  CompletenessScan scan(blocks, rider, radiusM);
  while (!scan.step(UINT32_MAX)) {}
  return scan.complete();
}
} // namespace map_nearby_coverage
