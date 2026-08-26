#include "../../lib/maps/src/mapBlockFormat.hpp"
#include "../../lib/maps/src/mapBuildingBlock.hpp"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

static void write32(std::vector<uint8_t> &data, size_t offset,
                    uint32_t value) {
  for (uint8_t shift = 0; shift < 32; shift += 8)
    data[offset++] = static_cast<uint8_t>(value >> shift);
}

static uint32_t read32(const std::vector<uint8_t> &data, size_t offset) {
  return static_cast<uint32_t>(data[offset]) |
         (static_cast<uint32_t>(data[offset + 1]) << 8U) |
         (static_cast<uint32_t>(data[offset + 2]) << 16U) |
         (static_cast<uint32_t>(data[offset + 3]) << 24U);
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

static uint8_t hexNibble(char value) {
  if (value >= '0' && value <= '9')
    return static_cast<uint8_t>(value - '0');
  if (value >= 'a' && value <= 'f')
    return static_cast<uint8_t>(value - 'a' + 10);
  if (value >= 'A' && value <= 'F')
    return static_cast<uint8_t>(value - 'A' + 10);
  throw std::runtime_error("invalid hex in golden FMB fixture");
}

static std::map<std::string, std::vector<uint8_t>> loadGoldenBlocks() {
  std::filesystem::path source =
      std::filesystem::absolute(std::filesystem::path(__FILE__));
  std::filesystem::path repository = source;
  for (uint8_t depth = 0; depth < 4; ++depth)
    repository = repository.parent_path();
  const std::filesystem::path fixture =
      repository / "test-fixtures/fmb/golden_blocks.txt";
  std::ifstream input(fixture);
  if (!input)
    throw std::runtime_error("could not open golden FMB fixture: " +
                             fixture.string());

  std::map<std::string, std::vector<uint8_t>> blocks;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#')
      continue;
    const size_t separator = line.find('=');
    if (separator == std::string::npos || (line.size() - separator - 1) % 2)
      throw std::runtime_error("invalid golden FMB fixture line");
    std::vector<uint8_t> bytes;
    bytes.reserve((line.size() - separator - 1) / 2);
    for (size_t index = separator + 1; index < line.size(); index += 2) {
      bytes.push_back(static_cast<uint8_t>(hexNibble(line[index]) << 4U) |
                      hexNibble(line[index + 1]));
    }
    blocks.emplace(line.substr(0, separator), std::move(bytes));
  }
  return blocks;
}

static size_t extensionOffset(const std::vector<uint8_t> &data,
                              uint8_t version) {
  const std::vector<uint8_t> magic = {'E', 'X', 'T',
                                      static_cast<uint8_t>('0' + version)};
  const auto found = std::search(data.begin(), data.end(), magic.begin(),
                                 magic.end());
  if (found == data.end())
    throw std::runtime_error("golden FMB extension directory is missing");
  return static_cast<size_t>(found - data.begin());
}

static size_t sectionEntryOffset(const std::vector<uint8_t> &data,
                                 uint8_t version, uint8_t sectionType) {
  return extensionOffset(data, version) + 8U +
         static_cast<size_t>(sectionType - 1U) * 16U;
}

static void refreshSectionCrc(std::vector<uint8_t> &data,
                              size_t entryOffset) {
  const size_t sectionOffset = read32(data, entryOffset + 4U);
  const size_t sectionLength = read32(data, entryOffset + 8U);
  const std::vector<uint8_t> section(
      data.begin() + static_cast<std::ptrdiff_t>(sectionOffset),
      data.begin() +
          static_cast<std::ptrdiff_t>(sectionOffset + sectionLength));
  write32(data, entryOffset + 12U, crc32(section));
}

int main() {
  static_assert(map_block_format::kMaximumBuildings == 12288);
  const auto golden = loadGoldenBlocks();
  assert(golden.size() == 4);
  const std::vector<uint8_t> &validV1 = golden.at("fmb_v1");
  const std::vector<uint8_t> &valid = golden.at("fmb_v2");
  const std::vector<uint8_t> &validV3 = golden.at("fmb_v3");
  const std::vector<uint8_t> &validV4 = golden.at("fmb_v4");

  assert(map_block_format::validate(validV1.data(), validV1.size()));
  for (size_t size = 0; size < validV1.size(); ++size)
    assert(!map_block_format::validate(validV1.data(), size));
  assert(map_block_format::validate(valid.data(), valid.size()));
  for (size_t size = 0; size < valid.size(); ++size)
    assert(!map_block_format::validate(valid.data(), size));

  assert(map_block_format::validate(validV3.data(), validV3.size()));
  for (size_t size = 0; size < validV3.size(); ++size)
    assert(!map_block_format::validate(validV3.data(), size));

  auto changed = validV3;
  changed.back() ^= 1;
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = validV3;
  const size_t firstV3Entry = sectionEntryOffset(validV3, 3, 1);
  changed[firstV3Entry + 4U] += 1; // first section is no longer contiguous
  assert(!map_block_format::validate(changed.data(), changed.size()));
  changed = validV3;
  changed.push_back(0);
  assert(!map_block_format::validate(changed.data(), changed.size()));

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
  assert(buildingBlock.stats.records == 1);
  assert(buildingBlock.stats.rings == 1);
  assert(buildingBlock.stats.points == 4);
  assert(buildingBlock.stats.provenance[0] == 1);
  assert(buildingBlock.stats.provenance[1] == 0);
  for (const uint8_t wall : buildingBlock.buildings[0].rings[0].walls)
    assert(wall == 1);
  for (size_t size = 0; size < validV4.size(); ++size)
    assert(!map_block_format::validate(validV4.data(), size));

  const size_t buildingEntry = sectionEntryOffset(validV4, 4, 4);
  const size_t buildingSection = read32(validV4, buildingEntry + 4U);
  const size_t buildingFlags = buildingSection + 8U + 1U;

  changed = validV4;
  changed[buildingFlags] = 2; // flat outline base
  changed.back() = 0; // flat bases have no walls
  refreshSectionCrc(changed, buildingEntry);
  assert(map_block_format::validate(changed.data(), changed.size()));
  assert(map_building_block::decode(changed.data(), changed.size(),
                                    buildingBlock, &buildingError));
  assert(buildingBlock.buildings[0].flags == 2);
  for (const uint8_t wall : buildingBlock.buildings[0].rings[0].walls)
    assert(wall == 0);

  changed = validV4;
  changed[buildingFlags] = 2; // flat outline with non-zero walls is invalid
  refreshSectionCrc(changed, buildingEntry);
  assert(!map_block_format::validate(changed.data(), changed.size()));

  changed = validV4;
  changed[buildingFlags] = 3; // building part cannot also be an outline base
  refreshSectionCrc(changed, buildingEntry);
  assert(!map_block_format::validate(changed.data(), changed.size()));

  changed = validV4;
  changed.back() = 0x8f; // non-canonical wall-mask padding
  refreshSectionCrc(changed, buildingEntry);
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

  for (const auto &fixture : golden) {
    map_block_format::StreamValidator binaryStream("tile.fmb");
    for (const uint8_t byte : fixture.second)
      assert(binaryStream.feed(&byte, 1));
    assert(binaryStream.finish());
  }

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
