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

inline bool memberInteger(std::string_view object, std::string_view name,
                          int32_t &value) {
  size_t cursor = object.find(name);
  if (cursor == std::string_view::npos) return false;
  cursor += name.size();
  return consume(object, cursor, ':') && integer(object, cursor, value) &&
         (cursor == object.size() || object[cursor] == ',' ||
          object[cursor] == '}' || object[cursor] == ' ' ||
          object[cursor] == '\n');
}

inline bool decodeManifestInto(std::string_view manifest,
                               std::vector<Block> &blocks) {
  blocks.clear();
  constexpr std::string_view needle = "\"nearbyCoverage\"";
  size_t cursor = manifest.find(needle);
  if (cursor == std::string_view::npos) return false;
  cursor += needle.size();
  if (!consume(manifest, cursor, ':') || !consume(manifest, cursor, '{'))
    return false;
  const size_t start = cursor - 1;
  // This profile has only primitive members and arrays, never nested objects.
  const size_t end = manifest.find('}', cursor);
  if (end == std::string_view::npos) return false;
  const std::string_view object = manifest.substr(start, end - start + 1);
  int32_t profile = 0, size = 0;
  if (!memberInteger(object, "\"profileVersion\"", profile) || profile != 1 ||
      !memberInteger(object, "\"blockSizeMeters\"", size) || size != 4096)
    return false;
  cursor = object.find("\"blocks\"");
  if (cursor == std::string_view::npos) return false;
  cursor += sizeof("\"blocks\"") - 1;
  if (!consume(object, cursor, ':') || !consume(object, cursor, '['))
    return false;
  bool afterComma = false;
  while (true) {
    skipSpace(object, cursor);
    if (cursor >= object.size()) return false;
    if (object[cursor] == ']') {
      if (afterComma) return false;
      ++cursor;
      break;
    }
    if (blocks.size() >= kMaximumBlocks || !consume(object, cursor, '['))
      return false;
    Block block;
    if (!integer(object, cursor, block.x) || !consume(object, cursor, ',') ||
        !integer(object, cursor, block.y) || !consume(object, cursor, ']') ||
        block.x < -4893 || block.x > 4893 ||
        block.y < -4893 || block.y > 4893 ||
        (!blocks.empty() && !less(blocks.back(), block))) return false;
    blocks.push_back(block);
    afterComma = false;
    skipSpace(object, cursor);
    if (cursor < object.size() && object[cursor] == ',') {
      ++cursor;
      afterComma = true;
      continue;
    }
    if (cursor < object.size() && object[cursor] == ']') {
      ++cursor;
      break;
    }
    return false;
  }
  return !blocks.empty();
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
inline bool completeWithinRadius(const std::vector<Block> &blocks,
                                 map_nearby_query::Position rider,
                                 double radiusM) {
  using namespace map_nearby_query;
  if (blocks.empty() || !valid(rider) || !std::isfinite(radiusM) ||
      radiusM <= 0.0 || radiusM > 25000.0 ||
      std::fabs(rider.latitude) >= 85.05112878) return false;
  const double angle = radiusM / kWgs84MinimumRadiusM;
  const double latitudeDelta = angle * 180.0 / kPi;
  const double extremeLatitude = std::fabs(rider.latitude) + latitudeDelta;
  if (extremeLatitude >= 85.05112878) return false;
  const double minimumCosine = std::cos(degreesToRadians(extremeLatitude));
  const double x = kMercatorRadiusM * degreesToRadians(rider.longitude);
  const double y = kMercatorRadiusM *
      std::log(std::tan(kPi / 4.0 + degreesToRadians(rider.latitude) / 2.0));
  const double projectedRadius =
      radiusM * kMercatorRadiusM / (kWgs84MinimumRadiusM * minimumCosine) +
      kBlockSizeM;
  const int32_t firstX = static_cast<int32_t>(std::floor((x - projectedRadius) /
                                                         kBlockSizeM));
  const int32_t lastX = static_cast<int32_t>(std::floor((x + projectedRadius) /
                                                        kBlockSizeM));
  const int32_t firstY = static_cast<int32_t>(std::floor((y - projectedRadius) /
                                                         kBlockSizeM));
  const int32_t lastY = static_cast<int32_t>(std::floor((y + projectedRadius) /
                                                        kBlockSizeM));
  for (int32_t blockX = firstX; blockX <= lastX; ++blockX)
    for (int32_t blockY = firstY; blockY <= lastY; ++blockY) {
      map_poi_index::Entry entry;
      entry.blockX = blockX;
      entry.blockY = blockY;
      const double bound = blockLowerBoundMeters(rider, entry);
      if ((!std::isfinite(bound) || bound <= radiusM) &&
          !contains(blocks, {blockX, blockY})) return false;
    }
  return true;
}
} // namespace map_nearby_coverage
