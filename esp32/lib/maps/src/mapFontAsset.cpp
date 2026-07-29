#include "mapFontAsset.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <limits>
#include <sys/stat.h>

namespace map_font_asset {
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

bool readExact(FILE *file, void *buffer, size_t size) {
  return size == 0 || std::fread(buffer, 1, size, file) == size;
}

} // namespace

Asset::~Asset() { close(); }

Asset::Asset(Asset &&other) noexcept { *this = std::move(other); }

Asset &Asset::operator=(Asset &&other) noexcept {
  if (this == &other)
    return *this;
  close();
  file_ = other.file_;
  profileFingerprint_ = other.profileFingerprint_;
  glyphCount_ = other.glyphCount_;
  payloadOffset_ = other.payloadOffset_;
  useCounter_ = other.useCounter_;
  cachedBytes_ = other.cachedBytes_;
  cacheHits_ = other.cacheHits_;
  cacheMisses_ = other.cacheMisses_;
  cacheEvictions_ = other.cacheEvictions_;
  runtimeError_ = other.runtimeError_;
  consecutiveFailures_ = other.consecutiveFailures_;
  runtimeUnhealthy_ = other.runtimeUnhealthy_;
  languages_ = std::move(other.languages_);
  records_ = std::move(other.records_);
  cache_ = std::move(other.cache_);
  other.file_ = nullptr;
  other.profileFingerprint_ = 0;
  other.glyphCount_ = 0;
  other.payloadOffset_ = 0;
  other.useCounter_ = 0;
  other.cachedBytes_ = 0;
  other.cacheHits_ = 0;
  other.cacheMisses_ = 0;
  other.cacheEvictions_ = 0;
  other.runtimeError_ = RuntimeError::None;
  other.consecutiveFailures_ = 0;
  other.runtimeUnhealthy_ = false;
  return *this;
}

void Asset::close() {
  if (file_ != nullptr)
    std::fclose(file_);
  file_ = nullptr;
  profileFingerprint_ = 0;
  glyphCount_ = 0;
  payloadOffset_ = 0;
  useCounter_ = 0;
  cachedBytes_ = 0;
  cacheHits_ = 0;
  cacheMisses_ = 0;
  cacheEvictions_ = 0;
  runtimeError_ = RuntimeError::None;
  consecutiveFailures_ = 0;
  runtimeUnhealthy_ = false;
  languages_.clear();
  records_.clear();
  cache_.clear();
}

const std::string &Asset::language(uint8_t index) const {
  static const std::string empty;
  return index < languages_.size() ? languages_[index] : empty;
}

bool Asset::open(const std::string &path) {
  close();
  struct stat metadata = {};
  if (::stat(path.c_str(), &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
      metadata.st_size < 32 ||
      static_cast<uint64_t>(metadata.st_size) >
          map_font_asset_format::kMaximumFontAssetBytes)
    return false;

  FILE *candidate = std::fopen(path.c_str(), "rb");
  if (candidate == nullptr)
    return false;

  map_font_asset_format::StreamValidator validator;
  std::array<uint8_t, 16U * 1024U> validationBuffer{};
  bool valid = true;
  while (valid) {
    const size_t bytes =
        std::fread(validationBuffer.data(), 1, validationBuffer.size(), candidate);
    if (bytes != 0 && !validator.feed(validationBuffer.data(), bytes))
      valid = false;
    if (bytes < validationBuffer.size()) {
      if (std::ferror(candidate) != 0)
        valid = false;
      break;
    }
  }
  if (!valid || !validator.finish() || std::fseek(candidate, 0, SEEK_SET) != 0) {
    std::fclose(candidate);
    return false;
  }

  std::array<uint8_t, 32> header{};
  if (!readExact(candidate, header.data(), header.size())) {
    std::fclose(candidate);
    return false;
  }
  const uint8_t languageCount = header[6];
  profileFingerprint_ = le32(header.data() + 8);
  const uint32_t recordCount = le32(header.data() + 12);
  const uint32_t languageBytes = le32(header.data() + 16);
  const uint32_t faceBytes = le32(header.data() + 20);
  const uint32_t indexBytes = le32(header.data() + 24);
  glyphCount_ = static_cast<uint16_t>(recordCount / 3U);

  MapFontVector<uint8_t> languageTable(languageBytes);
  if (!readExact(candidate, languageTable.data(), languageTable.size())) {
    std::fclose(candidate);
    close();
    return false;
  }
  size_t languageOffset = 0;
  languages_.reserve(languageCount);
  for (uint8_t index = 0; index < languageCount; ++index) {
    if (languageOffset >= languageTable.size()) {
      std::fclose(candidate);
      close();
      return false;
    }
    const uint8_t length = languageTable[languageOffset++];
    if (length > languageTable.size() - languageOffset) {
      std::fclose(candidate);
      close();
      return false;
    }
    languages_.emplace_back(
        reinterpret_cast<const char *>(languageTable.data() + languageOffset),
        length);
    languageOffset += length;
  }
  if (languageOffset != languageTable.size() ||
      std::fseek(candidate, static_cast<long>(faceBytes), SEEK_CUR) != 0) {
    std::fclose(candidate);
    close();
    return false;
  }

  records_.reserve(recordCount);
  std::array<uint8_t, 32> bytes{};
  for (uint32_t index = 0; index < recordCount; ++index) {
    if (!readExact(candidate, bytes.data(), bytes.size())) {
      std::fclose(candidate);
      close();
      return false;
    }
    GlyphRecord record;
    record.glyphId = le16(bytes.data());
    record.sizeId = bytes[3];
    record.bearingX = sle16(bytes.data() + 4);
    record.bearingY = sle16(bytes.data() + 6);
    record.advance26_6 = sle16(bytes.data() + 8);
    record.width = le16(bytes.data() + 10);
    record.height = le16(bytes.data() + 12);
    record.fillOffset = le32(bytes.data() + 16);
    record.fillLength = le32(bytes.data() + 20);
    record.distanceOffset = le32(bytes.data() + 24);
    record.distanceLength = le32(bytes.data() + 28);
    records_.push_back(record);
  }
  payloadOffset_ = 32U + languageBytes + faceBytes + indexBytes;
  file_ = candidate;
  return true;
}

const Asset::GlyphRecord *Asset::record(uint16_t glyphId,
                                         uint8_t sizeId) const {
  if (!hasGlyph(glyphId, sizeId))
    return nullptr;
  const size_t index = (static_cast<size_t>(glyphId) - 1U) * 3U + sizeId;
  return &records_[index];
}

bool Asset::hasGlyph(uint16_t glyphId, uint8_t sizeId) const {
  if (file_ == nullptr || glyphId == 0 || glyphId > glyphCount_ || sizeId > 2)
    return false;
  const size_t index = (static_cast<size_t>(glyphId) - 1U) * 3U + sizeId;
  return index < records_.size() && records_[index].glyphId == glyphId &&
         records_[index].sizeId == sizeId;
}

bool Asset::decodeBitmap(uint32_t offset, uint32_t encodedLength,
                         size_t decodedLength,
                         MapFontVector<uint8_t> &output) {
  if (file_ == nullptr || encodedLength == 0 ||
      offset > std::numeric_limits<uint32_t>::max() - payloadOffset_ ||
      std::fseek(file_, static_cast<long>(payloadOffset_ + offset), SEEK_SET) !=
          0)
    return false;
  MapFontVector<uint8_t> encoded(encodedLength);
  if (!readExact(file_, encoded.data(), encoded.size()))
    return false;
  output.clear();
  output.reserve(decodedLength);
  size_t cursor = 0;
  while (cursor < encoded.size()) {
    const uint8_t control = encoded[cursor++];
    const size_t count = static_cast<size_t>(control & 0x7fU) + 1U;
    if (count > decodedLength - output.size())
      return false;
    if ((control & 0x80U) != 0) {
      if (cursor >= encoded.size() || encoded[cursor] > 15)
        return false;
      output.insert(output.end(), count, encoded[cursor++]);
    } else {
      if (count > encoded.size() - cursor)
        return false;
      for (size_t index = 0; index < count; ++index) {
        if (encoded[cursor + index] > 15)
          return false;
        output.push_back(encoded[cursor + index]);
      }
      cursor += count;
    }
  }
  return output.size() == decodedLength;
}

void Asset::evictFor(size_t incomingBytes) {
  while (!cache_.empty() &&
         incomingBytes > kBitmapCacheBytes -
                             std::min(cachedBytes_, kBitmapCacheBytes)) {
    auto oldest = std::min_element(
        cache_.begin(), cache_.end(), [](const CacheEntry &lhs,
                                        const CacheEntry &rhs) {
          return lhs.lastUse < rhs.lastUse;
        });
    cachedBytes_ -= oldest->fill.size() + oldest->distance.size();
    cache_.erase(oldest);
    cacheEvictions_++;
  }
}

void Asset::setView(CacheEntry &entry, GlyphBitmap &bitmap) {
  bitmap.bearingX = entry.record.bearingX;
  bitmap.bearingY = entry.record.bearingY;
  bitmap.advance26_6 = entry.record.advance26_6;
  bitmap.width = entry.record.width;
  bitmap.height = entry.record.height;
  bitmap.fill = entry.fill.data();
  bitmap.distance = entry.distance.data();
}

void Asset::markRuntimeFailure(RuntimeError error) {
  runtimeError_ = error;
  if (consecutiveFailures_ < std::numeric_limits<uint8_t>::max())
    consecutiveFailures_++;
  if (consecutiveFailures_ >= 3)
    runtimeUnhealthy_ = true;
}

void Asset::markRuntimeSuccess() {
  if (!runtimeUnhealthy_) {
    runtimeError_ = RuntimeError::None;
    consecutiveFailures_ = 0;
  }
}

bool Asset::loadGlyph(uint16_t glyphId, uint8_t sizeId,
                      GlyphBitmap &bitmap) {
  if (!healthy())
    return false;
  for (CacheEntry &entry : cache_) {
    if (entry.glyphId == glyphId && entry.sizeId == sizeId) {
      entry.lastUse = ++useCounter_;
      cacheHits_++;
      setView(entry, bitmap);
      markRuntimeSuccess();
      return true;
    }
  }
  const GlyphRecord *source = record(glyphId, sizeId);
  if (source == nullptr) {
    markRuntimeFailure(RuntimeError::MissingGlyph);
    return false;
  }
  cacheMisses_++;
  const size_t pixels = static_cast<size_t>(source->width) * source->height;
  if (pixels > kBitmapCacheBytes / 2U) {
    markRuntimeFailure(RuntimeError::BitmapLimit);
    return false;
  }
  evictFor(pixels * 2U);
  CacheEntry entry;
  entry.glyphId = glyphId;
  entry.sizeId = sizeId;
  entry.lastUse = ++useCounter_;
  entry.record = *source;
  if (!decodeBitmap(source->fillOffset, source->fillLength, pixels,
                    entry.fill) ||
      !decodeBitmap(source->distanceOffset, source->distanceLength, pixels,
                    entry.distance)) {
    markRuntimeFailure(RuntimeError::BitmapReadOrDecode);
    return false;
  }
  cachedBytes_ += pixels * 2U;
  cache_.push_back(std::move(entry));
  setView(cache_.back(), bitmap);
  markRuntimeSuccess();
  return true;
}

} // namespace map_font_asset
