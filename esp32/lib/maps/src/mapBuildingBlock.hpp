#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T>
using MapBuildingVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapBuildingVector = std::vector<T>;
#endif

namespace map_building_block {

struct Point {
  int16_t x = 0;
  int16_t y = 0;
};

struct Ring {
  bool hole = false;
  MapBuildingVector<Point> points;
  MapBuildingVector<uint8_t> walls;
};

struct Building {
  uint8_t typeId = 100;
  uint8_t flags = 0;
  uint8_t provenance = 0;
  uint16_t heightDm = 0;
  uint16_t minimumHeightDm = 0;
  int16_t minX = 0;
  int16_t minY = 0;
  int16_t maxX = 0;
  int16_t maxY = 0;
  MapBuildingVector<Ring> rings;
};

struct Stats {
  uint32_t records = 0;
  uint32_t rings = 0;
  uint32_t points = 0;
  std::array<uint32_t, 5> provenance = {};
};

struct Block {
  MapBuildingVector<Building> buildings;
  Stats stats;
  void clear() {
    buildings.clear();
    stats = {};
  }
  size_t decodedBytes() const;
};

// Decodes FMB v4 section type 4 after the strict block validator succeeds.
// Older FMB versions are valid and produce an empty block.
bool decode(const uint8_t *data, size_t size, Block &output,
            std::string *error = nullptr);

} // namespace map_building_block
