#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T>
using MapLabelVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapLabelVector = std::vector<T>;
#endif

namespace map_label_block {

struct GlyphPlacement {
  uint16_t glyphId = 0;
  int16_t xOffset26_6 = 0;
  int16_t yOffset26_6 = 0;
  int16_t xAdvance26_6 = 0;
};

struct ShapedRun {
  uint16_t stringId = 0;
  uint8_t sizeId = 0;
  MapLabelVector<GlyphPlacement> glyphs;
};

struct Variant {
  uint8_t kind = 0;
  uint8_t languageId = 0;
  uint16_t stringId = 0;
  uint16_t runIds[3] = {0, 0, 0};
};

struct Candidate {
  int16_t startX = 0;
  int16_t startY = 0;
  int16_t endX = 0;
  int16_t endY = 0;
  uint8_t quality = 0;
  uint8_t flags = 0;
};

struct RoadLabel {
  uint16_t polylineIndex = 0;
  uint8_t rank = 0;
  uint8_t minZoom = 0;
  uint8_t maxZoom = 0;
  uint16_t repeatGroup = 0;
  MapLabelVector<Variant> variants;
  MapLabelVector<Candidate> candidates;
};

struct Block {
  uint32_t profileFingerprint = 0;
  uint16_t stringCount = 0;
  MapLabelVector<ShapedRun> runs;
  MapLabelVector<RoadLabel> labels;

  void clear();
  size_t decodedBytes() const;
  bool referencesResolve(uint16_t fontGlyphCount,
                         uint8_t fontLanguageCount) const;
};

// Decodes the label extension after the complete block has passed the strict
// map_block_format validator. v1/v2 are valid and produce an empty result.
bool decode(const uint8_t *data, size_t size, uint16_t polylineCount,
            Block &output, std::string *error = nullptr);

} // namespace map_label_block
