#include "../../lib/maps/src/mapFontAssetFormat.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <vector>

static void append16(std::vector<uint8_t> &data, uint16_t value) {
  data.push_back(static_cast<uint8_t>(value));
  data.push_back(static_cast<uint8_t>(value >> 8U));
}

static void append32(std::vector<uint8_t> &data, uint32_t value) {
  for (uint8_t shift = 0; shift < 32; shift += 8)
    data.push_back(static_cast<uint8_t>(value >> shift));
}

static std::vector<uint8_t> validAsset(bool includeGlyph) {
  const std::vector<uint8_t> language = {2, 'e', 'n'};
  std::vector<uint8_t> face = {0, 0, 5, 0};
  face.insert(face.end(), 32, 0x42);
  face.insert(face.end(), {'l', 'a', 't', 'i', 'n'});
  std::vector<uint8_t> index;
  std::vector<uint8_t> payload;
  if (includeGlyph) {
    for (uint8_t sizeId = 0; sizeId < 3; ++sizeId) {
      append16(index, 1);
      index.push_back(0);
      index.push_back(sizeId);
      append16(index, 0);
      append16(index, 0);
      append16(index, 64);
      append16(index, 1);
      append16(index, 1);
      append16(index, 0);
      append32(index, static_cast<uint32_t>(payload.size()));
      append32(index, 2);
      append32(index, static_cast<uint32_t>(payload.size() + 2));
      append32(index, 2);
      payload.insert(payload.end(), {0x80, 15, 0x80, 15});
    }
  }
  std::vector<uint8_t> data = {'F', 'M', 'A', '1', 1, 3, 1, 1};
  append32(data, 0x12345678);
  append32(data, includeGlyph ? 3 : 0);
  append32(data, static_cast<uint32_t>(language.size()));
  append32(data, static_cast<uint32_t>(face.size()));
  append32(data, static_cast<uint32_t>(index.size()));
  append32(data, static_cast<uint32_t>(payload.size()));
  data.insert(data.end(), language.begin(), language.end());
  data.insert(data.end(), face.begin(), face.end());
  data.insert(data.end(), index.begin(), index.end());
  data.insert(data.end(), payload.begin(), payload.end());
  return data;
}

int main() {
  for (const bool includeGlyph : {false, true}) {
    const std::vector<uint8_t> valid = validAsset(includeGlyph);
    map_font_asset_format::Metadata metadata;
    assert(map_font_asset_format::validate(valid.data(), valid.size(), &metadata));
    assert(metadata.profileFingerprint == 0x12345678);
    assert(metadata.distinctGlyphCount == (includeGlyph ? 1 : 0));
    for (size_t size = 0; size < valid.size(); ++size)
      assert(!map_font_asset_format::validate(valid.data(), size));

    map_font_asset_format::StreamValidator stream;
    for (const uint8_t byte : valid)
      assert(stream.feed(&byte, 1));
    assert(stream.finish());
  }

  auto changed = validAsset(true);
  changed[4] = 2;
  assert(!map_font_asset_format::validate(changed.data(), changed.size()));
  changed = validAsset(true);
  changed.back() = 16;
  assert(!map_font_asset_format::validate(changed.data(), changed.size()));
  changed = validAsset(true);
  changed[32 + 3 + 41 + 20] = 3;
  assert(!map_font_asset_format::validate(changed.data(), changed.size()));
  changed = validAsset(true);
  changed.push_back(0);
  assert(!map_font_asset_format::validate(changed.data(), changed.size()));

  std::vector<uint8_t> oversized(
      map_font_asset_format::kMaximumFontAssetBytes + 1U, 0);
  map_font_asset_format::StreamValidator budget;
  assert(!budget.feed(oversized.data(), oversized.size()));

  std::cout << "map font asset format tests passed\n";
  return 0;
}
