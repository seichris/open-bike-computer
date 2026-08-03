#include "mapFontAssetFormat.hpp"

#include <algorithm>
#include <limits>

namespace map_font_asset_format {
namespace {

uint16_t le16(const uint8_t *bytes) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8U);
}

uint32_t le32(const uint8_t *bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8U) |
         (static_cast<uint32_t>(bytes[2]) << 16U) |
         (static_cast<uint32_t>(bytes[3]) << 24U);
}

bool canonicalLanguage(const std::string &value) {
  if (value.size() < 2 || value.size() > 35)
    return false;
  size_t partStart = 0;
  uint8_t partIndex = 0;
  while (partStart < value.size()) {
    const size_t dash = value.find('-', partStart);
    const size_t end = dash == std::string::npos ? value.size() : dash;
    const size_t length = end - partStart;
    if (length == 0 || length > 8 || partIndex > 3)
      return false;
    for (size_t index = partStart; index < end; ++index) {
      const unsigned char character = value[index];
      const bool alpha = (character >= 'a' && character <= 'z') ||
                         (character >= 'A' && character <= 'Z');
      if (!alpha && !(partIndex > 0 && character >= '0' && character <= '9'))
        return false;
      if (partIndex == 0 && !(character >= 'a' && character <= 'z'))
        return false;
    }
    if (partIndex > 0) {
      if (length == 4) {
        if (!(value[partStart] >= 'A' && value[partStart] <= 'Z'))
          return false;
        for (size_t index = partStart + 1; index < end; ++index)
          if (!(value[index] >= 'a' && value[index] <= 'z'))
            return false;
      } else if (length == 2) {
        for (size_t index = partStart; index < end; ++index)
          if (!(value[index] >= 'A' && value[index] <= 'Z'))
            return false;
      } else {
        for (size_t index = partStart; index < end; ++index)
          if (value[index] >= 'A' && value[index] <= 'Z')
            return false;
      }
    }
    partIndex++;
    if (dash == std::string::npos)
      return true;
    partStart = dash + 1;
  }
  return false;
}

} // namespace

bool StreamValidator::feed(const uint8_t *data, size_t size) {
  if (failed_ || (data == nullptr && size != 0) ||
      size > kMaximumFontAssetBytes - bytesSeen_) {
    failed_ = true;
    return false;
  }
  bytesSeen_ += size;
  for (size_t index = 0; index < size; ++index) {
    if (!feedByte(data[index])) {
      failed_ = true;
      return false;
    }
  }
  return true;
}

bool StreamValidator::feedByte(uint8_t byte) {
  switch (state_) {
  case State::Header:
    record_[recordSize_++] = byte;
    return recordSize_ < 32 || parseHeader();
  case State::Languages:
    return feedLanguage(byte);
  case State::Faces:
    return feedFace(byte);
  case State::Index:
    return feedIndex(byte);
  case State::Payload:
    return feedPayload(byte);
  case State::Complete:
    return false;
  }
  return false;
}

bool StreamValidator::parseHeader() {
  if (!std::equal(record_.begin(), record_.begin() + 4,
                  std::array<uint8_t, 4>{'F', 'M', 'A', '1'}.begin()) ||
      record_[4] != 1 || record_[5] != 3 ||
      record_[6] > kMaximumLanguages || record_[7] == 0 ||
      record_[7] > kMaximumFaces) {
    return false;
  }
  metadata_.languageCount = record_[6];
  facesExpected_ = record_[7];
  metadata_.profileFingerprint = le32(record_.data() + 8);
  metadata_.glyphRecordCount = le32(record_.data() + 12);
  languageTableBytes_ = le32(record_.data() + 16);
  faceTableBytes_ = le32(record_.data() + 20);
  indexBytes_ = le32(record_.data() + 24);
  payloadBytes_ = le32(record_.data() + 28);
  if (metadata_.glyphRecordCount > kMaximumGlyphRecords ||
      metadata_.glyphRecordCount % 3U != 0 ||
      indexBytes_ != metadata_.glyphRecordCount * 32U ||
      languageTableBytes_ > kMaximumLanguages * 36U ||
      faceTableBytes_ > kMaximumFaces * (36U + 255U)) {
    return false;
  }
  const uint64_t total = 32ULL + languageTableBytes_ + faceTableBytes_ +
                         indexBytes_ + payloadBytes_;
  if (total > kMaximumFontAssetBytes)
    return false;
  metadata_.distinctGlyphCount =
      static_cast<uint16_t>(metadata_.glyphRecordCount / 3U);
  bitmapRanges_.reserve(metadata_.glyphRecordCount * 2U);
  recordSize_ = 0;
  sectionBytesSeen_ = 0;
  if (languageTableBytes_ != 0) {
    state_ = State::Languages;
  } else if (metadata_.languageCount != 0) {
    return false;
  } else {
    state_ = State::Faces;
  }
  return true;
}

bool StreamValidator::feedLanguage(uint8_t byte) {
  if (++sectionBytesSeen_ > languageTableBytes_)
    return false;
  if (textBytesRemaining_ == 0) {
    if (languagesSeen_ >= metadata_.languageCount || byte == 0 || byte > 35)
      return false;
    textBytesRemaining_ = byte;
    text_.clear();
  } else {
    if (byte > 0x7f)
      return false;
    text_.push_back(static_cast<char>(byte));
    if (--textBytesRemaining_ == 0) {
      if (!canonicalLanguage(text_))
        return false;
      for (uint8_t index = 0; index < languagesSeen_; ++index)
        if (languages_[index] == text_)
          return false;
      languages_[languagesSeen_++] = text_;
    }
  }
  if (sectionBytesSeen_ == languageTableBytes_) {
    if (textBytesRemaining_ != 0 || languagesSeen_ != metadata_.languageCount)
      return false;
    state_ = State::Faces;
    sectionBytesSeen_ = 0;
  }
  return true;
}

bool StreamValidator::feedFace(uint8_t byte) {
  if (++sectionBytesSeen_ > faceTableBytes_)
    return false;
  if (textBytesRemaining_ != 0) {
    if (byte < 0x20 || byte > 0x7e)
      return false;
    text_.push_back(static_cast<char>(byte));
    textBytesRemaining_--;
    if (textBytesRemaining_ == 0)
      facesSeen_++;
  } else {
    record_[recordSize_++] = byte;
    if (recordSize_ == 36 && !parseFacePrefix())
      return false;
  }
  if (sectionBytesSeen_ == faceTableBytes_) {
    if (textBytesRemaining_ != 0 || recordSize_ != 0 ||
        facesSeen_ != facesExpected_)
      return false;
    state_ = metadata_.glyphRecordCount == 0 ? State::Payload : State::Index;
    sectionBytesSeen_ = 0;
  }
  return true;
}

bool StreamValidator::parseFacePrefix() {
  const uint8_t faceId = record_[0];
  const uint16_t nameBytes = le16(record_.data() + 2);
  if (faceIds_[faceId] || nameBytes == 0 || nameBytes > 255 ||
      facesSeen_ >= facesExpected_)
    return false;
  faceIds_[faceId] = true;
  textBytesRemaining_ = static_cast<uint8_t>(nameBytes);
  text_.clear();
  recordSize_ = 0;
  return true;
}

bool StreamValidator::feedIndex(uint8_t byte) {
  if (++sectionBytesSeen_ > indexBytes_)
    return false;
  record_[recordSize_++] = byte;
  if (recordSize_ == 32 && !parseGlyphRecord())
    return false;
  if (sectionBytesSeen_ == indexBytes_) {
    if (recordSize_ != 0 || glyphRecordsSeen_ != metadata_.glyphRecordCount ||
        expectedPayloadOffset_ != payloadBytes_)
      return false;
    state_ = State::Payload;
    sectionBytesSeen_ = 0;
  }
  return true;
}

bool StreamValidator::parseGlyphRecord() {
  const uint16_t glyphId = le16(record_.data());
  const uint8_t faceId = record_[2];
  const uint8_t sizeId = record_[3];
  const uint16_t width = le16(record_.data() + 10);
  const uint16_t height = le16(record_.data() + 12);
  const uint16_t reserved = le16(record_.data() + 14);
  const uint32_t fillOffset = le32(record_.data() + 16);
  const uint32_t fillLength = le32(record_.data() + 20);
  const uint32_t distanceOffset = le32(record_.data() + 24);
  const uint32_t distanceLength = le32(record_.data() + 28);
  const uint16_t expectedGlyph = static_cast<uint16_t>(glyphRecordsSeen_ / 3U + 1U);
  const uint8_t expectedSize = static_cast<uint8_t>(glyphRecordsSeen_ % 3U);
  if (glyphId != expectedGlyph || sizeId != expectedSize || !faceIds_[faceId] ||
      width == 0 || width > kMaximumGlyphDimension || height == 0 ||
      height > kMaximumGlyphDimension || reserved != 0 || fillLength == 0 ||
      distanceLength == 0 || fillOffset != expectedPayloadOffset_ ||
      distanceOffset != fillOffset + fillLength ||
      distanceOffset > payloadBytes_ ||
      distanceLength > payloadBytes_ - distanceOffset) {
    return false;
  }
  const uint32_t pixels = static_cast<uint32_t>(width) * height;
  bitmapRanges_.push_back(
      {fillLength, static_cast<uint16_t>(pixels)});
  bitmapRanges_.push_back(
      {distanceLength, static_cast<uint16_t>(pixels)});
  expectedPayloadOffset_ = distanceOffset + distanceLength;
  previousGlyphId_ = glyphId;
  previousSizeId_ = sizeId;
  (void)previousGlyphId_;
  (void)previousSizeId_;
  glyphRecordsSeen_++;
  recordSize_ = 0;
  return true;
}

bool StreamValidator::feedPayload(uint8_t byte) {
  if (++sectionBytesSeen_ > payloadBytes_ || bitmapRangeIndex_ >= bitmapRanges_.size())
    return false;
  const BitmapRange &range = bitmapRanges_[bitmapRangeIndex_];
  if (++bitmapEncodedSeen_ > range.encodedBytes)
    return false;
  if (rleRepeatValuePending_) {
    if (byte > 15)
      return false;
    rleRepeatValuePending_ = false;
    bitmapPixelsSeen_ = static_cast<uint16_t>(bitmapPixelsSeen_ + rleValuesRemaining_);
    rleValuesRemaining_ = 0;
  } else if (rleLiteral_ && rleValuesRemaining_ != 0) {
    if (byte > 15)
      return false;
    bitmapPixelsSeen_++;
    if (--rleValuesRemaining_ == 0)
      rleLiteral_ = false;
  } else {
    const uint8_t count = static_cast<uint8_t>((byte & 0x7fU) + 1U);
    if (count > range.pixels - bitmapPixelsSeen_)
      return false;
    rleValuesRemaining_ = count;
    if ((byte & 0x80U) != 0)
      rleRepeatValuePending_ = true;
    else
      rleLiteral_ = true;
  }
  if (bitmapEncodedSeen_ == range.encodedBytes && !finishBitmapRange())
    return false;
  if (sectionBytesSeen_ == payloadBytes_) {
    if (bitmapRangeIndex_ != bitmapRanges_.size())
      return false;
    state_ = State::Complete;
  }
  return true;
}

bool StreamValidator::finishBitmapRange() {
  const BitmapRange &range = bitmapRanges_[bitmapRangeIndex_];
  if (rleRepeatValuePending_ || rleLiteral_ || rleValuesRemaining_ != 0 ||
      bitmapPixelsSeen_ != range.pixels)
    return false;
  bitmapRangeIndex_++;
  bitmapEncodedSeen_ = 0;
  bitmapPixelsSeen_ = 0;
  return true;
}

bool StreamValidator::finish() {
  if (failed_)
    return false;
  if (state_ == State::Payload && payloadBytes_ == 0 && bitmapRanges_.empty())
    state_ = State::Complete;
  return state_ == State::Complete &&
         bytesSeen_ == 32ULL + languageTableBytes_ + faceTableBytes_ +
                           indexBytes_ + payloadBytes_;
}

bool validate(const uint8_t *data, size_t size, Metadata *metadata) {
  StreamValidator validator;
  if (!validator.feed(data, size) || !validator.finish())
    return false;
  if (metadata != nullptr)
    *metadata = validator.metadata();
  return true;
}

} // namespace map_font_asset_format
