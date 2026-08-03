#include "mapLabelBlock.hpp"

#include "mapBlockFormat.hpp"

#include <algorithm>
#include <array>
#include <limits>

namespace map_label_block {
namespace {

uint16_t le16(const uint8_t *bytes) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8U);
}

int16_t sle16(const uint8_t *bytes) {
  return static_cast<int16_t>(le16(bytes));
}

uint32_t le32(const uint8_t *bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8U) |
         (static_cast<uint32_t>(bytes[2]) << 16U) |
         (static_cast<uint32_t>(bytes[3]) << 24U);
}

bool fail(std::string *error, const char *message) {
  if (error != nullptr)
    *error = message;
  return false;
}

bool take(size_t amount, size_t size, size_t &offset) {
  if (amount > size - std::min(offset, size))
    return false;
  offset += amount;
  return true;
}

bool baseEnd(const uint8_t *data, size_t size, size_t &offset,
             uint16_t &actualPolylineCount) {
  if (size < 6 || (data[3] != 3 && data[3] != 4))
    return false;
  offset = 4;
  const uint16_t polygonCount = le16(data + offset);
  offset += 2;
  for (uint16_t index = 0; index < polygonCount; ++index) {
    if (!take(12, size, offset) || !take(2, size, offset))
      return false;
    const uint16_t pointCount = le16(data + offset - 2);
    if (!take(static_cast<size_t>(pointCount) * 4U, size, offset))
      return false;
  }
  if (!take(2, size, offset))
    return false;
  actualPolylineCount = le16(data + offset - 2);
  for (uint16_t index = 0; index < actualPolylineCount; ++index) {
    if (!take(13, size, offset) || !take(2, size, offset))
      return false;
    const uint16_t pointCount = le16(data + offset - 2);
    if (!take(static_cast<size_t>(pointCount) * 4U, size, offset))
      return false;
  }
  return true;
}

struct Section {
  size_t offset = 0;
  size_t length = 0;
};

bool sections(const uint8_t *data, size_t size, size_t directoryOffset,
              std::array<Section, 3> &result) {
  const uint8_t version = data[3];
  const size_t directoryBytes = 8U + static_cast<size_t>(version) * 16U;
  if (directoryOffset > size || size - directoryOffset < directoryBytes ||
      data[directoryOffset] != 'E' || data[directoryOffset + 1] != 'X' ||
      data[directoryOffset + 2] != 'T' ||
      data[directoryOffset + 3] != static_cast<uint8_t>('0' + version) ||
      data[directoryOffset + 4] != version)
    return false;
  size_t cursor = directoryOffset + 8;
  for (uint8_t index = 0; index < 3; ++index) {
    if (data[cursor] != index + 1)
      return false;
    result[index].offset = le32(data + cursor + 4);
    result[index].length = le32(data + cursor + 8);
    cursor += 16;
  }
  return true;
}

} // namespace

void Block::clear() {
  profileFingerprint = 0;
  stringCount = 0;
  runs.clear();
  labels.clear();
}

size_t Block::decodedBytes() const {
  size_t bytes = runs.capacity() * sizeof(ShapedRun) +
                 labels.capacity() * sizeof(RoadLabel);
  for (const ShapedRun &run : runs)
    bytes += run.glyphs.capacity() * sizeof(GlyphPlacement);
  for (const RoadLabel &label : labels) {
    bytes += label.variants.capacity() * sizeof(Variant);
    bytes += label.candidates.capacity() * sizeof(Candidate);
  }
  return bytes;
}

bool Block::referencesResolve(uint16_t fontGlyphCount,
                              uint8_t fontLanguageCount) const {
  for (const ShapedRun &run : runs) {
    if (run.stringId == 0 || run.stringId > stringCount || run.sizeId > 2 ||
        run.glyphs.empty())
      return false;
    for (const GlyphPlacement &glyph : run.glyphs)
      if (glyph.glyphId == 0 || glyph.glyphId > fontGlyphCount)
        return false;
  }
  for (const RoadLabel &label : labels) {
    for (const Variant &variant : label.variants) {
      if (variant.stringId == 0 || variant.stringId > stringCount ||
          (variant.languageId != 0 && variant.languageId != 255 &&
           variant.languageId > fontLanguageCount))
        return false;
      for (uint8_t sizeId = 0; sizeId < 3; ++sizeId) {
        const uint16_t runId = variant.runIds[sizeId];
        if (runId == 0 || runId > runs.size())
          return false;
        const ShapedRun &run = runs[runId - 1U];
        if (run.stringId != variant.stringId || run.sizeId != sizeId)
          return false;
      }
    }
  }
  return true;
}

bool decode(const uint8_t *data, size_t size, uint16_t polylineCount,
            Block &output, std::string *error) {
  output.clear();
  if (data == nullptr || size < 4 || data[0] != 'F' || data[1] != 'M' ||
      data[2] != 'B')
    return fail(error, "invalid FMB header");
  if (data[3] < 3)
    return true;
  if ((data[3] != 3 && data[3] != 4) ||
      !map_block_format::validate(data, size))
    return fail(error, "invalid label-aware FMB block");

  size_t directoryOffset = 0;
  uint16_t decodedPolylineCount = 0;
  if (!baseEnd(data, size, directoryOffset, decodedPolylineCount) ||
      (polylineCount != std::numeric_limits<uint16_t>::max() &&
       decodedPolylineCount != polylineCount))
    return fail(error, "FMB geometry/label boundary mismatch");
  std::array<Section, 3> table{};
  if (!sections(data, size, directoryOffset, table))
    return fail(error, "invalid FMB extension directory");

  size_t cursor = table[0].offset;
  const size_t stringEnd = cursor + table[0].length;
  output.stringCount = le16(data + cursor);
  cursor += 2;
  for (uint16_t index = 0; index < output.stringCount; ++index) {
    const uint16_t length = le16(data + cursor);
    cursor += 2U + length;
  }
  if (cursor != stringEnd)
    return fail(error, "invalid FMB string table");

  cursor = table[1].offset;
  const size_t runEnd = cursor + table[1].length;
  const uint16_t runCount = le16(data + cursor);
  cursor += 2;
  output.runs.reserve(runCount);
  for (uint16_t index = 0; index < runCount; ++index) {
    ShapedRun run;
    run.stringId = le16(data + cursor);
    run.sizeId = data[cursor + 2];
    const uint8_t glyphCount = data[cursor + 3];
    cursor += 4;
    run.glyphs.reserve(glyphCount);
    for (uint8_t glyphIndex = 0; glyphIndex < glyphCount; ++glyphIndex) {
      run.glyphs.push_back(
          {le16(data + cursor), sle16(data + cursor + 2),
           sle16(data + cursor + 4), sle16(data + cursor + 6)});
      cursor += 8;
    }
    output.runs.push_back(std::move(run));
  }
  if (cursor != runEnd)
    return fail(error, "invalid FMB shaped-run table");

  cursor = table[2].offset;
  const size_t labelEnd = cursor + table[2].length;
  output.profileFingerprint = le32(data + cursor);
  const uint16_t labelCount = le16(data + cursor + 4);
  cursor += 6;
  output.labels.reserve(labelCount);
  for (uint16_t index = 0; index < labelCount; ++index) {
    RoadLabel label;
    label.polylineIndex = le16(data + cursor);
    label.rank = data[cursor + 2];
    label.minZoom = data[cursor + 3];
    label.maxZoom = data[cursor + 4];
    label.repeatGroup = le16(data + cursor + 5);
    const uint8_t variantCount = data[cursor + 7];
    const uint8_t candidateCount = data[cursor + 8];
    cursor += 9;
    if (label.polylineIndex >= polylineCount)
      return fail(error, "FMB label references missing polyline");
    label.variants.reserve(variantCount);
    for (uint8_t variantIndex = 0; variantIndex < variantCount;
         ++variantIndex) {
      Variant variant;
      variant.kind = data[cursor];
      variant.languageId = data[cursor + 1];
      variant.stringId = le16(data + cursor + 2);
      for (uint8_t sizeId = 0; sizeId < 3; ++sizeId)
        variant.runIds[sizeId] = le16(data + cursor + 4U + sizeId * 2U);
      cursor += 10;
      label.variants.push_back(variant);
    }
    label.candidates.reserve(candidateCount);
    for (uint8_t candidateIndex = 0; candidateIndex < candidateCount;
         ++candidateIndex) {
      label.candidates.push_back(
          {sle16(data + cursor), sle16(data + cursor + 2),
           sle16(data + cursor + 4), sle16(data + cursor + 6),
           data[cursor + 8], data[cursor + 9]});
      cursor += 10;
    }
    output.labels.push_back(std::move(label));
  }
  if (cursor != labelEnd ||
      !output.referencesResolve(std::numeric_limits<uint16_t>::max(), 254)) {
    output.clear();
    return fail(error, "FMB label references are inconsistent");
  }
  return true;
}

} // namespace map_label_block
