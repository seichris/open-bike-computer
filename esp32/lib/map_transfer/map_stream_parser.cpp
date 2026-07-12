#include "map_stream_parser.hpp"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <new>
#include <utility>

#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
#include <esp_heap_caps.h>
#endif

namespace map_transfer {
namespace {

void *allocateStreamMemory(size_t bytes) {
  if (bytes == 0)
    return nullptr;
#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
  return heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#else
  return std::malloc(bytes);
#endif
}

void freeStreamMemory(void *memory) {
  if (memory == nullptr)
    return;
#if defined(ARDUINO) && defined(BOARD_HAS_PSRAM)
  heap_caps_free(memory);
#else
  std::free(memory);
#endif
}

class ManifestJsonReader {
public:
  ManifestJsonReader(std::string_view text, uint32_t expectedFileCount)
      : text_(text), expectedFileCount_(expectedFileCount) {}

  bool parse(ParsedMapStreamManifest &parsed) {
    MapManifest &manifest = parsed.metadata;
    bool haveSchema = false;
    bool haveMapId = false;
    bool haveFiles = false;
    bool haveTarget = false;
    uint64_t schema = 0;
    skipWhitespace();
    if (!consume('{'))
      return false;
    skipWhitespace();
    if (consume('}'))
      return false;
    std::string previousKey;
    while (true) {
      std::string key;
      if (!parseString(key) || (!previousKey.empty() && key <= previousKey) ||
          !consumeAfterWhitespace(':'))
        return false;
      previousKey = key;
      if (key == "schemaVersion") {
        if (haveSchema || !parseUnsigned(schema))
          return false;
        haveSchema = true;
      } else if (key == "mapId") {
        if (haveMapId || !parseString(manifest.mapId))
          return false;
        haveMapId = true;
      } else if (key == "files") {
        if (haveFiles || !parseFiles(parsed.files))
          return false;
        haveFiles = true;
      } else if (key == "target") {
        if (haveTarget || !parseTarget(manifest))
          return false;
        haveTarget = true;
      } else if (!skipValue(0)) {
        return false;
      }
      skipWhitespace();
      if (consume('}'))
        break;
      if (!consume(','))
        return false;
      skipWhitespace();
    }
    skipWhitespace();
    if (position_ != text_.size() || !canonical_ || !haveSchema || !haveMapId ||
        !haveFiles || !haveTarget || schema != 1 ||
        manifest.renderer != "esp32-fmb" || manifest.formatVersion != 1) {
      return false;
    }
    manifest.schemaVersion = static_cast<uint32_t>(schema);
    return true;
  }

private:
  std::string_view text_;
  uint32_t expectedFileCount_ = 0;
  size_t position_ = 0;
  bool canonical_ = true;

  void skipWhitespace() {
    while (position_ < text_.size() &&
           (text_[position_] == ' ' || text_[position_] == '\n' ||
            text_[position_] == '\r' || text_[position_] == '\t')) {
      canonical_ = false;
      position_++;
    }
  }

  bool consume(char expected) {
    if (position_ >= text_.size() || text_[position_] != expected)
      return false;
    position_++;
    return true;
  }

  bool consumeAfterWhitespace(char expected) {
    skipWhitespace();
    if (!consume(expected))
      return false;
    skipWhitespace();
    return true;
  }

  bool parseString(std::string &output, uint32_t *rawOffset = nullptr,
                   uint16_t *rawBytes = nullptr) {
    skipWhitespace();
    if (!consume('"'))
      return false;
    const size_t rawStart = position_;
    bool escapedValue = false;
    output.clear();
    while (position_ < text_.size()) {
      const unsigned char character =
          static_cast<unsigned char>(text_[position_++]);
      if (character == '"') {
        const size_t bytes = position_ - rawStart - 1;
        if ((rawOffset != nullptr || rawBytes != nullptr) && escapedValue)
          return false;
        if (rawOffset != nullptr) {
          if (rawStart > UINT32_MAX)
            return false;
          *rawOffset = static_cast<uint32_t>(rawStart);
        }
        if (rawBytes != nullptr) {
          if (bytes > UINT16_MAX)
            return false;
          *rawBytes = static_cast<uint16_t>(bytes);
        }
        return true;
      }
      if (character < 0x20)
        return false;
      if (character != '\\') {
        if (output.size() >= 256)
          return false;
        output.push_back(static_cast<char>(character));
        continue;
      }
      escapedValue = true;
      if (position_ >= text_.size())
        return false;
      const char escaped = text_[position_++];
      switch (escaped) {
      case '"':
      case '\\':
      case '/':
        if (output.size() >= 256)
          return false;
        output.push_back(escaped);
        break;
      case 'b':
        if (output.size() >= 256)
          return false;
        output.push_back('\b');
        break;
      case 'f':
        if (output.size() >= 256)
          return false;
        output.push_back('\f');
        break;
      case 'n':
        if (output.size() >= 256)
          return false;
        output.push_back('\n');
        break;
      case 'r':
        if (output.size() >= 256)
          return false;
        output.push_back('\r');
        break;
      case 't':
        if (output.size() >= 256)
          return false;
        output.push_back('\t');
        break;
      case 'u':
        if (position_ + 4 > text_.size())
          return false;
        for (size_t index = 0; index < 4; index++) {
          const char digit = text_[position_ + index];
          if (!((digit >= '0' && digit <= '9') ||
                (digit >= 'a' && digit <= 'f') ||
                (digit >= 'A' && digit <= 'F'))) {
            return false;
          }
        }
        // Canonical identity/path fields are restricted ASCII and never use
        // unicode escapes. Preserve JSON validity while making any escaped
        // identity fail the later safe-character validation.
        if (output.size() >= 256)
          return false;
        output.push_back('?');
        position_ += 4;
        break;
      default:
        return false;
      }
    }
    return false;
  }

  bool skipString() {
    skipWhitespace();
    if (!consume('"'))
      return false;
    while (position_ < text_.size()) {
      const unsigned char character =
          static_cast<unsigned char>(text_[position_++]);
      if (character == '"')
        return true;
      if (character < 0x20)
        return false;
      if (character != '\\')
        continue;
      if (position_ >= text_.size())
        return false;
      const char escaped = text_[position_++];
      if (escaped == '"' || escaped == '\\' || escaped == '/' ||
          escaped == 'b' || escaped == 'f' || escaped == 'n' ||
          escaped == 'r' || escaped == 't') {
        continue;
      }
      if (escaped != 'u' || position_ + 4 > text_.size())
        return false;
      for (size_t index = 0; index < 4; index++) {
        const char digit = text_[position_ + index];
        if (!((digit >= '0' && digit <= '9') ||
              (digit >= 'a' && digit <= 'f') ||
              (digit >= 'A' && digit <= 'F'))) {
          return false;
        }
      }
      position_ += 4;
    }
    return false;
  }

  bool parseUnsigned(uint64_t &value) {
    skipWhitespace();
    if (position_ >= text_.size() || text_[position_] < '0' ||
        text_[position_] > '9') {
      return false;
    }
    const size_t start = position_;
    value = 0;
    while (position_ < text_.size() && text_[position_] >= '0' &&
           text_[position_] <= '9') {
      const uint64_t digit = static_cast<uint64_t>(text_[position_] - '0');
      if (value > (UINT64_MAX - digit) / 10)
        return false;
      value = value * 10 + digit;
      position_++;
    }
    return !(position_ - start > 1 && text_[start] == '0');
  }

  bool parseFiles(MapStreamFileTable &files) {
    skipWhitespace();
    if (!consume('['))
      return false;
    skipWhitespace();
    if (consume(']'))
      return true;
    while (true) {
      MapStreamFileDescriptor file;
      std::string path;
      std::string sha256;
      bool havePath = false;
      bool haveBytes = false;
      bool haveSha = false;
      if (!consume('{'))
        return false;
      skipWhitespace();
      if (consume('}'))
        return false;
      std::string previousKey;
      while (true) {
        std::string key;
        if (!parseString(key) || (!previousKey.empty() && key <= previousKey) ||
            !consumeAfterWhitespace(':'))
          return false;
        previousKey = key;
        if (key == "path") {
          if (havePath ||
              !parseString(path, &file.pathOffset, &file.pathBytes))
            return false;
          havePath = true;
        } else if (key == "bytes") {
          if (haveBytes || !parseUnsigned(file.bytes))
            return false;
          haveBytes = true;
        } else if (key == "sha256") {
          if (haveSha || !parseString(sha256))
            return false;
          haveSha = true;
        } else if (!skipValue(0)) {
          return false;
        }
        skipWhitespace();
        if (consume('}'))
          break;
        if (!consume(','))
          return false;
        skipWhitespace();
      }
      if (!havePath || !haveBytes || !haveSha)
        return false;
      if (!finishFile(path, sha256, file))
        return false;
      if (files.size() >= expectedFileCount_)
        return false;
      if (!files.pushBack(file))
        return false;
      skipWhitespace();
      if (consume(']'))
        return true;
      if (!consume(','))
        return false;
      skipWhitespace();
    }
  }

  bool parseTarget(MapManifest &manifest) {
    skipWhitespace();
    if (!consume('{'))
      return false;
    bool haveRenderer = false;
    bool haveFormat = false;
    bool haveMinimumFirmware = false;
    skipWhitespace();
    if (consume('}'))
      return false;
    std::string previousKey;
    while (true) {
      std::string key;
      if (!parseString(key) || (!previousKey.empty() && key <= previousKey) ||
          !consumeAfterWhitespace(':'))
        return false;
      previousKey = key;
      if (key == "renderer") {
        if (haveRenderer || !parseString(manifest.renderer))
          return false;
        haveRenderer = true;
      } else if (key == "formatVersion") {
        uint64_t formatVersion = 0;
        if (haveFormat || !parseUnsigned(formatVersion) ||
            formatVersion > UINT32_MAX)
          return false;
        manifest.formatVersion = static_cast<uint32_t>(formatVersion);
        haveFormat = true;
      } else if (key == "minFirmwareVersion") {
        if (haveMinimumFirmware ||
            !parseString(manifest.minimumFirmwareVersion))
          return false;
        haveMinimumFirmware = true;
      } else if (!skipValue(0)) {
        return false;
      }
      skipWhitespace();
      if (consume('}'))
        return haveRenderer && haveFormat && haveMinimumFirmware;
      if (!consume(','))
        return false;
      skipWhitespace();
    }
  }

  bool skipValue(size_t depth) {
    if (depth > 32)
      return false;
    skipWhitespace();
    if (position_ >= text_.size())
      return false;
    if (text_[position_] == '"') {
      return skipString();
    }
    if (text_[position_] == '{') {
      position_++;
      skipWhitespace();
      if (consume('}'))
        return true;
      std::string previousKey;
      while (true) {
        std::string key;
        if (!parseString(key) || (!previousKey.empty() && key <= previousKey) ||
            !consumeAfterWhitespace(':') ||
            !skipValue(depth + 1))
          return false;
        previousKey = key;
        skipWhitespace();
        if (consume('}'))
          return true;
        if (!consume(','))
          return false;
        skipWhitespace();
      }
    }
    if (text_[position_] == '[') {
      position_++;
      skipWhitespace();
      if (consume(']'))
        return true;
      while (true) {
        if (!skipValue(depth + 1))
          return false;
        skipWhitespace();
        if (consume(']'))
          return true;
        if (!consume(','))
          return false;
        skipWhitespace();
      }
    }
    for (const char *literal : {"true", "false", "null"}) {
      const size_t length = std::strlen(literal);
      if (text_.compare(position_, length, literal) == 0) {
        position_ += length;
        return true;
      }
    }
    size_t start = position_;
    if (text_[position_] == '-')
      position_++;
    const size_t integerStart = position_;
    bool digit = false;
    while (position_ < text_.size() && text_[position_] >= '0' &&
           text_[position_] <= '9') {
      digit = true;
      position_++;
    }
    if (position_ - integerStart > 1 && text_[integerStart] == '0')
      return false;
    if (position_ < text_.size() && text_[position_] == '.') {
      position_++;
      bool fraction = false;
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9') {
        fraction = true;
        position_++;
      }
      if (!fraction)
        return false;
    }
    if (position_ < text_.size() &&
        (text_[position_] == 'e' || text_[position_] == 'E')) {
      position_++;
      if (position_ < text_.size() &&
          (text_[position_] == '+' || text_[position_] == '-'))
        position_++;
      bool exponent = false;
      while (position_ < text_.size() && text_[position_] >= '0' &&
             text_[position_] <= '9') {
        exponent = true;
        position_++;
      }
      if (!exponent)
        return false;
    }
    return digit && position_ > start;
  }

  bool finishFile(const std::string &path, const std::string &sha256,
                  MapStreamFileDescriptor &file);
};

bool safeIdentifier(const std::string &value, size_t maximumBytes) {
  if (value.empty() || value.size() > maximumBytes || value == "." ||
      value == "..")
    return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '.' ||
           character == '_' || character == '-';
  });
}

bool safePathComponent(std::string_view value) {
  if (value.empty() || value.size() > MAP_STREAM_MAX_PATH_COMPONENT_BYTES ||
      value == "." || value == "..")
    return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '+' ||
           character == '.' || character == '_' || character == '-';
  });
}

bool safeMapPath(std::string_view path, const std::string &mapId,
                 size_t &tileOffset, size_t &tileBytes,
                 size_t &filenameOffset, size_t &filenameBytes) {
  if (path.empty() || path.size() > MAP_STREAM_MAX_RELATIVE_PATH_BYTES ||
      path.front() == '/' || path.find('\\') != std::string::npos ||
      path.find("//") != std::string::npos)
    return false;
  const size_t firstSlash = path.find('/');
  const size_t secondSlash = path.find('/', firstSlash + 1);
  const size_t thirdSlash = path.find('/', secondSlash + 1);
  if (firstSlash == std::string::npos || secondSlash == std::string::npos ||
      thirdSlash == std::string::npos ||
      path.find('/', thirdSlash + 1) != std::string::npos) {
    return false;
  }
  const std::string_view prefix(path.data(), firstSlash);
  const std::string_view pathMapId(path.data() + firstSlash + 1,
                                   secondSlash - firstSlash - 1);
  const std::string_view tile(path.data() + secondSlash + 1,
                              thirdSlash - secondSlash - 1);
  const std::string_view filename(path.data() + thirdSlash + 1,
                                  path.size() - thirdSlash - 1);
  if (prefix != "VECTMAP" || pathMapId != mapId ||
      !safePathComponent(pathMapId) || !safePathComponent(tile) ||
      !safePathComponent(filename)) {
    return false;
  }
  if (filename.size() < 5 ||
      !(filename.substr(filename.size() - 4) == ".fmb" ||
        filename.substr(filename.size() - 4) == ".fmp")) {
    return false;
  }
  tileOffset = secondSlash + 1;
  tileBytes = tile.size();
  filenameOffset = thirdSlash + 1;
  filenameBytes = filename.size();
  return true;
}

bool lowercaseSha256(const std::string &value) {
  return value.size() == 64 &&
         std::all_of(value.begin(), value.end(), [](char character) {
           return (character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f');
         });
}

bool decodeLowercaseSha256(const std::string &value,
                           std::array<uint8_t, 32> &digest) {
  if (!lowercaseSha256(value))
    return false;
  auto nibble = [](char character) -> uint8_t {
    return character <= '9' ? static_cast<uint8_t>(character - '0')
                            : static_cast<uint8_t>(character - 'a' + 10);
  };
  for (size_t index = 0; index < digest.size(); index++)
    digest[index] = static_cast<uint8_t>((nibble(value[index * 2]) << 4) |
                                         nibble(value[index * 2 + 1]));
  return true;
}

bool validUtf8(std::string_view value) {
  const auto *bytes = reinterpret_cast<const uint8_t *>(value.data());
  size_t position = 0;
  while (position < value.size()) {
    const uint8_t first = bytes[position++];
    if (first <= 0x7f)
      continue;
    uint32_t codePoint = 0;
    size_t continuationCount = 0;
    uint32_t minimum = 0;
    if (first >= 0xc2 && first <= 0xdf) {
      codePoint = first & 0x1f;
      continuationCount = 1;
      minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      codePoint = first & 0x0f;
      continuationCount = 2;
      minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      codePoint = first & 0x07;
      continuationCount = 3;
      minimum = 0x10000;
    } else {
      return false;
    }
    if (position + continuationCount > value.size())
      return false;
    for (size_t index = 0; index < continuationCount; index++) {
      const uint8_t continuation = bytes[position++];
      if ((continuation & 0xc0) != 0x80)
        return false;
      codePoint = (codePoint << 6) | (continuation & 0x3f);
    }
    if (codePoint < minimum || codePoint > 0x10ffff ||
        (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
      return false;
    }
  }
  return true;
}

bool parseFirmwareVersion(const std::string &value,
                          std::array<uint32_t, 3> &parts) {
  size_t position = 0;
  for (size_t partIndex = 0; partIndex < parts.size(); partIndex++) {
    const size_t start = position;
    uint64_t part = 0;
    while (position < value.size() && value[position] >= '0' &&
           value[position] <= '9') {
      part = part * 10 + static_cast<uint64_t>(value[position] - '0');
      if (part > UINT32_MAX)
        return false;
      position++;
    }
    if (position == start ||
        (position - start > 1 && value[start] == '0'))
      return false;
    parts[partIndex] = static_cast<uint32_t>(part);
    if (partIndex + 1 < parts.size()) {
      if (position >= value.size() || value[position] != '.')
        return false;
      position++;
    }
  }
  return position == value.size();
}

} // namespace

MapStreamFileTable::~MapStreamFileTable() {
  clear();
  freeStreamMemory(data_);
}

MapStreamFileTable::MapStreamFileTable(MapStreamFileTable &&other) noexcept
    : data_(other.data_), size_(other.size_), capacity_(other.capacity_) {
  other.data_ = nullptr;
  other.size_ = 0;
  other.capacity_ = 0;
}

MapStreamFileTable &
MapStreamFileTable::operator=(MapStreamFileTable &&other) noexcept {
  if (this == &other)
    return *this;
  clear();
  freeStreamMemory(data_);
  data_ = other.data_;
  size_ = other.size_;
  capacity_ = other.capacity_;
  other.data_ = nullptr;
  other.size_ = 0;
  other.capacity_ = 0;
  return *this;
}

bool MapStreamFileTable::allocate(size_t capacity) {
  clear();
  freeStreamMemory(data_);
  data_ = nullptr;
  size_ = 0;
  capacity_ = 0;
  if (capacity == 0 ||
      capacity > std::numeric_limits<size_t>::max() /
                     sizeof(MapStreamFileDescriptor)) {
    return false;
  }
  data_ = static_cast<MapStreamFileDescriptor *>(
      allocateStreamMemory(capacity * sizeof(MapStreamFileDescriptor)));
  if (data_ == nullptr)
    return false;
  capacity_ = capacity;
  return true;
}

bool MapStreamFileTable::pushBack(const MapStreamFileDescriptor &file) {
  if (size_ >= capacity_ || data_ == nullptr)
    return false;
  new (data_ + size_) MapStreamFileDescriptor(file);
  size_++;
  return true;
}

void MapStreamFileTable::clear() {
  while (size_ > 0) {
    size_--;
    data_[size_].~MapStreamFileDescriptor();
  }
}

size_t MapStreamFileTable::size() const { return size_; }

size_t MapStreamFileTable::capacity() const { return capacity_; }

MapStreamFileDescriptor &MapStreamFileTable::operator[](size_t index) {
  return data_[index];
}

const MapStreamFileDescriptor &
MapStreamFileTable::operator[](size_t index) const {
  return data_[index];
}

bool ManifestJsonReader::finishFile(const std::string &path,
                                    const std::string &sha256,
                                    MapStreamFileDescriptor &file) {
  const size_t firstSlash = path.find('/');
  const size_t secondSlash =
      firstSlash == std::string::npos ? std::string::npos
                                      : path.find('/', firstSlash + 1);
  const size_t thirdSlash =
      secondSlash == std::string::npos ? std::string::npos
                                       : path.find('/', secondSlash + 1);
  if (firstSlash == std::string::npos || secondSlash == std::string::npos ||
      thirdSlash == std::string::npos)
    return false;
  const size_t tileOffset = secondSlash + 1;
  const size_t tileBytes = thirdSlash - secondSlash - 1;
  const size_t filenameOffset = thirdSlash + 1;
  const size_t filenameBytes = path.size() - thirdSlash - 1;
  if (tileBytes > UINT16_MAX || filenameBytes > UINT16_MAX ||
      file.pathOffset > UINT32_MAX - filenameOffset ||
      !decodeLowercaseSha256(sha256, file.sha256)) {
    return false;
  }
  file.tileOffset = file.pathOffset + static_cast<uint32_t>(tileOffset);
  file.tileBytes = static_cast<uint16_t>(tileBytes);
  file.filenameOffset =
      file.pathOffset + static_cast<uint32_t>(filenameOffset);
  file.filenameBytes = static_cast<uint16_t>(filenameBytes);
  return true;
}

const char *mapStreamParserErrorCode(MapStreamParserError error) {
  switch (error) {
  case MapStreamParserError::None:
    return "ok";
  case MapStreamParserError::InvalidInput:
    return "stream_input_invalid";
  case MapStreamParserError::HeaderInvalid:
    return "stream_header_invalid";
  case MapStreamParserError::ContentLengthMismatch:
    return "stream_content_length";
  case MapStreamParserError::ManifestInvalid:
    return "stream_manifest_invalid";
  case MapStreamParserError::FirmwareIncompatible:
    return "stream_firmware_incompatible";
  case MapStreamParserError::EnvelopeInvalid:
    return "stream_envelope_invalid";
  case MapStreamParserError::UnknownSigningKey:
    return "stream_signing_key_unknown";
  case MapStreamParserError::SignatureInvalid:
    return "stream_signature_invalid";
  case MapStreamParserError::ResourceUnavailable:
    return "stream_resource_unavailable";
  case MapStreamParserError::HashUnavailable:
    return "stream_hash_unavailable";
  case MapStreamParserError::FileHashMismatch:
    return "stream_file_hash";
  case MapStreamParserError::ConsumerRejected:
    return "stream_consumer_rejected";
  case MapStreamParserError::Truncated:
    return "stream_truncated";
  case MapStreamParserError::TrailingData:
    return "stream_trailing_data";
  }
  return "stream_unknown_error";
}

bool parseMapStreamManifest(std::string_view manifestText,
                            const MapStreamHeader &header,
                            ParsedMapStreamManifest &parsed) {
  parsed.metadata = MapManifest();
  if (parsed.files.capacity() != header.fileCount &&
      !parsed.files.allocate(header.fileCount)) {
    return false;
  }
  parsed.files.clear();
  parsed.payloadBytes = 0;
  if (manifestText.empty() ||
      manifestText.size() > MAP_STREAM_MAX_MANIFEST_BYTES ||
      !validUtf8(manifestText) ||
      !ManifestJsonReader(manifestText, header.fileCount).parse(parsed) ||
      !safeIdentifier(parsed.metadata.mapId, MAP_STREAM_MAX_MAP_ID_BYTES) ||
      parsed.files.size() == 0 || parsed.files.size() != header.fileCount ||
      parsed.files.size() > MAP_STREAM_MAX_FILE_COUNT ||
      // Parsing validates the declared minimum version. Compatibility is
      // checked only after the exact manifest bytes have been authenticated.
      !mapStreamFirmwareCompatible(parsed.metadata.minimumFirmwareVersion,
                                   parsed.metadata.minimumFirmwareVersion)) {
    return false;
  }
  uint64_t payloadBytes = 0;
  std::string_view previousPath;
  for (size_t fileIndex = 0; fileIndex < parsed.files.size(); fileIndex++) {
    MapStreamFileDescriptor &file = parsed.files[fileIndex];
    if (file.pathOffset > manifestText.size() ||
        file.pathBytes > manifestText.size() - file.pathOffset) {
      return false;
    }
    const std::string_view path(manifestText.data() + file.pathOffset,
                                file.pathBytes);
    size_t tileOffset = 0;
    size_t tileBytes = 0;
    size_t filenameOffset = 0;
    size_t filenameBytes = 0;
    if (!safeMapPath(path, parsed.metadata.mapId, tileOffset, tileBytes,
                     filenameOffset, filenameBytes) ||
        file.bytes == 0 || file.bytes > MAP_STREAM_MAX_PAYLOAD_BYTES ||
        (!previousPath.empty() && path <= previousPath) ||
        payloadBytes > MAP_STREAM_MAX_PAYLOAD_BYTES - file.bytes) {
      return false;
    }
    file.tileOffset = file.pathOffset + static_cast<uint32_t>(tileOffset);
    file.tileBytes = static_cast<uint16_t>(tileBytes);
    file.filenameOffset =
        file.pathOffset + static_cast<uint32_t>(filenameOffset);
    file.filenameBytes = static_cast<uint16_t>(filenameBytes);
    payloadBytes += file.bytes;
    previousPath = path;
  }
  parsed.payloadBytes = payloadBytes;
  return payloadBytes == header.payloadBytes;
}

bool mapStreamFirmwareCompatible(const std::string &currentVersion,
                                 const std::string &minimumVersion) {
  std::array<uint32_t, 3> current = {};
  std::array<uint32_t, 3> minimum = {};
  return parseFirmwareVersion(currentVersion, current) &&
         parseFirmwareVersion(minimumVersion, minimum) && current >= minimum;
}

bool mapStreamFileView(const ParsedMapStreamManifest &parsed,
                       std::string_view canonicalManifest, size_t index,
                       MapStreamFileView &view) {
  view = MapStreamFileView();
  if (index >= parsed.files.size())
    return false;
  const MapStreamFileDescriptor &file = parsed.files[index];
  if (file.pathOffset > canonicalManifest.size() ||
      file.pathBytes > canonicalManifest.size() - file.pathOffset ||
      file.tileOffset > canonicalManifest.size() ||
      file.tileBytes > canonicalManifest.size() - file.tileOffset ||
      file.filenameOffset > canonicalManifest.size() ||
      file.filenameBytes > canonicalManifest.size() - file.filenameOffset) {
    return false;
  }
  view.path = canonicalManifest.substr(file.pathOffset, file.pathBytes);
  view.tileDirectory =
      canonicalManifest.substr(file.tileOffset, file.tileBytes);
  view.filename =
      canonicalManifest.substr(file.filenameOffset, file.filenameBytes);
  view.bytes = file.bytes;
  view.sha256 = &file.sha256;
  return true;
}

MapStreamIncrementalParser::MapStreamIncrementalParser(
    const MapStreamTrustStore &trustStore, MapStreamSha256 &fileHasher,
    MapStreamConsumer &consumer, MapStreamParserOptions options)
    : trustStore_(trustStore), fileHasher_(fileHasher), consumer_(consumer),
      options_(std::move(options)) {}

MapStreamIncrementalParser::~MapStreamIncrementalParser() {
  freeStreamMemory(manifestBuffer_);
}

bool MapStreamIncrementalParser::feed(const uint8_t *data, size_t size) {
  if (stage_ == Stage::Failed)
    return false;
  if (data == nullptr && size != 0)
    return fail(MapStreamParserError::InvalidInput);
  if (stage_ == Stage::Complete)
    return size == 0 || fail(MapStreamParserError::TrailingData);
  while (size > 0 && stage_ != Stage::Failed) {
    bool accepted = false;
    switch (stage_) {
    case Stage::Header:
      accepted = acceptHeaderByte(data, size);
      break;
    case Stage::Manifest:
      accepted = acceptManifestBytes(data, size);
      break;
    case Stage::Envelope:
      accepted = acceptEnvelopeBytes(data, size);
      break;
    case Stage::Payload:
      accepted = acceptPayloadBytes(data, size);
      break;
    case Stage::AwaitingFinish:
      return fail(MapStreamParserError::TrailingData);
    case Stage::Complete:
      return fail(MapStreamParserError::TrailingData);
    case Stage::Failed:
      return false;
    }
    if (!accepted)
      return false;
  }
  return stage_ != Stage::Failed;
}

bool MapStreamIncrementalParser::finish() {
  if (stage_ == Stage::AwaitingFinish) {
    if (!consumer_.onComplete(verified_))
      return fail(MapStreamParserError::ConsumerRejected);
    stage_ = Stage::Complete;
    return true;
  }
  if (stage_ == Stage::Complete)
    return true;
  if (stage_ == Stage::Failed)
    return false;
  return fail(MapStreamParserError::Truncated);
}

bool MapStreamIncrementalParser::complete() const {
  return stage_ == Stage::Complete;
}

bool MapStreamIncrementalParser::failed() const {
  return stage_ == Stage::Failed;
}

MapStreamParserError MapStreamIncrementalParser::error() const {
  return error_;
}

const char *MapStreamIncrementalParser::errorCode() const {
  return mapStreamParserErrorCode(error_);
}

uint64_t MapStreamIncrementalParser::receivedBytes() const {
  return receivedBytes_;
}

const VerifiedMapStreamManifest *
MapStreamIncrementalParser::verifiedManifest() const {
  return verifiedReady_ ? &verified_ : nullptr;
}

bool MapStreamIncrementalParser::fail(MapStreamParserError error) {
  if (stage_ != Stage::Failed) {
    stage_ = Stage::Failed;
    error_ = error;
    consumer_.onAbort(error);
  }
  return false;
}

bool MapStreamIncrementalParser::acceptHeaderByte(const uint8_t *&data,
                                                  size_t &size) {
  const size_t take = std::min(size, headerBuffer_.size() - headerBuffered_);
  std::copy(data, data + take, headerBuffer_.begin() + headerBuffered_);
  data += take;
  size -= take;
  headerBuffered_ += take;
  receivedBytes_ += take;
  if (headerBuffered_ != headerBuffer_.size())
    return true;
  if (parseMapStreamHeader(headerBuffer_.data(), headerBuffer_.size(), header_) !=
      MapStreamFormatError::Ok) {
    return fail(MapStreamParserError::HeaderInvalid);
  }
  if (options_.expectedContentBytes != std::numeric_limits<uint64_t>::max() &&
      options_.expectedContentBytes != header_.totalBytes()) {
    return fail(MapStreamParserError::ContentLengthMismatch);
  }
  if (header_.manifestBytes > options_.maximumWorkingBytes)
    return fail(MapStreamParserError::ResourceUnavailable);
  manifestBuffer_ = static_cast<uint8_t *>(
      allocateStreamMemory(static_cast<size_t>(header_.manifestBytes)));
  if (manifestBuffer_ == nullptr)
    return fail(MapStreamParserError::ResourceUnavailable);
  stage_ = Stage::Manifest;
  return true;
}

bool MapStreamIncrementalParser::acceptManifestBytes(const uint8_t *&data,
                                                     size_t &size) {
  const size_t remaining = header_.manifestBytes - manifestBuffered_;
  const size_t take = std::min(size, remaining);
  std::memcpy(manifestBuffer_ + manifestBuffered_, data, take);
  data += take;
  size -= take;
  manifestBuffered_ += take;
  receivedBytes_ += take;
  if (manifestBuffered_ == header_.manifestBytes)
    stage_ = Stage::Envelope;
  return true;
}

bool MapStreamIncrementalParser::acceptEnvelopeBytes(const uint8_t *&data,
                                                     size_t &size) {
  const size_t remaining =
      header_.signatureEnvelopeBytes - envelopeBuffered_;
  const size_t take = std::min(size, remaining);
  std::copy(data, data + take, envelopeBuffer_.begin() + envelopeBuffered_);
  data += take;
  size -= take;
  envelopeBuffered_ += take;
  receivedBytes_ += take;
  if (envelopeBuffered_ == header_.signatureEnvelopeBytes)
    return preparePayload();
  return true;
}

bool MapStreamIncrementalParser::preparePayload() {
  if (parseMapStreamSignatureEnvelope(envelopeBuffer_.data(),
                                      envelopeBuffered_, envelope_) !=
      MapStreamFormatError::Ok) {
    return fail(MapStreamParserError::EnvelopeInvalid);
  }
  if (trustStore_.find(envelope_.keyId) == nullptr)
    return fail(MapStreamParserError::UnknownSigningKey);
  if (!trustStore_.verify(
          manifestBuffer_, manifestBuffered_, envelope_)) {
    return fail(MapStreamParserError::SignatureInvalid);
  }
  const size_t fileTableBytes = static_cast<size_t>(header_.fileCount) *
                                sizeof(MapStreamFileDescriptor);
  if (fileTableBytes > options_.maximumWorkingBytes - manifestBuffered_ ||
      !verified_.manifest.files.allocate(header_.fileCount)) {
    return fail(MapStreamParserError::ResourceUnavailable);
  }
  // Authentication precedes all JSON expansion. An arbitrary Wi-Fi client can
  // make us retain at most the bounded raw manifest, but cannot drive the file
  // table allocations or semantic parser.
  const std::string_view manifestText(
      reinterpret_cast<const char *>(manifestBuffer_), manifestBuffered_);
  if (!parseMapStreamManifest(manifestText, header_, verified_.manifest))
    return fail(MapStreamParserError::ManifestInvalid);
  if (!mapStreamFirmwareCompatible(options_.currentFirmwareVersion,
                 verified_.manifest.metadata.minimumFirmwareVersion))
    return fail(MapStreamParserError::FirmwareIncompatible);
  verified_.manifestReceipt = mapStreamManifestReceipt(
      manifestBuffer_, manifestBuffered_);
  verified_.signedManifestReceipt = mapStreamSignedManifestReceipt(
      manifestBuffer_, manifestBuffered_, envelopeBuffer_.data(),
      envelopeBuffered_);
  verified_.signatureKeyId = envelope_.keyId;
  verified_.payloadBytes = header_.payloadBytes;
  verifiedReady_ = true;
  if (!consumer_.onManifest(verified_, manifestText))
    return fail(MapStreamParserError::ConsumerRejected);
  stage_ = Stage::Payload;
  return beginCurrentFile();
}

bool MapStreamIncrementalParser::beginCurrentFile() {
  if (fileIndex_ >= verified_.manifest.files.size())
    return fail(MapStreamParserError::ManifestInvalid);
  fileBytes_ = 0;
  const MapStreamFileView file = currentFileView();
  const MapStreamFileAction action = consumer_.onFileBegin(file, fileIndex_);
  if (action == MapStreamFileAction::Reject)
    return fail(MapStreamParserError::ConsumerRejected);
  verifyCurrentFile_ = action == MapStreamFileAction::VerifyAndConsume;
  if (verifyCurrentFile_ && !fileHasher_.reset())
    return fail(MapStreamParserError::HashUnavailable);
  fileStarted_ = true;
  return true;
}

bool MapStreamIncrementalParser::acceptPayloadBytes(const uint8_t *&data,
                                                    size_t &size) {
  if (!fileStarted_ || fileIndex_ >= verified_.manifest.files.size())
    return fail(MapStreamParserError::ManifestInvalid);
  const MapStreamFileDescriptor &descriptor =
      verified_.manifest.files[fileIndex_];
  const MapStreamFileView file = currentFileView();
  const uint64_t remaining = descriptor.bytes - fileBytes_;
  const size_t take = static_cast<size_t>(
      std::min<uint64_t>(remaining, static_cast<uint64_t>(size)));
  if (take == 0)
    return fail(MapStreamParserError::ManifestInvalid);
  if (verifyCurrentFile_ && !fileHasher_.update(data, take))
    return fail(MapStreamParserError::HashUnavailable);
  if (!consumer_.onFileData(file, data, take))
    return fail(MapStreamParserError::ConsumerRejected);
  data += take;
  size -= take;
  fileBytes_ += take;
  receivedBytes_ += take;
  if (fileBytes_ == descriptor.bytes)
    return finishCurrentFile();
  return true;
}

bool MapStreamIncrementalParser::finishCurrentFile() {
  std::array<uint8_t, 32> digest = {};
  const MapStreamFileDescriptor &descriptor =
      verified_.manifest.files[fileIndex_];
  const MapStreamFileView file = currentFileView();
  if (verifyCurrentFile_) {
    if (!fileHasher_.finish(digest))
      return fail(MapStreamParserError::HashUnavailable);
    if (digest != descriptor.sha256)
      return fail(MapStreamParserError::FileHashMismatch);
  }
  if (!consumer_.onFileEnd(file, fileIndex_))
    return fail(MapStreamParserError::ConsumerRejected);
  fileStarted_ = false;
  fileIndex_++;
  if (fileIndex_ < verified_.manifest.files.size())
    return beginCurrentFile();
  if (receivedBytes_ != header_.totalBytes())
    return fail(MapStreamParserError::Truncated);
  // Completion is deliberately deferred until finish(). That lets the parser
  // reject trailing bytes before a consumer atomically commits staged files.
  stage_ = Stage::AwaitingFinish;
  return true;
}

MapStreamFileView MapStreamIncrementalParser::currentFileView() const {
  MapStreamFileView view;
  const std::string_view manifest(
      reinterpret_cast<const char *>(manifestBuffer_), manifestBuffered_);
  mapStreamFileView(verified_.manifest, manifest, fileIndex_, view);
  return view;
}

} // namespace map_transfer
