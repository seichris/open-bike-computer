#pragma once

#include "mapBlockFormat.hpp"
#include "mapNearbyQuery.hpp"
#include "mapNearbyCoverage.hpp"

#include <array>
#include <cstdio>
#include <memory>
#include <string>

// The caller must be the sole map-storage worker. This code never opens a file
// on the UI task and never publishes a partially searched result set.
namespace map_nearby_storage {
enum class Status : uint8_t {
  Ok, Unavailable, Corrupt, ReadFailed, Cancelled, ResourceRejected
};
using Cancel = bool (*)(void *);

struct SearchResult {
  Status status = Status::Unavailable;
  std::array<map_nearby_query::Result, map_nearby_query::kMaximumResults> places{};
  uint8_t count = 0;
  uint32_t candidateBlocks = 0;
  uint32_t searchedBlocks = 0;
  bool coverageComplete = false;
};

inline bool cancelled(Cancel callback, void *context) {
  return callback != nullptr && callback(context);
}

using File = std::unique_ptr<std::FILE, decltype(&std::fclose)>;
inline File open(const std::string &path) {
  return File(std::fopen(path.c_str(), "rb"), &std::fclose);
}

inline bool readExact(std::FILE *file, void *buffer, size_t length) {
  return file != nullptr && std::fread(buffer, 1, length, file) == length;
}

inline bool seek(std::FILE *file, uint32_t offset) {
  const long signedOffset = static_cast<long>(offset);
  return file != nullptr && signedOffset >= 0 &&
         static_cast<uint32_t>(signedOffset) == offset &&
         std::fseek(file, signedOffset, SEEK_SET) == 0;
}

inline bool fileSize(std::FILE *file, uint32_t &length) {
  if (file == nullptr || std::fseek(file, 0, SEEK_END) != 0) return false;
  const long value = std::ftell(file);
  if (value < 0 || static_cast<unsigned long>(value) > UINT32_MAX ||
      std::fseek(file, 0, SEEK_SET) != 0) return false;
  length = static_cast<uint32_t>(value);
  return true;
}

inline bool readCoverage(const std::string &root,
                         std::vector<map_nearby_coverage::Block> &blocks,
                         Status &status) {
  blocks.clear();
  File file = open(root + "/.manifest.json");
  if (!file) {
    status = Status::Unavailable;
    return false;
  }
  uint32_t size = 0;
  if (!fileSize(file.get(), size)) {
    status = Status::ReadFailed;
    return false;
  }
  if (size == 0 || size > 2U * 1024U * 1024U) {
    status = Status::Corrupt;
    return false;
  }
  std::string manifest(size, '\0');
  if (!readExact(file.get(), &manifest[0], size)) {
    status = Status::ReadFailed;
    return false;
  }
  if (!map_nearby_coverage::decodeManifest(manifest, blocks)) {
    status = Status::Corrupt;
    return false;
  }
  status = Status::Ok;
  return true;
}

inline uint32_t crcUpdate(uint32_t crc, const uint8_t *data, size_t length) {
  for (size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (unsigned bit = 0; bit < 8; ++bit)
      crc = (crc >> 1U) ^ (0xedb88320U & (0U - (crc & 1U)));
  }
  return crc;
}

inline bool readIndex(const std::string &root,
                      MapNearbyVector<map_poi_index::Entry> &entries,
                      Cancel cancel, void *context, Status &status) {
  entries.clear();
  File file = open(root + "/assets/nearby-pois.fpi");
  if (!file) {
    status = Status::Unavailable;
    return false;
  }
  uint32_t size = 0;
  if (!fileSize(file.get(), size)) {
    status = Status::ReadFailed;
    return false;
  }
  if (size < map_poi_index::kHeaderBytes ||
      size > map_poi_index::kMaximumBytes) {
    status = Status::Corrupt;
    return false;
  }
  auto append = [](const map_poi_index::Entry &entry, void *destination) {
    static_cast<MapNearbyVector<map_poi_index::Entry> *>(destination)
        ->push_back(entry);
    return true;
  };
  map_poi_index::StreamValidator validator(append, &entries);
  std::array<uint8_t, 4096> buffer{};
  uint32_t remaining = size;
  while (remaining != 0) {
    if (cancelled(cancel, context)) {
      status = Status::Cancelled;
      return false;
    }
    const size_t count = std::min<size_t>(remaining, buffer.size());
    if (!readExact(file.get(), buffer.data(), count)) {
      status = Status::ReadFailed;
      return false;
    }
    if (!validator.feed(buffer.data(), count)) {
      status = Status::Corrupt;
      return false;
    }
    remaining -= count;
  }
  if (!validator.finish() || entries.size() != validator.entryCount()) {
    status = Status::Corrupt;
    return false;
  }
  status = Status::Ok;
  return true;
}

// A full streaming FMB check detects SD corruption without allocating the
// entire (up to 2 MiB) block or decoding irrelevant roads and polygons.
inline Status validateBlock(std::FILE *file, const std::string &path,
                            uint32_t size, Cancel cancel, void *context) {
  map_block_format::StreamValidator validator(path);
  std::array<uint8_t, 4096> buffer{};
  uint32_t remaining = size;
  while (remaining != 0) {
    if (cancelled(cancel, context)) return Status::Cancelled;
    const size_t count = std::min<size_t>(remaining, buffer.size());
    if (!readExact(file, buffer.data(), count)) return Status::ReadFailed;
    if (!validator.feed(buffer.data(), count)) return Status::Corrupt;
    remaining -= count;
  }
  return validator.finish() ? Status::Ok : Status::Corrupt;
}

inline bool skip(std::FILE *file, uint32_t amount, uint32_t limit,
                 uint32_t &position) {
  const long signedAmount = static_cast<long>(amount);
  if (position > limit || amount > limit - position || signedAmount < 0 ||
      static_cast<uint32_t>(signedAmount) != amount ||
      std::fseek(file, signedAmount, SEEK_CUR) != 0) return false;
  position += amount;
  return true;
}

// Return section 6's directory identity, independently of FPI1. The full
// streaming validation above has already established the geometry records.
inline bool poiSection(std::FILE *file, uint32_t size, uint32_t &offset,
                       uint32_t &length, uint32_t &crc) {
  if (!seek(file, 0) || size < 4) return false;
  uint8_t header[4]{};
  if (!readExact(file, header, sizeof(header)) || header[0] != 'F' ||
      header[1] != 'M' || header[2] != 'B' || header[3] != 6) return false;
  uint32_t position = 4;
  uint8_t small[2]{};
  if (!readExact(file, small, 2)) return false;
  position += 2;
  const uint16_t polygonCount = map_poi_index::u16(small);
  for (uint16_t index = 0; index < polygonCount; ++index) {
    uint8_t fixed[14]{};
    if (!readExact(file, fixed, sizeof(fixed))) return false;
    position += sizeof(fixed);
    if (!skip(file, uint32_t(map_poi_index::u16(fixed + 12)) * 4U,
              size, position)) return false;
  }
  if (!readExact(file, small, 2)) return false;
  position += 2;
  const uint16_t lineCount = map_poi_index::u16(small);
  for (uint16_t index = 0; index < lineCount; ++index) {
    uint8_t fixed[15]{};
    if (!readExact(file, fixed, sizeof(fixed))) return false;
    position += sizeof(fixed);
    if (!skip(file, uint32_t(map_poi_index::u16(fixed + 13)) * 4U,
              size, position)) return false;
  }
  if (position > size || size - position < 104U) return false;
  uint8_t directory[104]{};
  if (!readExact(file, directory, sizeof(directory)) ||
      directory[0] != 'E' || directory[1] != 'X' ||
      directory[2] != 'T' || directory[3] != '6' ||
      directory[4] != 6 || directory[5] != 0 ||
      directory[6] != 0 || directory[7] != 0) return false;
  const uint8_t *entry = directory + 8 + 5 * 16;
  if (entry[0] != 6 || entry[1] != 1 || entry[2] != 0 || entry[3] != 0)
    return false;
  offset = map_poi_index::u32(entry + 4);
  length = map_poi_index::u32(entry + 8);
  crc = map_poi_index::u32(entry + 12);
  return offset >= position + sizeof(directory) && offset <= size &&
         length <= size - offset;
}

inline Status consumeBlock(const std::string &root,
                           const map_poi_index::Entry &entry,
                           map_nearby_query::NearestTen &nearest,
                           Cancel cancel, void *context) {
  const std::string relative = map_poi_index::relativeBlockPath(
      entry.blockX, entry.blockY);
  if (relative.empty()) return Status::Corrupt;
  const std::string path = root + "/" + relative;
  File file = open(path);
  if (!file) return Status::ReadFailed;
  uint32_t size = 0;
  if (!fileSize(file.get(), size)) return Status::ReadFailed;
  if (size < 112 || size > map_poi_index::kMaximumBlockBytes)
    return Status::Corrupt;
  const Status validated = validateBlock(file.get(), path, size, cancel, context);
  if (validated != Status::Ok) return validated;
  uint32_t offset = 0, length = 0, expectedCrc = 0;
  if (!poiSection(file.get(), size, offset, length, expectedCrc) ||
      offset != entry.sectionOffset || length != entry.sectionBytes ||
      length != 8U + entry.recordCount() * 8U || !seek(file.get(), offset))
    return Status::Corrupt;
  uint8_t sectionHeader[8]{};
  if (!readExact(file.get(), sectionHeader, sizeof(sectionHeader)))
    return Status::ReadFailed;
  if (map_poi_index::u16(sectionHeader) != entry.recordCount() ||
      map_poi_index::u16(sectionHeader + 2) != 8 ||
      map_poi_index::u32(sectionHeader + 4) != entry.categoryMask)
    return Status::Corrupt;
  uint32_t crc = crcUpdate(0xffffffffU, sectionHeader, sizeof(sectionHeader));
  std::array<uint8_t, map_nearby_query::kMaximumBatchRecords * 8U> records{};
  std::array<uint16_t, 5> counts{};
  uint16_t ordinal = 0;
  while (ordinal < entry.recordCount()) {
    if (cancelled(cancel, context)) return Status::Cancelled;
    const size_t count = std::min<size_t>(
        records.size() / 8U, entry.recordCount() - ordinal);
    const size_t bytes = count * 8U;
    if (!readExact(file.get(), records.data(), bytes)) return Status::ReadFailed;
    crc = crcUpdate(crc, records.data(), bytes);
    for (size_t index = 0; index < count; ++index) {
      const uint8_t category = records[index * 8U + 4U];
      if (category < 1 || category > 5) return Status::Corrupt;
      ++counts[category - 1U];
    }
    if (!nearest.consume(entry, ordinal, records.data(), count))
      return Status::Corrupt;
    ordinal += static_cast<uint16_t>(count);
  }
  return counts == entry.categoryCounts && (crc ^ 0xffffffffU) == expectedCrc
             ? Status::Ok : Status::Corrupt;
}

inline SearchResult search(const std::string &root,
                           map_nearby_query::Position rider,
                           uint32_t selectedMask, double radiusM,
                           Cancel cancel = nullptr, void *context = nullptr,
                           const std::vector<map_nearby_coverage::Block> *coverage = nullptr) {
  SearchResult result;
  if (!map_nearby_query::valid(rider) || selectedMask == 0 ||
      (selectedMask & ~0x1fU) != 0 || !std::isfinite(radiusM) ||
      radiusM <= 0 || radiusM > 25000) {
    result.status = Status::Corrupt;
    return result;
  }
  std::string normalized = root;
  while (!normalized.empty() && normalized.back() == '/')
    normalized.pop_back();
  if (normalized.empty()) {
    result.status = Status::Unavailable;
    return result;
  }
  MapNearbyVector<map_poi_index::Entry> entries;
  if (!readIndex(normalized, entries, cancel, context, result.status))
    return result;
  MapNearbyVector<map_nearby_query::FrontierItem> frontier;
  if (!map_nearby_query::prepareFrontier(entries.data(), entries.size(), rider,
                                          selectedMask, radiusM, frontier)) {
    result.status = Status::Corrupt;
    return result;
  }
  result.candidateBlocks = static_cast<uint32_t>(frontier.size());
  map_nearby_query::NearestTen nearest(rider, selectedMask, radiusM);
  for (const auto &item : frontier) {
    if (cancelled(cancel, context)) {
      result.status = Status::Cancelled;
      return result;
    }
    if (nearest.canFinishBefore(item.lowerBoundM())) break;
    const Status status = consumeBlock(normalized, entries[item.index],
                                       nearest, cancel, context);
    if (status != Status::Ok) {
      result.status = status;
      return result;
    }
    ++result.searchedBlocks;
  }
  result.count = static_cast<uint8_t>(nearest.size());
  for (size_t index = 0; index < nearest.size(); ++index)
    result.places[index] = nearest[index];
  result.status = Status::Ok;
  result.coverageComplete = coverage != nullptr &&
      map_nearby_coverage::completeWithinRadius(*coverage, rider, radiusM);
  return result;
}
} // namespace map_nearby_storage
