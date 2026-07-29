#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace map_block_format {

constexpr size_t kMaximumBlockBytes = 2U * 1024U * 1024U;
constexpr uint32_t kMaximumFeatures = 16384;
constexpr uint32_t kMaximumPoints = 262144;
// The renderer expands every polygon bbox into a 16x16 spatial grid. Bound
// that decoded index separately from encoded feature/point counts so a small
// block cannot amplify into all available PSRAM.
constexpr uint32_t kMaximumPolygonGridEntries = 262144;
constexpr uint32_t kMaximumLabelStrings = 4096;
constexpr uint32_t kMaximumLabelStringBytes = 256U * 1024U;
constexpr uint32_t kMaximumLabelRuns = 12288;
constexpr uint32_t kMaximumRoadLabels = 8192;
constexpr uint32_t kMaximumLabelCandidates = 16384;
constexpr uint8_t kMaximumLabelVariants = 8;
constexpr uint8_t kMaximumGlyphsPerRun = 192;

// Performs the same structural walk as the renderer without allocating or
// dereferencing beyond the supplied bytes. Only renderer-supported binary map
// versions are accepted and every byte must belong to a complete record.
bool validate(const uint8_t *data, size_t size);

class StreamValidator {
public:
  explicit StreamValidator(const std::string &path);
  bool feed(const uint8_t *data, size_t size);
  bool finish();
  bool failed() const { return failed_; }

private:
  enum class Format { Invalid, Binary, Ascii };
  enum class BinaryState {
    Header,
    PolygonCount,
    PolygonFixed,
    PolygonPointCount,
    PolygonPoints,
    PolylineCount,
    PolylineFixed,
    PolylinePointCount,
    PolylinePoints,
    V3DirectoryHeader,
    V3DirectoryEntries,
    V3Sections,
    Complete,
  };
  enum class V3ParseState {
    None,
    StringCount,
    StringLength,
    StringBytes,
    RunCount,
    RunHeader,
    RunGlyph,
    LabelHeader,
    LabelFixed,
    LabelVariant,
    LabelCandidate,
    Complete,
  };
  enum class AsciiState {
    PolygonHeader,
    PolygonColor,
    PolygonZoom,
    PolygonTypeOrBbox,
    PolygonBbox,
    PolygonCoords,
    PolylineHeader,
    PolylineColor,
    PolylineWidth,
    PolylineZoom,
    PolylineTypeOrBbox,
    PolylineBbox,
    PolylineCoords,
    Complete,
  };
  enum class CoordinateState { Prefix, XStart, XDigits, YStart, YDigits };

  Format format_ = Format::Invalid;
  bool failed_ = false;
  BinaryState binaryState_ = BinaryState::Header;
  uint8_t binaryVersion_ = 0;
  uint8_t small_[4] = {};
  size_t smallSize_ = 0;
  uint8_t binaryFixed_[13] = {};
  size_t binaryFixedSize_ = 0;
  size_t binaryRemaining_ = 0;
  uint32_t recordsRemaining_ = 0;
  size_t bytesSeen_ = 0;
  uint32_t featuresSeen_ = 0;
  uint32_t pointsSeen_ = 0;
  uint32_t polygonGridEntries_ = 0;
  uint16_t binaryPolylineCount_ = 0;
  size_t binaryBytesProcessed_ = 0;
  struct V3Section {
    uint8_t type = 0;
    uint8_t flags = 0;
    uint32_t offset = 0;
    uint32_t length = 0;
    uint32_t crc32 = 0;
  };
  V3Section v3Sections_[3] = {};
  uint8_t v3Directory_[16] = {};
  size_t v3DirectorySize_ = 0;
  uint8_t v3SectionCount_ = 0;
  uint8_t v3DirectoryEntriesSeen_ = 0;
  size_t v3DirectoryStart_ = 0;
  uint8_t v3CurrentSection_ = 0;
  uint32_t v3SectionBytesSeen_ = 0;
  uint32_t v3SectionCrc_ = 0xFFFFFFFFU;
  V3ParseState v3ParseState_ = V3ParseState::None;
  uint8_t v3Record_[10] = {};
  size_t v3RecordSize_ = 0;
  uint32_t v3RecordsRemaining_ = 0;
  uint32_t v3ItemsRemaining_ = 0;
  uint32_t v3LabelCandidatesSeen_ = 0;
  uint32_t v3StringBytesSeen_ = 0;
  uint16_t v3StringCount_ = 0;
  uint16_t v3RunCount_ = 0;
  uint8_t v3VariantsRemaining_ = 0;
  uint8_t v3CandidatesRemaining_ = 0;
  uint8_t v3Utf8Remaining_ = 0;
  uint32_t v3Utf8Codepoint_ = 0;
  uint32_t v3Utf8Minimum_ = 0;
  AsciiState asciiState_ = AsciiState::PolygonHeader;
  std::string line_;
  CoordinateState coordinateState_ = CoordinateState::Prefix;
  size_t coordinatePrefix_ = 0;
  int32_t coordinateValue_ = 0;
  int coordinateSign_ = 1;
  bool coordinateHasDigit_ = false;
  bool coordinateLineHasPair_ = false;

  bool feedBinary(uint8_t byte);
  bool beginV3Extensions();
  bool feedV3Directory(uint8_t byte);
  bool feedV3Sections(uint8_t byte, size_t byteOffset);
  bool beginV3Section(uint8_t sectionIndex);
  bool feedV3SectionRecord(uint8_t byte);
  bool finishV3Section();
  bool feedV3Utf8(uint8_t byte);
  bool feedAscii(uint8_t byte);
  bool finishAsciiLine();
  bool feedCoordinate(uint8_t byte);
  void beginBinaryFixed(BinaryState state, size_t bytes);
  void beginCoordinateLine();
  bool addPolygonGridEntries(int16_t minX, int16_t minY, int16_t maxX,
                             int16_t maxY);
};

} // namespace map_block_format
