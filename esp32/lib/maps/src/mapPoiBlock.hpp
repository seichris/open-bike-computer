#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T> using MapPoiVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapPoiVector = std::vector<T>;
#endif

namespace map_poi_block {

enum class Category : uint8_t {
  Shops = 1,
  RestaurantsAndCafes = 2,
  PublicToilets = 3,
  GasStations = 4,
  BicycleServices = 5,
};

struct Record {
  int16_t localX = 0;
  int16_t localY = 0;
  Category category = Category::Shops;
  uint8_t maximumZoom = 0;
  uint8_t rank = 0;
};

struct Stats {
  uint32_t records = 0;
  std::array<uint32_t, 5> categories = {};
};

struct Block {
  MapPoiVector<Record> records;
  Stats stats;

  void clear() {
    records.clear();
    stats = {};
  }
  size_t decodedBytes() const { return records.capacity() * sizeof(Record); }
};

// Decodes required FMB v5 section type 5 after strict whole-block validation.
// Older valid FMB blocks produce an empty POI block.
bool decode(const uint8_t *data, size_t size, Block &output,
            std::string *error = nullptr);

} // namespace map_poi_block
