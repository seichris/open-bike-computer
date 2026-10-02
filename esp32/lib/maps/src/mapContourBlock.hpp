#pragma once
#include <algorithm>
#include "mapBlockFormat.hpp"
#include "mapBuildingBlock.hpp"
#include "mapByteOrder.hpp"

namespace map_contour_block {
struct Record {
  int16_t elevationM = 0;
  uint8_t flags = 0;
  uint32_t pointOffset = 0;
  uint16_t pointCount = 0;
  int16_t minX = 0, minY = 0, maxX = 0, maxY = 0;
};
struct Block {
  uint16_t minorIntervalM = 0, indexIntervalM = 0;
  MapBuildingVector<Record> records;
  MapBuildingVector<map_building_block::Point> points;
  size_t decodedBytes() const {
    return records.capacity() * sizeof(Record) + points.capacity() * sizeof(map_building_block::Point);
  }
};

inline bool decode(const uint8_t *data, size_t size, Block &output,
                   bool (*cancelled)() = nullptr) {
  output = {};
  if (!data || size < 4) return false;
  map_block_format::StreamValidator validator("block.fmb");
  for (size_t offset = 0; offset < size; offset += 1024) {
    if ((cancelled && cancelled()) || !validator.feed(data + offset, std::min(size - offset, size_t(1024)))) return false;
  }
  if (!validator.finish()) return false;
  if (data[3] < 5) return true;
  // All offsets/counts below have passed the allocation-free streaming walk.
  const auto u16 = [&](size_t offset) { return map_byte_order::readLe16(data + offset); };
  const auto u32 = [&](size_t offset) {
    return uint32_t(u16(offset)) | (uint32_t(u16(offset + 2)) << 16);
  };
  const auto s16 = [&](size_t offset) { return static_cast<int16_t>(u16(offset)); };
  size_t offset = 4;
  for (size_t kind = 0; kind < 2; ++kind) {
    const uint16_t count = u16(offset); offset += 2;
    for (uint16_t index = 0; index < count; ++index) {
      if (cancelled && cancelled()) return false;
      offset += kind == 0 ? 12 : 13;
      const uint16_t points = u16(offset); offset += 2 + size_t(points) * 4;
    }
  }
  offset = u32(offset + 8 + 4 * 16 + 4);
  Block result;
  result.minorIntervalM = u16(offset + 2); result.indexIntervalM = u16(offset + 4);
  const uint16_t count = u16(offset + 6);
  result.records.reserve(count); result.points.reserve(u32(offset + 8));
  offset += 12;
  for (uint16_t index = 0; index < count; ++index) {
    if (cancelled && cancelled()) return false;
    Record record;
    record.elevationM = s16(offset); record.flags = data[offset + 2];
    record.pointCount = u16(offset + 4); record.pointOffset = result.points.size();
    record.minX = s16(offset + 6); record.minY = s16(offset + 8);
    record.maxX = s16(offset + 10); record.maxY = s16(offset + 12); offset += 14;
    int16_t x = 0, y = 0;
    for (uint16_t point = 0; point < record.pointCount; ++point) {
      if ((point & 31U) == 0 && cancelled && cancelled()) return false;
      x += s16(offset); y += s16(offset + 2); offset += 4;
      result.points.push_back({x, y});
    }
    result.records.push_back(record);
  }
  output = std::move(result);
  return true;
}
} // namespace map_contour_block
