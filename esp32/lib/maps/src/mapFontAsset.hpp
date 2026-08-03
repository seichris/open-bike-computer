#pragma once

#include "mapFontAssetFormat.hpp"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#ifdef ARDUINO
#include "../../utils/src/psram_allocator.hpp"
template <typename T>
using MapFontVector = std::vector<T, PsramAllocator<T>>;
#else
template <typename T> using MapFontVector = std::vector<T>;
#endif

namespace map_font_asset {

constexpr size_t kBitmapCacheBytes = 512U * 1024U;

enum class RuntimeError : uint8_t {
  None = 0,
  MissingGlyph,
  BitmapLimit,
  BitmapReadOrDecode,
};

inline const char *runtimeErrorCode(RuntimeError error) {
  switch (error) {
  case RuntimeError::None:
    return "none";
  case RuntimeError::MissingGlyph:
    return "missing_glyph";
  case RuntimeError::BitmapLimit:
    return "bitmap_limit";
  case RuntimeError::BitmapReadOrDecode:
    return "bitmap_read_or_decode";
  }
  return "unknown";
}

struct GlyphBitmap {
  int16_t bearingX = 0;
  int16_t bearingY = 0;
  int16_t advance26_6 = 0;
  uint16_t width = 0;
  uint16_t height = 0;
  const uint8_t *fill = nullptr;
  const uint8_t *distance = nullptr;
};

class Asset {
public:
  Asset() = default;
  ~Asset();
  Asset(const Asset &) = delete;
  Asset &operator=(const Asset &) = delete;
  Asset(Asset &&other) noexcept;
  Asset &operator=(Asset &&other) noexcept;

  bool open(const std::string &path);
  void close();
  bool isOpen() const { return file_ != nullptr; }
  bool healthy() const { return file_ != nullptr && !runtimeUnhealthy_; }
  RuntimeError runtimeError() const { return runtimeError_; }
  uint8_t consecutiveFailures() const { return consecutiveFailures_; }
  uint32_t profileFingerprint() const { return profileFingerprint_; }
  uint16_t glyphCount() const { return glyphCount_; }
  uint8_t languageCount() const {
    return static_cast<uint8_t>(languages_.size());
  }
  const std::string &language(uint8_t index) const;
  bool hasGlyph(uint16_t glyphId, uint8_t sizeId) const;
  bool loadGlyph(uint16_t glyphId, uint8_t sizeId, GlyphBitmap &bitmap);
  size_t cachedBytes() const { return cachedBytes_; }
  uint32_t cacheHits() const { return cacheHits_; }
  uint32_t cacheMisses() const { return cacheMisses_; }
  uint32_t cacheEvictions() const { return cacheEvictions_; }

private:
  struct GlyphRecord {
    uint16_t glyphId = 0;
    uint8_t sizeId = 0;
    int16_t bearingX = 0;
    int16_t bearingY = 0;
    int16_t advance26_6 = 0;
    uint16_t width = 0;
    uint16_t height = 0;
    uint32_t fillOffset = 0;
    uint32_t fillLength = 0;
    uint32_t distanceOffset = 0;
    uint32_t distanceLength = 0;
  };

  struct CacheEntry {
    uint16_t glyphId = 0;
    uint8_t sizeId = 0;
    uint32_t lastUse = 0;
    GlyphRecord record;
    MapFontVector<uint8_t> fill;
    MapFontVector<uint8_t> distance;
  };

  FILE *file_ = nullptr;
  uint32_t profileFingerprint_ = 0;
  uint16_t glyphCount_ = 0;
  uint32_t payloadOffset_ = 0;
  uint32_t useCounter_ = 0;
  size_t cachedBytes_ = 0;
  uint32_t cacheHits_ = 0;
  uint32_t cacheMisses_ = 0;
  uint32_t cacheEvictions_ = 0;
  RuntimeError runtimeError_ = RuntimeError::None;
  uint8_t consecutiveFailures_ = 0;
  bool runtimeUnhealthy_ = false;
  std::vector<std::string> languages_;
  MapFontVector<GlyphRecord> records_;
  MapFontVector<CacheEntry> cache_;

  const GlyphRecord *record(uint16_t glyphId, uint8_t sizeId) const;
  bool decodeBitmap(uint32_t offset, uint32_t encodedLength,
                    size_t decodedLength, MapFontVector<uint8_t> &output);
  void evictFor(size_t incomingBytes);
  void setView(CacheEntry &entry, GlyphBitmap &bitmap);
  void markRuntimeFailure(RuntimeError error);
  void markRuntimeSuccess();
};

} // namespace map_font_asset
