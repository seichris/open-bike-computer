#include "mapBlockFormat.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <limits>

namespace map_block_format {
namespace {

uint16_t littleEndian16(const uint8_t bytes[2]) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8U);
}

uint32_t littleEndian32(const uint8_t *bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8U) |
         (static_cast<uint32_t>(bytes[2]) << 16U) |
         (static_cast<uint32_t>(bytes[3]) << 24U);
}

uint32_t crc32Byte(uint32_t crc, uint8_t byte) {
  crc ^= byte;
  for (uint8_t bit = 0; bit < 8; ++bit)
    crc = (crc >> 1U) ^ (0xEDB88320U & (0U - (crc & 1U)));
  return crc;
}

bool unsignedValue(const std::string &text, uint32_t maximum,
                   uint32_t &value) {
  if (text.empty())
    return false;
  uint32_t parsed = 0;
  for (const char character : text) {
    if (character < '0' || character > '9')
      return false;
    const uint32_t digit = static_cast<uint32_t>(character - '0');
    if (parsed > (maximum - digit) / 10U)
      return false;
    parsed = parsed * 10U + digit;
  }
  value = parsed;
  return true;
}

bool smallUnsignedOrEmpty(const std::string &text) {
  if (text.empty())
    return true;
  uint32_t value = 0;
  return unsignedValue(text, 255, value);
}

bool colorValue(const std::string &text) {
  if (text.size() < 3 || text.size() > 10 || text[0] != '0' ||
      text[1] != 'x')
    return false;
  return std::all_of(text.begin() + 2, text.end(), [](unsigned char value) {
    return std::isxdigit(value) != 0;
  });
}

bool signed16(const std::string &text, size_t &offset, int16_t &result) {
  if (offset >= text.size())
    return false;
  int sign = 1;
  if (text[offset] == '-') {
    sign = -1;
    offset++;
  } else if (text[offset] == '+') {
    offset++;
  }
  if (offset >= text.size() || text[offset] < '0' || text[offset] > '9')
    return false;
  uint32_t value = 0;
  while (offset < text.size() && text[offset] >= '0' && text[offset] <= '9') {
    const uint32_t digit = static_cast<uint32_t>(text[offset] - '0');
    const uint32_t limit = sign > 0 ? 32767U : 32768U;
    if (value > (limit - digit) / 10U)
      return false;
    value = value * 10U + digit;
    offset++;
  }
  result = static_cast<int16_t>(sign > 0 ? static_cast<int32_t>(value)
                                         : -static_cast<int32_t>(value));
  return true;
}

bool bboxValue(const std::string &text, int16_t values[4] = nullptr) {
  if (text.compare(0, 5, "bbox:") != 0)
    return false;
  size_t offset = 5;
  for (size_t index = 0; index < 4; ++index) {
    int16_t value = 0;
    if (!signed16(text, offset, value))
      return false;
    if (values != nullptr)
      values[index] = value;
    if (index < 3) {
      if (offset >= text.size() || text[offset++] != ',')
        return false;
    }
  }
  return offset == text.size();
}

int16_t littleEndianSigned16(const uint8_t *bytes) {
  return static_cast<int16_t>(static_cast<uint16_t>(bytes[0]) |
                              (static_cast<uint16_t>(bytes[1]) << 8U));
}

bool countHeader(const std::string &text, const char *prefix,
                 uint32_t &count) {
  const size_t prefixSize = std::strlen(prefix);
  return text.compare(0, prefixSize, prefix) == 0 &&
         unsignedValue(text.substr(prefixSize), 32767, count);
}

} // namespace

StreamValidator::StreamValidator(const std::string &path) {
  if (path.size() >= 4 && path.compare(path.size() - 4, 4, ".fmb") == 0)
    format_ = Format::Binary;
  else if (path.size() >= 4 &&
           path.compare(path.size() - 4, 4, ".fmp") == 0)
    format_ = Format::Ascii;
  else
    failed_ = true;
}

bool StreamValidator::feed(const uint8_t *data, size_t size) {
  if (failed_ || (data == nullptr && size != 0))
    return false;
  if (size > kMaximumBlockBytes - bytesSeen_) {
    failed_ = true;
    return false;
  }
  bytesSeen_ += size;
  for (size_t index = 0; index < size; ++index) {
    const bool accepted = format_ == Format::Binary
                              ? feedBinary(data[index])
                              : format_ == Format::Ascii && feedAscii(data[index]);
    if (!accepted) {
      failed_ = true;
      return false;
    }
  }
  return true;
}

void StreamValidator::beginBinaryFixed(BinaryState state, size_t bytes) {
  binaryState_ = state;
  binaryRemaining_ = bytes;
  binaryFixedSize_ = 0;
}

bool StreamValidator::addPolygonGridEntries(int16_t minX, int16_t minY,
                                            int16_t maxX, int16_t maxY) {
  const auto cell = [](int16_t coordinate) {
    if (coordinate <= 0)
      return 0;
    return std::min(15, static_cast<int>(coordinate) / 256);
  };
  const int minCellX = cell(minX);
  const int minCellY = cell(minY);
  const int maxCellX = cell(maxX);
  const int maxCellY = cell(maxY);
  if (minCellX > maxCellX || minCellY > maxCellY)
    return true;
  const uint32_t entries =
      static_cast<uint32_t>(maxCellX - minCellX + 1) *
      static_cast<uint32_t>(maxCellY - minCellY + 1);
  if (entries > kMaximumPolygonGridEntries - polygonGridEntries_)
    return false;
  polygonGridEntries_ += entries;
  return true;
}

bool StreamValidator::feedBinary(uint8_t byte) {
  const size_t byteOffset = binaryBytesProcessed_++;
  if (binaryState_ == BinaryState::Complete)
    return false;
  if (binaryState_ == BinaryState::V3DirectoryHeader ||
      binaryState_ == BinaryState::V3DirectoryEntries)
    return feedV3Directory(byte);
  if (binaryState_ == BinaryState::V3Sections)
    return feedV3Sections(byte, byteOffset);
  if (binaryState_ == BinaryState::Header) {
    small_[smallSize_++] = byte;
    if (smallSize_ != 4)
      return true;
    if (std::memcmp(small_, "FMB", 3) != 0 ||
        (small_[3] != 1 && small_[3] != 2 && small_[3] != 3 &&
         small_[3] != 4))
      return false;
    binaryVersion_ = small_[3];
    smallSize_ = 0;
    binaryState_ = BinaryState::PolygonCount;
    return true;
  }
  if (binaryState_ == BinaryState::PolygonCount ||
      binaryState_ == BinaryState::PolygonPointCount ||
      binaryState_ == BinaryState::PolylineCount ||
      binaryState_ == BinaryState::PolylinePointCount) {
    small_[smallSize_++] = byte;
    if (smallSize_ != 2)
      return true;
    const uint16_t value = littleEndian16(small_);
    smallSize_ = 0;
    if (binaryState_ == BinaryState::PolygonCount) {
      recordsRemaining_ = value;
      featuresSeen_ = value;
      if (featuresSeen_ > kMaximumFeatures)
        return false;
      if (recordsRemaining_ == 0)
        binaryState_ = BinaryState::PolylineCount;
      else
        beginBinaryFixed(BinaryState::PolygonFixed,
                         11U + (binaryVersion_ >= 2 ? 1U : 0U));
    } else if (binaryState_ == BinaryState::PolygonPointCount) {
      if (value == 0)
        return false;
      if (value > kMaximumPoints - pointsSeen_)
        return false;
      pointsSeen_ += value;
      beginBinaryFixed(BinaryState::PolygonPoints,
                       static_cast<size_t>(value) * 4U);
    } else if (binaryState_ == BinaryState::PolylineCount) {
      recordsRemaining_ = value;
      binaryPolylineCount_ = value;
      if (value > kMaximumFeatures - featuresSeen_)
        return false;
      featuresSeen_ += value;
      if (recordsRemaining_ == 0) {
        if (binaryVersion_ >= 3)
          return beginV3Extensions();
        binaryState_ = BinaryState::Complete;
      }
      else
        beginBinaryFixed(BinaryState::PolylineFixed,
                         12U + (binaryVersion_ >= 2 ? 1U : 0U));
    } else {
      if (value == 0)
        return false;
      if (value > kMaximumPoints - pointsSeen_)
        return false;
      pointsSeen_ += value;
      beginBinaryFixed(BinaryState::PolylinePoints,
                       static_cast<size_t>(value) * 4U);
    }
    return true;
  }

  if (binaryRemaining_ == 0)
    return false;
  if (binaryState_ == BinaryState::PolygonFixed) {
    if (binaryFixedSize_ >= sizeof(binaryFixed_))
      return false;
    binaryFixed_[binaryFixedSize_++] = byte;
  }
  binaryRemaining_--;
  if (binaryRemaining_ != 0)
    return true;
  if (binaryState_ == BinaryState::PolygonFixed) {
    const size_t bboxOffset = binaryVersion_ >= 2 ? 4U : 3U;
    if (!addPolygonGridEntries(
            littleEndianSigned16(binaryFixed_ + bboxOffset),
            littleEndianSigned16(binaryFixed_ + bboxOffset + 2U),
            littleEndianSigned16(binaryFixed_ + bboxOffset + 4U),
            littleEndianSigned16(binaryFixed_ + bboxOffset + 6U)))
      return false;
    binaryState_ = BinaryState::PolygonPointCount;
  } else if (binaryState_ == BinaryState::PolygonPoints) {
    if (--recordsRemaining_ == 0)
      binaryState_ = BinaryState::PolylineCount;
    else
      beginBinaryFixed(BinaryState::PolygonFixed,
                       11U + (binaryVersion_ >= 2 ? 1U : 0U));
  } else if (binaryState_ == BinaryState::PolylineFixed) {
    binaryState_ = BinaryState::PolylinePointCount;
  } else if (binaryState_ == BinaryState::PolylinePoints) {
    if (--recordsRemaining_ == 0) {
      if (binaryVersion_ >= 3)
        return beginV3Extensions();
      binaryState_ = BinaryState::Complete;
    }
    else
      beginBinaryFixed(BinaryState::PolylineFixed,
                       12U + (binaryVersion_ >= 2 ? 1U : 0U));
  }
  return true;
}

bool StreamValidator::beginV3Extensions() {
  binaryState_ = BinaryState::V3DirectoryHeader;
  v3DirectoryStart_ = binaryBytesProcessed_;
  v3DirectorySize_ = 0;
  return true;
}

bool StreamValidator::feedV3Directory(uint8_t byte) {
  if (v3DirectorySize_ >= sizeof(v3Directory_))
    return false;
  v3Directory_[v3DirectorySize_++] = byte;
  if (binaryState_ == BinaryState::V3DirectoryHeader) {
    if (v3DirectorySize_ != 8)
      return true;
    const char expectedVersion = static_cast<char>('0' + binaryVersion_);
    if (std::memcmp(v3Directory_, "EXT", 3) != 0 ||
        v3Directory_[3] != static_cast<uint8_t>(expectedVersion) ||
        v3Directory_[4] != binaryVersion_ || v3Directory_[5] != 0 ||
        v3Directory_[6] != 0 || v3Directory_[7] != 0)
      return false;
    v3SectionCount_ = v3Directory_[4];
    v3DirectorySize_ = 0;
    binaryState_ = BinaryState::V3DirectoryEntries;
    return true;
  }
  if (v3DirectorySize_ != 16)
    return true;

  if (v3DirectoryEntriesSeen_ >= v3SectionCount_)
    return false;
  V3Section &section = v3Sections_[v3DirectoryEntriesSeen_];
  section.type = v3Directory_[0];
  section.flags = v3Directory_[1];
  if (v3Directory_[2] != 0 || v3Directory_[3] != 0 ||
      section.type != static_cast<uint8_t>(v3DirectoryEntriesSeen_ + 1U) ||
      section.flags != 1)
    return false;
  section.offset = littleEndian32(v3Directory_ + 4);
  section.length = littleEndian32(v3Directory_ + 8);
  section.crc32 = littleEndian32(v3Directory_ + 12);
  if (section.length == 0)
    return false;
  v3DirectoryEntriesSeen_++;
  v3DirectorySize_ = 0;
  if (v3DirectoryEntriesSeen_ != v3SectionCount_)
    return true;

  uint32_t expectedOffset = static_cast<uint32_t>(
      v3DirectoryStart_ + 8U + static_cast<size_t>(v3SectionCount_) * 16U);
  for (uint8_t index = 0; index < v3SectionCount_; ++index) {
    const V3Section &candidate = v3Sections_[index];
    if (candidate.offset != expectedOffset ||
        candidate.length > kMaximumBlockBytes - expectedOffset)
      return false;
    expectedOffset += candidate.length;
  }
  binaryState_ = BinaryState::V3Sections;
  return beginV3Section(0);
}

bool StreamValidator::beginV3Section(uint8_t sectionIndex) {
  if (sectionIndex >= v3SectionCount_)
    return false;
  v3CurrentSection_ = sectionIndex;
  v3SectionBytesSeen_ = 0;
  v3SectionCrc_ = 0xFFFFFFFFU;
  v3RecordSize_ = 0;
  v3RecordsRemaining_ = 0;
  v3ItemsRemaining_ = 0;
  switch (v3Sections_[sectionIndex].type) {
  case 1:
    v3ParseState_ = V3ParseState::StringCount;
    break;
  case 2:
    v3ParseState_ = V3ParseState::RunCount;
    break;
  case 3:
    v3ParseState_ = V3ParseState::LabelHeader;
    break;
  case 4:
    v3ParseState_ = V3ParseState::BuildingHeader;
    v4DeclaredBuildingPoints_ = 0;
    v4BuildingPointsSeen_ = 0;
    break;
  default:
    return false;
  }
  return true;
}

bool StreamValidator::feedV3Sections(uint8_t byte, size_t byteOffset) {
  if (v3CurrentSection_ >= v3SectionCount_)
    return false;
  const V3Section &section = v3Sections_[v3CurrentSection_];
  if (byteOffset != static_cast<size_t>(section.offset) + v3SectionBytesSeen_ ||
      v3SectionBytesSeen_ >= section.length)
    return false;
  v3SectionCrc_ = crc32Byte(v3SectionCrc_, byte);
  v3SectionBytesSeen_++;
  if (!feedV3SectionRecord(byte))
    return false;
  if (v3SectionBytesSeen_ != section.length)
    return true;
  if (!finishV3Section() || (v3SectionCrc_ ^ 0xFFFFFFFFU) != section.crc32)
    return false;
  if (++v3CurrentSection_ == v3SectionCount_) {
    binaryState_ = BinaryState::Complete;
    return true;
  }
  return beginV3Section(v3CurrentSection_);
}

bool StreamValidator::feedV3Utf8(uint8_t byte) {
  if (v3Utf8Remaining_ == 0) {
    if (byte <= 0x7FU) {
      return byte != 0 && byte >= 0x20U && byte != 0x7FU;
    }
    if (byte >= 0xC2U && byte <= 0xDFU) {
      v3Utf8Remaining_ = 1;
      v3Utf8Codepoint_ = byte & 0x1FU;
      v3Utf8Minimum_ = 0x80U;
      return true;
    }
    if (byte >= 0xE0U && byte <= 0xEFU) {
      v3Utf8Remaining_ = 2;
      v3Utf8Codepoint_ = byte & 0x0FU;
      v3Utf8Minimum_ = 0x800U;
      return true;
    }
    if (byte >= 0xF0U && byte <= 0xF4U) {
      v3Utf8Remaining_ = 3;
      v3Utf8Codepoint_ = byte & 0x07U;
      v3Utf8Minimum_ = 0x10000U;
      return true;
    }
    return false;
  }
  if ((byte & 0xC0U) != 0x80U)
    return false;
  v3Utf8Codepoint_ = (v3Utf8Codepoint_ << 6U) | (byte & 0x3FU);
  if (--v3Utf8Remaining_ != 0)
    return true;
  const uint32_t value = v3Utf8Codepoint_;
  return value >= v3Utf8Minimum_ && value <= 0x10FFFFU &&
         !(value >= 0xD800U && value <= 0xDFFFU) &&
         !(value >= 0x80U && value <= 0x9FU) &&
         !(value >= 0x202AU && value <= 0x202EU);
}

bool StreamValidator::feedV3SectionRecord(uint8_t byte) {
  const auto collect = [&](size_t size) {
    if (size > sizeof(v3Record_) || v3RecordSize_ >= size)
      return false;
    v3Record_[v3RecordSize_++] = byte;
    return true;
  };
  switch (v3ParseState_) {
  case V3ParseState::StringCount:
    if (!collect(2) || v3RecordSize_ != 2)
      return true;
    v3StringCount_ = littleEndian16(v3Record_);
    if (v3StringCount_ > kMaximumLabelStrings)
      return false;
    v3RecordsRemaining_ = v3StringCount_;
    v3RecordSize_ = 0;
    v3ParseState_ = v3RecordsRemaining_ == 0 ? V3ParseState::Complete
                                              : V3ParseState::StringLength;
    return true;
  case V3ParseState::StringLength:
    if (!collect(2) || v3RecordSize_ != 2)
      return true;
    v3ItemsRemaining_ = littleEndian16(v3Record_);
    if (v3ItemsRemaining_ == 0 || v3ItemsRemaining_ > 255 ||
        v3ItemsRemaining_ > kMaximumLabelStringBytes - v3StringBytesSeen_)
      return false;
    v3StringBytesSeen_ += v3ItemsRemaining_;
    v3Utf8Remaining_ = 0;
    v3RecordSize_ = 0;
    v3ParseState_ = V3ParseState::StringBytes;
    return true;
  case V3ParseState::StringBytes:
    if (!feedV3Utf8(byte) || v3ItemsRemaining_ == 0)
      return false;
    if (--v3ItemsRemaining_ != 0)
      return true;
    if (v3Utf8Remaining_ != 0)
      return false;
    v3ParseState_ = --v3RecordsRemaining_ == 0
                        ? V3ParseState::Complete
                        : V3ParseState::StringLength;
    return true;
  case V3ParseState::RunCount:
    if (!collect(2) || v3RecordSize_ != 2)
      return true;
    v3RunCount_ = littleEndian16(v3Record_);
    if (v3RunCount_ > kMaximumLabelRuns)
      return false;
    v3RecordsRemaining_ = v3RunCount_;
    v3RecordSize_ = 0;
    v3ParseState_ = v3RecordsRemaining_ == 0 ? V3ParseState::Complete
                                              : V3ParseState::RunHeader;
    return true;
  case V3ParseState::RunHeader:
    if (!collect(4) || v3RecordSize_ != 4)
      return true;
    v3ItemsRemaining_ = v3Record_[3];
    if (littleEndian16(v3Record_) == 0 ||
        littleEndian16(v3Record_) > v3StringCount_ || v3Record_[2] > 2 ||
        v3ItemsRemaining_ == 0 ||
        v3ItemsRemaining_ > kMaximumGlyphsPerRun)
      return false;
    v3RecordSize_ = 0;
    v3ParseState_ = V3ParseState::RunGlyph;
    return true;
  case V3ParseState::RunGlyph:
    if (!collect(8) || v3RecordSize_ != 8)
      return true;
    if (littleEndian16(v3Record_) == 0)
      return false;
    v3RecordSize_ = 0;
    if (--v3ItemsRemaining_ == 0) {
      v3ParseState_ = --v3RecordsRemaining_ == 0
                          ? V3ParseState::Complete
                          : V3ParseState::RunHeader;
    }
    return true;
  case V3ParseState::LabelHeader:
    if (!collect(6) || v3RecordSize_ != 6)
      return true;
    v3RecordsRemaining_ = littleEndian16(v3Record_ + 4);
    if (v3RecordsRemaining_ > kMaximumRoadLabels)
      return false;
    v3RecordSize_ = 0;
    v3ParseState_ = v3RecordsRemaining_ == 0 ? V3ParseState::Complete
                                              : V3ParseState::LabelFixed;
    return true;
  case V3ParseState::LabelFixed:
    if (!collect(9) || v3RecordSize_ != 9)
      return true;
    v3VariantsRemaining_ = v3Record_[7];
    v3CandidatesRemaining_ = v3Record_[8];
    if (littleEndian16(v3Record_) >= binaryPolylineCount_ ||
        v3Record_[2] > 6 || v3Record_[3] > v3Record_[4] ||
        littleEndian16(v3Record_ + 5) == 0 ||
        v3VariantsRemaining_ == 0 ||
        v3VariantsRemaining_ > kMaximumLabelVariants ||
        v3CandidatesRemaining_ == 0 ||
        v3CandidatesRemaining_ >
            kMaximumLabelCandidates - v3LabelCandidatesSeen_)
      return false;
    v3LabelCandidatesSeen_ += v3CandidatesRemaining_;
    v3RecordSize_ = 0;
    v3ParseState_ = V3ParseState::LabelVariant;
    return true;
  case V3ParseState::LabelVariant:
    if (!collect(10) || v3RecordSize_ != 10)
      return true;
    if (v3Record_[0] > 3 ||
        (v3Record_[1] != 0 && v3Record_[1] != 255 && v3Record_[1] > 3) ||
        littleEndian16(v3Record_ + 2) == 0 ||
        littleEndian16(v3Record_ + 2) > v3StringCount_)
      return false;
    for (size_t offset : {4U, 6U, 8U}) {
      if (littleEndian16(v3Record_ + offset) == 0 ||
          littleEndian16(v3Record_ + offset) > v3RunCount_)
        return false;
    }
    v3RecordSize_ = 0;
    if (--v3VariantsRemaining_ == 0)
      v3ParseState_ = V3ParseState::LabelCandidate;
    return true;
  case V3ParseState::LabelCandidate:
    if (!collect(10) || v3RecordSize_ != 10)
      return true;
    if (v3Record_[9] != 0)
      return false;
    v3RecordSize_ = 0;
    if (--v3CandidatesRemaining_ == 0) {
      v3ParseState_ = --v3RecordsRemaining_ == 0
                          ? V3ParseState::Complete
                          : V3ParseState::LabelFixed;
    }
    return true;
  case V3ParseState::BuildingHeader:
    if (!collect(8) || v3RecordSize_ != 8)
      return true;
    v3RecordsRemaining_ = littleEndian16(v3Record_);
    v4DeclaredBuildingPoints_ = littleEndian32(v3Record_ + 4);
    if (littleEndian16(v3Record_ + 2) != 0 ||
        v3RecordsRemaining_ > kMaximumBuildings ||
        v4DeclaredBuildingPoints_ > kMaximumBuildingPoints)
      return false;
    v3RecordSize_ = 0;
    v3ParseState_ = v3RecordsRemaining_ == 0
                        ? V3ParseState::Complete
                        : V3ParseState::BuildingFixed;
    return true;
  case V3ParseState::BuildingFixed:
    if (!collect(18) || v3RecordSize_ != 18)
      return true;
    v4RingsRemaining_ = littleEndian16(v3Record_ + 16);
    v4CurrentRingIndex_ = 0;
    v4DeclaredBounds_[0] = littleEndianSigned16(v3Record_ + 8);
    v4DeclaredBounds_[1] = littleEndianSigned16(v3Record_ + 10);
    v4DeclaredBounds_[2] = littleEndianSigned16(v3Record_ + 12);
    v4DeclaredBounds_[3] = littleEndianSigned16(v3Record_ + 14);
    if (v3Record_[0] != 100 || (v3Record_[1] & ~1U) != 0 ||
        v3Record_[2] > 4 || v3Record_[3] != 0 ||
        littleEndian16(v3Record_ + 6) >= littleEndian16(v3Record_ + 4) ||
        v4DeclaredBounds_[0] > v4DeclaredBounds_[2] ||
        v4DeclaredBounds_[1] > v4DeclaredBounds_[3] ||
        v4RingsRemaining_ == 0 ||
        v4RingsRemaining_ > kMaximumBuildingRings)
      return false;
    v4ActualBounds_[0] = 32767;
    v4ActualBounds_[1] = 32767;
    v4ActualBounds_[2] = -32768;
    v4ActualBounds_[3] = -32768;
    v3RecordSize_ = 0;
    v3ParseState_ = V3ParseState::BuildingRingHeader;
    return true;
  case V3ParseState::BuildingRingHeader:
    if (!collect(4) || v3RecordSize_ != 4)
      return true;
    v4RingPointCount_ = littleEndian16(v3Record_);
    v4RingPointsRemaining_ = v4RingPointCount_;
    v4WallBytesRemaining_ =
        static_cast<uint16_t>((v4RingPointCount_ + 7U) / 8U);
    if (v4RingPointCount_ < 3 ||
        v4RingPointCount_ > kMaximumBuildingPoints - v4BuildingPointsSeen_ ||
        v3Record_[2] != (v4CurrentRingIndex_ == 0 ? 0 : 1) ||
        v3Record_[3] != 0)
      return false;
    v4BuildingPointsSeen_ += v4RingPointCount_;
    v3RecordSize_ = 0;
    v3ParseState_ = V3ParseState::BuildingRingPoints;
    return true;
  case V3ParseState::BuildingRingPoints:
    if (!collect(4) || v3RecordSize_ != 4)
      return true;
    {
      const int16_t x = littleEndianSigned16(v3Record_);
      const int16_t y = littleEndianSigned16(v3Record_ + 2);
      v4ActualBounds_[0] = std::min(v4ActualBounds_[0], x);
      v4ActualBounds_[1] = std::min(v4ActualBounds_[1], y);
      v4ActualBounds_[2] = std::max(v4ActualBounds_[2], x);
      v4ActualBounds_[3] = std::max(v4ActualBounds_[3], y);
    }
    v3RecordSize_ = 0;
    if (--v4RingPointsRemaining_ == 0)
      v3ParseState_ = V3ParseState::BuildingWallMask;
    return true;
  case V3ParseState::BuildingWallMask:
    if (v4WallBytesRemaining_ == 0)
      return false;
    if (v4WallBytesRemaining_ == 1 && (v4RingPointCount_ % 8U) != 0 &&
        (byte & ~((1U << (v4RingPointCount_ % 8U)) - 1U)) != 0)
      return false;
    if (--v4WallBytesRemaining_ != 0)
      return true;
    ++v4CurrentRingIndex_;
    if (--v4RingsRemaining_ != 0) {
      v3ParseState_ = V3ParseState::BuildingRingHeader;
      return true;
    }
    if (!std::equal(std::begin(v4DeclaredBounds_),
                    std::end(v4DeclaredBounds_),
                    std::begin(v4ActualBounds_)))
      return false;
    v3ParseState_ = --v3RecordsRemaining_ == 0
                        ? V3ParseState::Complete
                        : V3ParseState::BuildingFixed;
    return true;
  case V3ParseState::None:
  case V3ParseState::Complete:
    return false;
  }
  return false;
}

bool StreamValidator::finishV3Section() {
  return v3ParseState_ == V3ParseState::Complete && v3RecordSize_ == 0 &&
         v3Utf8Remaining_ == 0 &&
         (v3Sections_[v3CurrentSection_].type != 4 ||
          v4BuildingPointsSeen_ == v4DeclaredBuildingPoints_);
}

void StreamValidator::beginCoordinateLine() {
  coordinateState_ = CoordinateState::Prefix;
  coordinatePrefix_ = 0;
  coordinateValue_ = 0;
  coordinateSign_ = 1;
  coordinateHasDigit_ = false;
  coordinateLineHasPair_ = false;
}

bool StreamValidator::feedCoordinate(uint8_t byte) {
  static constexpr char kPrefix[] = "coords:";
  if (coordinateState_ == CoordinateState::Prefix) {
    if (coordinatePrefix_ >= sizeof(kPrefix) - 1 ||
        byte != static_cast<uint8_t>(kPrefix[coordinatePrefix_++]))
      return false;
    if (coordinatePrefix_ == sizeof(kPrefix) - 1)
      coordinateState_ = CoordinateState::XStart;
    return true;
  }
  const auto startNumber = [&](CoordinateState digits) {
    coordinateValue_ = 0;
    coordinateSign_ = 1;
    coordinateHasDigit_ = false;
    if (byte == '-' || byte == '+') {
      coordinateSign_ = byte == '-' ? -1 : 1;
      coordinateState_ = digits;
      return true;
    }
    if (byte < '0' || byte > '9')
      return false;
    coordinateValue_ = byte - '0';
    coordinateHasDigit_ = true;
    coordinateState_ = digits;
    return true;
  };
  if (coordinateState_ == CoordinateState::XStart)
    return startNumber(CoordinateState::XDigits);
  if (coordinateState_ == CoordinateState::YStart)
    return startNumber(CoordinateState::YDigits);
  if (byte >= '0' && byte <= '9') {
    const int32_t digit = byte - '0';
    const int32_t limit = coordinateSign_ > 0 ? 32767 : 32768;
    if (coordinateValue_ > (limit - digit) / 10)
      return false;
    coordinateValue_ = coordinateValue_ * 10 + digit;
    coordinateHasDigit_ = true;
    return true;
  }
  if (coordinateState_ == CoordinateState::XDigits && coordinateHasDigit_ &&
      byte == ',') {
    coordinateState_ = CoordinateState::YStart;
    return true;
  }
  if (coordinateState_ == CoordinateState::YDigits && coordinateHasDigit_ &&
      byte == ';') {
    if (pointsSeen_ == kMaximumPoints)
      return false;
    pointsSeen_++;
    coordinateState_ = CoordinateState::XStart;
    coordinateLineHasPair_ = true;
    return true;
  }
  return false;
}

bool StreamValidator::finishAsciiLine() {
  uint32_t count = 0;
  switch (asciiState_) {
  case AsciiState::PolygonHeader:
    if (!countHeader(line_, "Polygons:", count))
      return false;
    recordsRemaining_ = count;
    featuresSeen_ = count;
    if (featuresSeen_ > kMaximumFeatures)
      return false;
    asciiState_ = recordsRemaining_ == 0 ? AsciiState::PolylineHeader
                                         : AsciiState::PolygonColor;
    break;
  case AsciiState::PolygonColor:
    if (!colorValue(line_))
      return false;
    asciiState_ = AsciiState::PolygonZoom;
    break;
  case AsciiState::PolygonZoom:
    if (!smallUnsignedOrEmpty(line_))
      return false;
    asciiState_ = AsciiState::PolygonTypeOrBbox;
    break;
  case AsciiState::PolygonTypeOrBbox:
    {
      int16_t bbox[4] = {};
      if (bboxValue(line_, bbox)) {
        if (!addPolygonGridEntries(bbox[0], bbox[1], bbox[2], bbox[3]))
          return false;
        asciiState_ = AsciiState::PolygonCoords;
        beginCoordinateLine();
      } else {
        uint32_t typeId = 0;
        if (!unsignedValue(line_, 255, typeId))
          return false;
        asciiState_ = AsciiState::PolygonBbox;
      }
    }
    break;
  case AsciiState::PolygonBbox:
    {
      int16_t bbox[4] = {};
      if (!bboxValue(line_, bbox) ||
          !addPolygonGridEntries(bbox[0], bbox[1], bbox[2], bbox[3]))
        return false;
      asciiState_ = AsciiState::PolygonCoords;
      beginCoordinateLine();
    }
    break;
  case AsciiState::PolylineHeader:
    if (!countHeader(line_, "Polylines:", count))
      return false;
    recordsRemaining_ = count;
    if (count > kMaximumFeatures - featuresSeen_)
      return false;
    featuresSeen_ += count;
    asciiState_ = recordsRemaining_ == 0 ? AsciiState::Complete
                                         : AsciiState::PolylineColor;
    break;
  case AsciiState::PolylineColor:
    if (!colorValue(line_))
      return false;
    asciiState_ = AsciiState::PolylineWidth;
    break;
  case AsciiState::PolylineWidth:
    if (!smallUnsignedOrEmpty(line_))
      return false;
    asciiState_ = AsciiState::PolylineZoom;
    break;
  case AsciiState::PolylineZoom:
    if (!smallUnsignedOrEmpty(line_))
      return false;
    asciiState_ = AsciiState::PolylineTypeOrBbox;
    break;
  case AsciiState::PolylineTypeOrBbox:
    if (bboxValue(line_)) {
      asciiState_ = AsciiState::PolylineCoords;
      beginCoordinateLine();
    } else {
      uint32_t typeId = 0;
      if (!unsignedValue(line_, 255, typeId))
        return false;
      asciiState_ = AsciiState::PolylineBbox;
    }
    break;
  case AsciiState::PolylineBbox:
    if (!bboxValue(line_))
      return false;
    asciiState_ = AsciiState::PolylineCoords;
    beginCoordinateLine();
    break;
  case AsciiState::PolygonCoords:
  case AsciiState::PolylineCoords:
  case AsciiState::Complete:
    return false;
  }
  line_.clear();
  return true;
}

bool StreamValidator::feedAscii(uint8_t byte) {
  if (byte == '\r')
    return true;
  if (asciiState_ == AsciiState::Complete)
    return false;
  const bool coordinates = asciiState_ == AsciiState::PolygonCoords ||
                           asciiState_ == AsciiState::PolylineCoords;
  if (byte != '\n') {
    if (coordinates)
      return feedCoordinate(byte);
    if (line_.size() >= 128)
      return false;
    line_.push_back(static_cast<char>(byte));
    return true;
  }
  if (!coordinates)
    return finishAsciiLine();
  if (coordinateState_ != CoordinateState::XStart ||
      !coordinateLineHasPair_)
    return false;
  if (asciiState_ == AsciiState::PolygonCoords) {
    if (--recordsRemaining_ == 0)
      asciiState_ = AsciiState::PolylineHeader;
    else
      asciiState_ = AsciiState::PolygonColor;
  } else {
    if (--recordsRemaining_ == 0)
      asciiState_ = AsciiState::Complete;
    else
      asciiState_ = AsciiState::PolylineColor;
  }
  return true;
}

bool StreamValidator::finish() {
  if (failed_)
    return false;
  return (format_ == Format::Binary &&
          binaryState_ == BinaryState::Complete) ||
         (format_ == Format::Ascii && asciiState_ == AsciiState::Complete);
}

bool validate(const uint8_t *data, size_t size) {
  StreamValidator validator("block.fmb");
  return validator.feed(data, size) && validator.finish();
}

} // namespace map_block_format
