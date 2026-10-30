#include "../../lib/maps/src/mapFontAsset.hpp"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>
#include <vector>

// Concurrent worktree checks must not share one fixed font path.
static std::string temporaryFontPath(const char *name) {
  const char *directory = std::getenv("TMPDIR");
  std::string path =
      directory != nullptr && *directory != '\0' ? directory : "/tmp";
  if (path.back() != '/')
    path += '/';
  return path + name + "-" + std::to_string(::getpid()) + ".fma";
}

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

// A font whose glyph index spans several 16 KiB read batches (512 records
// each). Every record carries values derived from its glyph and size so a
// record shifted or dropped at a batch boundary is detected.
static int16_t bearingXFor(uint16_t glyphId) {
  return static_cast<int16_t>(static_cast<int>(glyphId % 97U) - 48);
}

static std::vector<uint8_t> multiBatchFixture(uint16_t glyphs) {
  const std::vector<uint8_t> language = {2, 'e', 'n'};
  std::vector<uint8_t> face = {7, 0};
  append16(face, 5);
  face.insert(face.end(), 32, 0x5a);
  face.insert(face.end(), {'l', 'a', 't', 'i', 'n'});

  std::vector<uint8_t> index;
  std::vector<uint8_t> payload;
  for (uint16_t glyphId = 1; glyphId <= glyphs; ++glyphId) {
    for (uint8_t sizeId = 0; sizeId < 3; ++sizeId) {
      append16(index, glyphId);
      index.push_back(7);
      index.push_back(sizeId);
      append16(index, static_cast<uint16_t>(bearingXFor(glyphId)));
      append16(index, static_cast<uint16_t>(sizeId + 1));
      append16(index, static_cast<uint16_t>(glyphId + sizeId));
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
  }

  std::vector<uint8_t> data = {'F', 'M', 'A', '1', 1, 3, 1, 1};
  append32(data, 0x0badf00d);
  append32(data, static_cast<uint32_t>(glyphs) * 3U);
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

static void testGlyphIndexIsReadAcrossBatchBoundaries() {
  // 700 glyphs = 2,100 records: four full 512-record batches plus 52.
  constexpr uint16_t kGlyphs = 700;
  const std::string path = temporaryFontPath("open-bike-computer-map-font-batches");
  const auto data = multiBatchFixture(kGlyphs);
  {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char *>(data.data()), data.size());
  }

  map_font_asset::Asset asset;
  assert(asset.open(path));
  assert(asset.profileFingerprint() == 0x0badf00d);
  assert(asset.glyphCount() == kGlyphs);
  for (uint16_t glyphId = 1; glyphId <= kGlyphs; ++glyphId)
    for (uint8_t sizeId = 0; sizeId < 3; ++sizeId)
      assert(asset.hasGlyph(glyphId, sizeId));
  assert(!asset.hasGlyph(kGlyphs + 1, 0));

  // Records 511/512 and 1023/1024 straddle batch boundaries; the last glyph
  // ends the final partial batch.
  const uint16_t probes[] = {1, 170, 171, 172, 341, 342, 512, 699, kGlyphs};
  for (uint16_t glyphId : probes) {
    for (uint8_t sizeId = 0; sizeId < 3; ++sizeId) {
      map_font_asset::GlyphBitmap bitmap;
      assert(asset.loadGlyph(glyphId, sizeId, bitmap));
      assert(bitmap.bearingX == bearingXFor(glyphId));
      assert(bitmap.bearingY == sizeId + 1);
      assert(bitmap.advance26_6 == glyphId + sizeId);
      assert(bitmap.width == 2 && bitmap.height == 2);
      assert(bitmap.fill[3] == 15 && bitmap.distance[3] == 4);
    }
  }

  // The same bytes with one record table byte cut away fail validation
  // before any record is accepted.
  {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char *>(data.data()),
                 static_cast<std::streamsize>(data.size() - 1));
  }
  map_font_asset::Asset truncated;
  assert(!truncated.open(path));
  assert(!truncated.isOpen() && truncated.glyphCount() == 0);
  std::remove(path.c_str());
}

int main() {
  testGlyphIndexIsReadAcrossBatchBoundaries();
  const std::string path = temporaryFontPath("open-bike-computer-map-font-test");
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
