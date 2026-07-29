#include "../../lib/maps/src/mapFontAsset.hpp"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <fstream>
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

static std::vector<uint8_t> fixture() {
  const std::vector<uint8_t> language = {2, 'e', 'n'};
  std::vector<uint8_t> face = {7, 0};
  append16(face, 5);
  face.insert(face.end(), 32, 0x5a);
  face.insert(face.end(), {'l', 'a', 't', 'i', 'n'});

  std::vector<uint8_t> index;
  std::vector<uint8_t> payload;
  for (uint8_t sizeId = 0; sizeId < 3; ++sizeId) {
    append16(index, 1);
    index.push_back(7);
    index.push_back(sizeId);
    append16(index, static_cast<uint16_t>(-1));
    append16(index, 3);
    append16(index, static_cast<uint16_t>((10 + sizeId) * 64));
    append16(index, 2);
    append16(index, 2);
    append16(index, 0);
    append32(index, static_cast<uint32_t>(payload.size()));
    append32(index, 5);
    payload.insert(payload.end(), {3, 0, 5, 10, 15});
    append32(index, static_cast<uint32_t>(payload.size()));
    append32(index, 5);
    payload.insert(payload.end(), {3, 1, 2, 3, 4});
  }

  std::vector<uint8_t> data = {'F', 'M', 'A', '1', 1, 3, 1, 1};
  append32(data, 0x12345678);
  append32(data, 3);
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
  const std::string path = "/tmp/open-bike-computer-map-font-test.fma";
  const auto data = fixture();
  {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char *>(data.data()), data.size());
  }

  map_font_asset::Asset asset;
  assert(asset.open(path));
  assert(asset.profileFingerprint() == 0x12345678);
  assert(asset.glyphCount() == 1);
  assert(asset.languageCount() == 1);
  assert(asset.language(0) == "en");
  assert(asset.hasGlyph(1, 2));
  assert(!asset.hasGlyph(2, 0));

  map_font_asset::GlyphBitmap bitmap;
  assert(asset.loadGlyph(1, 1, bitmap));
  assert(bitmap.width == 2 && bitmap.height == 2);
  assert(bitmap.bearingX == -1 && bitmap.bearingY == 3);
  assert(bitmap.fill[0] == 0 && bitmap.fill[3] == 15);
  assert(bitmap.distance[0] == 1 && bitmap.distance[3] == 4);
  assert(asset.cachedBytes() == 8);
  assert(asset.cacheMisses() == 1);
  assert(asset.cacheHits() == 0);
  assert(asset.loadGlyph(1, 1, bitmap));
  assert(asset.cachedBytes() == 8);
  assert(asset.cacheHits() == 1);
  assert(asset.cacheEvictions() == 0);
  assert(asset.healthy());
  assert(!asset.loadGlyph(2, 1, bitmap));
  assert(asset.runtimeError() == map_font_asset::RuntimeError::MissingGlyph);
  assert(asset.consecutiveFailures() == 1);
  assert(!asset.loadGlyph(2, 1, bitmap));
  assert(!asset.loadGlyph(2, 1, bitmap));
  assert(!asset.healthy());

  asset.close();
  assert(!asset.isOpen());
  std::remove(path.c_str());
  std::cout << "map font asset runtime tests passed\n";
  return 0;
}
