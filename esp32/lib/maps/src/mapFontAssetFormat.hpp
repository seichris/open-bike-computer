#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace map_font_asset_format {

constexpr size_t kMaximumFontAssetBytes = 16U * 1024U * 1024U;
constexpr uint32_t kMaximumDistinctGlyphs = 8192;
constexpr uint32_t kMaximumGlyphRecords = kMaximumDistinctGlyphs * 3U;
constexpr uint8_t kMaximumLanguages = 3;
constexpr uint8_t kMaximumFaces = 16;
constexpr uint8_t kMaximumGlyphDimension = 96;

struct Metadata {
  uint32_t profileFingerprint = 0;
  uint32_t glyphRecordCount = 0;
  uint16_t distinctGlyphCount = 0;
  uint8_t languageCount = 0;
};

class StreamValidator {
public:
  bool feed(const uint8_t *data, size_t size);
  bool finish();
  bool failed() const { return failed_; }
  const Metadata &metadata() const { return metadata_; }

private:
  enum class State { Header, Languages, Faces, Index, Payload, Complete };
  struct BitmapRange {
    uint32_t encodedBytes = 0;
    uint16_t pixels = 0;
  };

  State state_ = State::Header;
  bool failed_ = false;
  size_t bytesSeen_ = 0;
  std::array<uint8_t, 36> record_{};
  size_t recordSize_ = 0;
  Metadata metadata_{};
  uint32_t languageTableBytes_ = 0;
  uint32_t faceTableBytes_ = 0;
  uint32_t indexBytes_ = 0;
  uint32_t payloadBytes_ = 0;
  uint32_t sectionBytesSeen_ = 0;
  uint8_t languagesSeen_ = 0;
  uint8_t facesExpected_ = 0;
  uint8_t facesSeen_ = 0;
  std::array<bool, 256> faceIds_{};
  std::array<std::string, kMaximumLanguages> languages_{};
  uint8_t textBytesRemaining_ = 0;
  std::string text_;
  uint32_t glyphRecordsSeen_ = 0;
  uint16_t previousGlyphId_ = 0;
  uint8_t previousSizeId_ = 0;
  uint32_t expectedPayloadOffset_ = 0;
  std::vector<BitmapRange> bitmapRanges_;
  size_t bitmapRangeIndex_ = 0;
  uint32_t bitmapEncodedSeen_ = 0;
  uint16_t bitmapPixelsSeen_ = 0;
  uint8_t rleValuesRemaining_ = 0;
  bool rleRepeatValuePending_ = false;
  bool rleLiteral_ = false;

  bool feedByte(uint8_t byte);
  bool parseHeader();
  bool feedLanguage(uint8_t byte);
  bool feedFace(uint8_t byte);
  bool parseFacePrefix();
  bool feedIndex(uint8_t byte);
  bool parseGlyphRecord();
  bool feedPayload(uint8_t byte);
  bool finishBitmapRange();
};

bool validate(const uint8_t *data, size_t size, Metadata *metadata = nullptr);

} // namespace map_font_asset_format
