#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <limits>
#include <string>

// FPI1 contains block summaries only. Installation must additionally verify
// every entry against section 6 of the same signed map and require complete
// coverage of its nonempty POI blocks; this codec alone is not that proof.
namespace map_poi_index {
constexpr size_t kHeaderBytes = 16;
constexpr size_t kEntryBytes = 32;
constexpr uint32_t kMaximumEntries = 16384;
constexpr size_t kMaximumBytes = kHeaderBytes + kEntryBytes * kMaximumEntries;
constexpr uint32_t kMaximumRecordsPerBlock = 16384;
constexpr uint32_t kMaximumBlockBytes = 2U * 1024U * 1024U;

struct Entry {
  int32_t blockX = 0;
  int32_t blockY = 0;
  uint32_t categoryMask = 0;
  std::array<uint16_t, 5> categoryCounts{};
  uint32_t sectionOffset = 0;
  uint32_t sectionBytes = 0;

  uint32_t recordCount() const {
    uint32_t count = 0;
    for (uint16_t value : categoryCounts) count += value;
    return count;
  }
};

inline std::string relativeBlockPath(int32_t x, int32_t y) {
  const auto floor16 = [](int32_t value) -> int64_t {
    const int64_t widened = value;
    return widened >= 0 ? widened / 16 : -((-widened + 15) / 16);
  };
  const int64_t folderX = floor16(x);
  const int64_t folderY = floor16(y);
  const int64_t localX = int64_t(x) - folderX * 16;
  const int64_t localY = int64_t(y) - folderY * 16;
  char folder[32] = {};
  const int size = std::snprintf(folder, sizeof(folder), "%+04lld%+04lld",
                                 static_cast<long long>(folderX),
                                 static_cast<long long>(folderY));
  if (size <= 0 || static_cast<size_t>(size) >= sizeof(folder)) return {};
  return std::string(folder) + "/" + std::to_string(localX) + "_" +
         std::to_string(localY) + ".fmb";
}

inline std::string blockPath(const std::string &mapId, int32_t x, int32_t y) {
  const std::string relative = relativeBlockPath(x, y);
  return relative.empty() ? std::string() :
         "VECTMAP/" + mapId + "/" + relative;
}

inline bool blockFromPath(const std::string &mapId, const std::string &path,
                          int32_t &x, int32_t &y) {
  const std::string prefix = "VECTMAP/" + mapId + "/";
  if (path.compare(0, prefix.size(), prefix) != 0) return false;
  const size_t slash = path.find('/', prefix.size());
  if (slash == std::string::npos) return false;
  const std::string folder = path.substr(prefix.size(), slash - prefix.size());
  const size_t secondSign = folder.find_first_of("+-", 1);
  const size_t underscore = path.find('_', slash + 1);
  if (secondSign == std::string::npos || underscore == std::string::npos ||
      path.compare(path.size() >= 4 ? path.size() - 4 : 0, 4, ".fmb") != 0)
    return false;
  const auto number = [](const std::string &value, int64_t &result) {
    if (value.empty()) return false;
    errno = 0;
    char *end = nullptr;
    const long long parsed = std::strtoll(value.c_str(), &end, 10);
    if (errno != 0 || end != value.c_str() + value.size()) return false;
    result = parsed;
    return true;
  };
  int64_t folderX = 0, folderY = 0, localX = 0, localY = 0;
  if (!number(folder.substr(0, secondSign), folderX) ||
      !number(folder.substr(secondSign), folderY) ||
      !number(path.substr(slash + 1, underscore - slash - 1), localX) ||
      !number(path.substr(underscore + 1, path.size() - underscore - 5), localY) ||
      localX < 0 || localX >= 16 || localY < 0 || localY >= 16 ||
      folderX < -134217729 || folderX > 134217728 ||
      folderY < -134217729 || folderY > 134217728)
    return false;
  const int64_t widenedX = folderX * 16 + localX;
  const int64_t widenedY = folderY * 16 + localY;
  if (widenedX < INT32_MIN || widenedX > INT32_MAX ||
      widenedY < INT32_MIN || widenedY > INT32_MAX)
    return false;
  x = static_cast<int32_t>(widenedX);
  y = static_cast<int32_t>(widenedY);
  return path == blockPath(mapId, x, y);
}

inline uint16_t u16(const uint8_t *data) {
  return uint16_t(data[0]) | (uint16_t(data[1]) << 8U);
}
inline uint32_t u32(const uint8_t *data) {
  return uint32_t(u16(data)) | (uint32_t(u16(data + 2)) << 16U);
}
inline int32_t s32(const uint8_t *data) {
  const uint32_t value = u32(data);
  return static_cast<int32_t>(value <= INT32_MAX ? int64_t(value)
                                                : int64_t(value) - 0x100000000LL);
}

inline bool decodeEntry(const uint8_t *data, size_t size, Entry &output) {
  if (data == nullptr || size != kEntryBytes || u16(data + 30) != 0) return false;
  Entry entry;
  entry.blockX = s32(data);
  entry.blockY = s32(data + 4);
  entry.categoryMask = u32(data + 8);
  uint32_t mask = 0;
  for (size_t category = 0; category < 5; ++category) {
    entry.categoryCounts[category] = u16(data + 12 + category * 2);
    if (entry.categoryCounts[category] != 0) mask |= 1U << category;
  }
  const uint32_t count = entry.recordCount();
  entry.sectionOffset = u32(data + 22);
  entry.sectionBytes = u32(data + 26);
  if (count == 0 || count > kMaximumRecordsPerBlock || entry.categoryMask != mask ||
      entry.sectionOffset < 112 || entry.sectionBytes != 8 + count * 8 ||
      entry.sectionOffset > kMaximumBlockBytes - entry.sectionBytes) return false;
  output = entry;
  return true;
}

class StreamValidator {
public:
  // The callback may validate correspondence against a bounded block inventory.
  // It must not publish entries as trusted until finish() and the signed file
  // hash have both passed. Returning false permanently rejects this stream.
  using Visitor = bool (*)(const Entry &, void *);
  explicit StreamValidator(Visitor visitor = nullptr, void *context = nullptr)
      : visitor_(visitor), context_(context) {}

  bool feed(const uint8_t *data, size_t size) {
    if (failed_ || (data == nullptr && size != 0) || size > kMaximumBytes - bytes_) {
      failed_ = true;
      return false;
    }
    for (size_t index = 0; index < size; ++index) {
      const uint8_t byte = data[index];
      if (bytes_ < kHeaderBytes) {
        header_[bytes_] = byte;
        ++bytes_;
        if (bytes_ == kHeaderBytes && !header()) return reject();
        continue;
      }
      if (entries_ >= declaredEntries_) return reject();
      ++bytes_;
      crc_ ^= byte;
      for (unsigned bit = 0; bit < 8; ++bit)
        crc_ = (crc_ >> 1U) ^ (0xedb88320U & (0U - (crc_ & 1U)));
      record_[recordBytes_++] = byte;
      if (recordBytes_ == kEntryBytes) {
        Entry entry;
        if (!decodeEntry(record_.data(), record_.size(), entry) ||
            (entries_ != 0 && (entry.blockX < previousX_ ||
              (entry.blockX == previousX_ && entry.blockY <= previousY_))) ||
            (visitor_ != nullptr && !visitor_(entry, context_))) return reject();
        previousX_ = entry.blockX;
        previousY_ = entry.blockY;
        ++entries_;
        recordBytes_ = 0;
      }
    }
    return true;
  }

  bool finish() const {
    return !failed_ && bytes_ >= kHeaderBytes && recordBytes_ == 0 &&
           entries_ == declaredEntries_ && (crc_ ^ 0xffffffffU) == declaredCrc_;
  }
  bool failed() const { return failed_; }
  uint32_t entryCount() const { return declaredEntries_; }

private:
  bool reject() { failed_ = true; return false; }
  bool header() {
    if (header_[0] != 'F' || header_[1] != 'P' || header_[2] != 'I' ||
        header_[3] != '1' || u16(header_.data() + 4) != kEntryBytes ||
        u16(header_.data() + 6) != 0) return false;
    declaredEntries_ = u32(header_.data() + 8);
    declaredCrc_ = u32(header_.data() + 12);
    return declaredEntries_ <= kMaximumEntries;
  }
  Visitor visitor_ = nullptr;
  void *context_ = nullptr;
  std::array<uint8_t, kHeaderBytes> header_{};
  std::array<uint8_t, kEntryBytes> record_{};
  size_t bytes_ = 0;
  size_t recordBytes_ = 0;
  uint32_t entries_ = 0;
  uint32_t declaredEntries_ = 0;
  uint32_t declaredCrc_ = 0;
  uint32_t crc_ = 0xffffffffU;
  int32_t previousX_ = 0;
  int32_t previousY_ = 0;
  bool failed_ = false;
};
} // namespace map_poi_index
