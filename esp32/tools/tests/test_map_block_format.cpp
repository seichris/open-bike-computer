#include "../../lib/maps/src/mapBlockFormat.hpp"
#include "../../lib/maps/src/mapBuildingBlock.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

static void append16(std::vector<uint8_t> &data, uint16_t value) {
  data.push_back(static_cast<uint8_t>(value));
  data.push_back(static_cast<uint8_t>(value >> 8U));
}

static void append32(std::vector<uint8_t> &data, uint32_t value) {
  for (uint8_t shift = 0; shift < 32; shift += 8)
    data.push_back(static_cast<uint8_t>(value >> shift));
}

static void write32(std::vector<uint8_t> &data, size_t offset,
                    uint32_t value) {
  for (uint8_t shift = 0; shift < 32; shift += 8)
    data[offset++] = static_cast<uint8_t>(value >> shift);
}

static uint32_t crc32(const std::vector<uint8_t> &data) {
  uint32_t crc = 0xFFFFFFFFU;
  for (const uint8_t byte : data) {
    crc ^= byte;
    for (uint8_t bit = 0; bit < 8; ++bit)
      crc = (crc >> 1U) ^ (0xEDB88320U & (0U - (crc & 1U)));
  }
  return crc ^ 0xFFFFFFFFU;
}

static std::vector<uint8_t> emptyV3() {
  std::vector<uint8_t> data = {'F', 'M', 'B', 3, 0, 0, 0, 0,
                               'E', 'X', 'T', '3', 3, 0, 0, 0};
  const std::vector<std::vector<uint8_t>> sections = {
      {0, 0},             // zero strings
      {0, 0},             // zero shaped runs
      {0x78, 0x56, 0x34, 0x12, 0, 0}, // profile + zero labels
  };
  uint32_t offset = static_cast<uint32_t>(data.size() + 3U * 16U);
  for (uint8_t index = 0; index < sections.size(); ++index) {
    data.push_back(index + 1);
    data.push_back(1);
    append16(data, 0);
    append32(data, offset);
    append32(data, static_cast<uint32_t>(sections[index].size()));
    append32(data, crc32(sections[index]));
    offset += sections[index].size();
  }
  for (const auto &section : sections)
    data.insert(data.end(), section.begin(), section.end());
  return data;
}

static std::vector<uint8_t> oneBuildingV4() {
  std::vector<uint8_t> data = {'F', 'M', 'B', 4, 0, 0, 0, 0,
                               'E', 'X', 'T', '4', 4, 0, 0, 0};
  std::vector<uint8_t> buildings;
  append16(buildings, 1); // one building
  append16(buildings, 0); // reserved
  append32(buildings, 4); // four declared points
  buildings.insert(buildings.end(), {
      100, 1, 0, 0,       // type, flags, provenance, reserved
      123, 0, 20, 0,      // height 12.3 m, minimum height 2.0 m
      0, 0, 0, 0,         // minimum x/y
      100, 0, 100, 0,     // maximum x/y
      1, 0,                // one ring
      4, 0, 0, 0,         // four-point outer ring
      0, 0, 0, 0,
      100, 0, 0, 0,
      100, 0, 100, 0,
      0, 0, 100, 0,
      0x0f,                // every source edge may render a wall
  });
  const std::vector<std::vector<uint8_t>> sections = {
      {0, 0},
      {0, 0},
      {0x78, 0x56, 0x34, 0x12, 0, 0},
      buildings,
  };
  uint32_t offset = static_cast<uint32_t>(data.size() + 4U * 16U);
  for (uint8_t index = 0; index < sections.size(); ++index) {
    data.push_back(index + 1);
    data.push_back(1);
    append16(data, 0);
    append32(data, offset);
    append32(data, static_cast<uint32_t>(sections[index].size()));
    append32(data, crc32(sections[index]));
    offset += sections[index].size();
  }
  for (const auto &section : sections)
    data.insert(data.end(), section.begin(), section.end());
  return data;
}

int main() {
  const std::vector<uint8_t> emptyV1 = {'F', 'M', 'B', 1, 0, 0, 0, 0};
  assert(map_block_format::validate(emptyV1.data(), emptyV1.size()));
  const std::vector<uint8_t> valid = {
      'F', 'M', 'B', 2,
      1,   0,                         // one polygon
      0x34, 0x12, 15, 100,           // color, zoom, type
      0, 0, 0, 0, 10, 0, 10, 0,     // bbox
      2, 0, 0, 0, 0, 0, 10, 0, 10, 0, // points
      1, 0,                           // one polyline
      0x34, 0x12, 2, 15, 7,          // color, width, zoom, type
      0, 0, 0, 0, 10, 0, 10, 0,     // bbox
      1, 0, 5, 0, 5, 0};             // point
  assert(map_block_format::validate(valid.data(), valid.size()));
  for (size_t size = 0; size < valid.size(); ++size)
    assert(!map_block_format::validate(valid.data(), size));

  const std::vector<uint8_t> validV3 = emptyV3();
  assert(map_block_format::validate(validV3.data(), validV3.size()));
  for (size_t size = 0; size < validV3.size(); ++size)
    assert(!map_block_format::validate(validV3.data(), size));

  auto changed = validV3;
  changed.back() ^= 1;
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = validV3;
  changed[20] += 1; // first section offset is no longer contiguous
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = validV3;
  changed.push_back(0);
  assert(!map_block_format::validate(changed.data(), changed.size()));

  const std::vector<uint8_t> validV4 = oneBuildingV4();
  assert(map_block_format::validate(validV4.data(), validV4.size()));
  map_building_block::Block buildingBlock;
  std::string buildingError;
  assert(map_building_block::decode(validV4.data(), validV4.size(),
                                    buildingBlock, &buildingError));
  assert(buildingBlock.buildings.size() == 1);
  assert(buildingBlock.buildings[0].heightDm == 123);
  assert(buildingBlock.buildings[0].minimumHeightDm == 20);
  assert(buildingBlock.buildings[0].rings.size() == 1);
  assert(buildingBlock.buildings[0].rings[0].points.size() == 4);
  assert(buildingBlock.buildings[0].rings[0].walls.size() == 4);
  for (const uint8_t wall : buildingBlock.buildings[0].rings[0].walls)
    assert(wall == 1);
  for (size_t size = 0; size < validV4.size(); ++size)
    assert(!map_block_format::validate(validV4.data(), size));

  changed = validV4;
  changed[99] = 2;   // flat outline base
  changed.back() = 0; // flat bases have no walls
  write32(changed, 76,
          crc32(std::vector<uint8_t>(changed.begin() + 90, changed.end())));
  assert(map_block_format::validate(changed.data(), changed.size()));
  assert(map_building_block::decode(changed.data(), changed.size(),
                                    buildingBlock, &buildingError));
  assert(buildingBlock.buildings[0].flags == 2);
  for (const uint8_t wall : buildingBlock.buildings[0].rings[0].walls)
    assert(wall == 0);

  changed = validV4;
  changed[99] = 2; // flat outline with non-zero wall bits is non-canonical
  write32(changed, 76,
          crc32(std::vector<uint8_t>(changed.begin() + 90, changed.end())));
  assert(!map_block_format::validate(changed.data(), changed.size()));

  changed = validV4;
  changed[99] = 3; // a building part cannot also be an outline base
  write32(changed, 76,
          crc32(std::vector<uint8_t>(changed.begin() + 90, changed.end())));
  assert(!map_block_format::validate(changed.data(), changed.size()));

  changed = validV4;
  changed.back() = 0x8f; // non-canonical wall-mask padding
  write32(changed, 76,
          crc32(std::vector<uint8_t>(changed.begin() + 90, changed.end())));
  assert(!map_block_format::validate(changed.data(), changed.size()));
  assert(!map_building_block::decode(changed.data(), changed.size(),
                                     buildingBlock, &buildingError));

  changed = valid;
  changed.push_back(0);
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = valid;
  changed[18] = 0xff;
  changed[19] = 0xff;
  assert(!map_block_format::validate(changed.data(), changed.size()));

  const std::vector<uint8_t> tooManyFeatures = {'F', 'M', 'B', 1,
                                                 1,   0x40};
  map_block_format::StreamValidator featureBudget("tile.fmb");
  assert(!featureBudget.feed(tooManyFeatures.data(),
                             tooManyFeatures.size()));
  std::vector<uint8_t> oversized(map_block_format::kMaximumBlockBytes + 1,
                                 0);
  map_block_format::StreamValidator byteBudget("tile.fmb");
  assert(!byteBudget.feed(oversized.data(), oversized.size()));
  std::string pointHeavy =
      "Polygons:1\n0x1\n15\nbbox:0,0,1,1\ncoords:";
  for (uint32_t index = 0; index <= map_block_format::kMaximumPoints; ++index)
    pointHeavy += "0,0;";
  pointHeavy += "\nPolylines:0\n";
  map_block_format::StreamValidator pointBudget("tile.fmp");
  assert(!pointBudget.feed(
      reinterpret_cast<const uint8_t *>(pointHeavy.data()),
      pointHeavy.size()));

  std::vector<uint8_t> gridHeavy = {'F', 'M', 'B', 1, 1, 4};
  for (uint32_t index = 0;
       index <= map_block_format::kMaximumPolygonGridEntries / 256U;
       ++index) {
    const std::vector<uint8_t> polygon = {
        0, 0, 15,                    // color, zoom
        0, 0, 0, 0, 0xff, 0x0f, 0xff, 0x0f, // full-grid bbox
        1, 0, 0, 0, 0, 0};          // one point
    gridHeavy.insert(gridHeavy.end(), polygon.begin(), polygon.end());
  }
  gridHeavy.push_back(0);
  gridHeavy.push_back(0);
  map_block_format::StreamValidator gridBudget("tile.fmb");
  assert(!gridBudget.feed(gridHeavy.data(), gridHeavy.size()));

  map_block_format::StreamValidator binaryStream("tile.fmb");
  for (const uint8_t byte : valid)
    assert(binaryStream.feed(&byte, 1));
  assert(binaryStream.finish());

  const std::string legacyAscii =
      "Polygons:1\n0x1234\n15\nbbox:-1,-2,3,4\ncoords:-1,-2;3,4;\n"
      "Polylines:1\n0x5678\n2\n14\nbbox:0,0,5,6\ncoords:0,0;5,6;\n";
  map_block_format::StreamValidator legacy("tile.fmp");
  for (const char byte : legacyAscii)
    assert(legacy.feed(reinterpret_cast<const uint8_t *>(&byte), 1));
  assert(legacy.finish());

  std::string missingFinalNewline = legacyAscii;
  missingFinalNewline.pop_back();
  map_block_format::StreamValidator missingNewline("tile.fmp");
  assert(missingNewline.feed(
      reinterpret_cast<const uint8_t *>(missingFinalNewline.data()),
      missingFinalNewline.size()));
  assert(!missingNewline.finish());

  std::string uppercaseColor = legacyAscii;
  uppercaseColor.replace(uppercaseColor.find("0x1234"), 2, "0X");
  map_block_format::StreamValidator uppercase("tile.fmp");
  assert(!uppercase.feed(
      reinterpret_cast<const uint8_t *>(uppercaseColor.data()),
      uppercaseColor.size()));

  const std::string typedAscii =
      "Polygons:1\n0x1234\n15\n101\nbbox:-1,-2,3,4\ncoords:-1,-2;3,4;\n"
      "Polylines:1\n0x5678\n2\n14\n7\nbbox:0,0,5,6\ncoords:0,0;5,6;\n";
  map_block_format::StreamValidator typed("tile.fmp");
  assert(typed.feed(reinterpret_cast<const uint8_t *>(typedAscii.data()),
                    typedAscii.size()));
  assert(typed.finish());

  for (const std::string &invalid : {
           std::string("Polygons:0\n"),
           std::string("Polygons:1\n0x1\n15\nbbox:0,0,1,1\ncoords:\n") +
               "Polylines:0\n",
           std::string("Polygons:1\n0x1\n15\nbbox:999999999999999999,0,1,1\n") +
               "coords:0,0;\nPolylines:0\n",
           std::string("Polygons:1\n0x1\n15\nbbox:0,0,1,1\n") +
               "coords:999999999999999999,0;\nPolylines:0\n",
           typedAscii + "x",
       }) {
    map_block_format::StreamValidator rejected("tile.fmp");
    const bool fed = rejected.feed(
        reinterpret_cast<const uint8_t *>(invalid.data()), invalid.size());
    assert(!fed || !rejected.finish());
  }

  std::cout << "map block format tests passed\n";
  return 0;
}
