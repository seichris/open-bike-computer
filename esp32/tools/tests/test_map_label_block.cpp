#include "../../lib/maps/src/mapLabelBlock.hpp"

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

static uint32_t crc32(const std::vector<uint8_t> &data) {
  uint32_t crc = 0xFFFFFFFFU;
  for (const uint8_t byte : data) {
    crc ^= byte;
    for (uint8_t bit = 0; bit < 8; ++bit)
      crc = (crc >> 1U) ^ (0xEDB88320U & (0U - (crc & 1U)));
  }
  return crc ^ 0xFFFFFFFFU;
}

static std::vector<uint8_t> fixture() {
  std::vector<uint8_t> data = {
      'F', 'M', 'B', 3, 0, 0, 1, 0, // header, no polygons, one line
      0x34, 0x12, 2, 5, 7,           // color, width, zoom, type
      0, 0, 0, 0, 100, 0, 0, 0,     // bbox
      2, 0, 0, 0, 0, 0, 100, 0, 0, 0, // points
      'E', 'X', 'T', '3', 3, 0, 0, 0,
  };
  std::vector<uint8_t> strings = {1, 0, 4, 0, 'M', 'a', 'i', 'n'};
  std::vector<uint8_t> runs = {3, 0};
  for (uint8_t size = 0; size < 3; ++size) {
    append16(runs, 1);
    runs.push_back(size);
    runs.push_back(1);
    append16(runs, 1);
    append16(runs, 0);
    append16(runs, 0);
    append16(runs, static_cast<uint16_t>((12 + size * 3) * 64));
  }
  std::vector<uint8_t> labels;
  append32(labels, 0x12345678);
  append16(labels, 1);
  append16(labels, 0); // polyline
  labels.insert(labels.end(), {0, 0, 5});
  append16(labels, 42);
  labels.insert(labels.end(), {1, 1});
  labels.insert(labels.end(), {0, 0}); // local variant, local language
  append16(labels, 1);
  append16(labels, 1);
  append16(labels, 2);
  append16(labels, 3);
  append16(labels, 10);
  append16(labels, 0);
  append16(labels, 90);
  append16(labels, 0);
  labels.insert(labels.end(), {200, 0});

  const std::vector<std::vector<uint8_t>> sections = {strings, runs, labels};
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

int main() {
  const auto data = fixture();
  map_label_block::Block block;
  std::string error;
  assert(map_label_block::decode(data.data(), data.size(), 1, block, &error));
  assert(block.profileFingerprint == 0x12345678);
  assert(block.stringCount == 1);
  assert(block.runs.size() == 3);
  assert(block.labels.size() == 1);
  assert(block.labels[0].candidates[0].endX == 90);
  assert(block.referencesResolve(1, 0));
  assert(!block.referencesResolve(0, 0));

  map_label_block::Block legacy;
  const std::vector<uint8_t> v2 = {'F', 'M', 'B', 2, 0, 0, 0, 0};
  assert(map_label_block::decode(v2.data(), v2.size(), 0, legacy, &error));
  assert(legacy.labels.empty());
  assert(!map_label_block::decode(data.data(), data.size(), 0, legacy, &error));

  std::cout << "map label block tests passed\n";
  return 0;
}
