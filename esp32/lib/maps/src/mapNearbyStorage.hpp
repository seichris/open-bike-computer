#pragma once

#include "mapNearbyQuery.hpp"
#include "mapNearbyCoverage.hpp"
#include "../../utils/src/descriptor_file.hpp"

#include <array>
#include <cerrno>
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

inline Status openFailureStatus(int error) {
  return error == ENOENT ? Status::Unavailable : Status::ReadFailed;
}

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

using File = descriptor_file::File;
inline File open(const std::string &path) {
  return File(path.c_str(), O_RDONLY);
}

inline bool readExact(int file, void *buffer, size_t length) {
  return file >= 0 && descriptor_file::readExact(file, buffer, length);
}

inline bool seek(int file, uint32_t offset) {
  const off_t signedOffset = static_cast<off_t>(offset);
  return file >= 0 && signedOffset >= 0 &&
         static_cast<uint32_t>(signedOffset) == offset &&
         ::lseek(file, signedOffset, SEEK_SET) >= 0;
}

inline bool fileSize(int file, uint32_t &length) {
  if (file < 0) return false;
  const off_t value = ::lseek(file, 0, SEEK_END);
  if (value < 0 || static_cast<uint64_t>(value) > UINT32_MAX ||
      ::lseek(file, 0, SEEK_SET) < 0) return false;
  length = static_cast<uint32_t>(value);
  return true;
}

inline bool readCoverage(const std::string &root,
                         std::vector<map_nearby_coverage::Block> &blocks,
                         Status &status) {
  blocks.clear();
  File file = open(root + "/.manifest.json");
  if (!file) {
    status = openFailureStatus(errno);
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
    status = openFailureStatus(errno);
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

// Only demonstrable on-disk format/checksum failures invalidate runtime health.
// Allocation pressure, cancellation and transient SD reads remain retryable.
inline bool invalidatesHealth(Status status) { return status == Status::Corrupt; }

// A cursor is owned exclusively by the map worker. Each step scans at most
// 128 geometry headers (seeking over coordinates), 256 POI records, or 64
// signed-coverage window blocks. Installed
// blocks were already fully authenticated and validated; a query checks their
// header, section directory, signed FPI1 identity, POI records, counts and CRC
// without reading unrelated geometry payloads again.
class SearchCursor {
 public:
  SearchCursor(std::string root, map_nearby_query::Position rider,
               uint32_t selectedMask, double radiusM,
               const std::vector<map_nearby_coverage::Block> *coverage = nullptr)
      : root_(std::move(root)), rider_(rider), selectedMask_(selectedMask),
        radiusM_(radiusM), coverage_(coverage),
        nearest_(rider, selectedMask, radiusM) {
    while (!root_.empty() && root_.back() == '/') root_.pop_back();
    if (!map_nearby_query::valid(rider) || selectedMask == 0 ||
        (selectedMask & ~0x1fU) != 0 || !std::isfinite(radiusM) ||
        radiusM <= 0 || radiusM > 25000) finish(Status::Corrupt);
    else if (root_.empty()) finish(Status::Unavailable);
  }

  const SearchResult &result() const { return result_; }
  bool done() const { return phase_ == Phase::Done; }

  bool step(Cancel cancel = nullptr, void *context = nullptr) {
    if (done()) return true;
    if (cancelled(cancel, context)) return finish(Status::Cancelled);
    if (phase_ == Phase::Index) {
      file_ = open(root_ + "/assets/nearby-pois.fpi");
      if (!file_) return finish(openFailureStatus(errno));
      if (!fileSize(file_.get(), indexRemaining_)) return finish(Status::ReadFailed);
      // Signed Nearby coverage caps installed maps below the generic FPI1
      // codec limit. Fail closed before allocating/scanning an oversized index.
      if (indexRemaining_ < map_poi_index::kHeaderBytes ||
          indexRemaining_ > map_poi_index::kHeaderBytes +
              map_poi_index::kEntryBytes * map_nearby_coverage::kMaximumBlocks)
        return finish(Status::Corrupt);
      auto append = [](const map_poi_index::Entry &entry, void *destination) {
        static_cast<MapNearbyVector<map_poi_index::Entry> *>(destination)->push_back(entry);
        return true;
      };
      indexValidator_ = std::make_unique<map_poi_index::StreamValidator>(append, &entries_);
      phase_ = Phase::IndexRead;
      return false;
    }
    if (phase_ == Phase::IndexRead) {
      std::array<uint8_t, 4096> buffer{};
      const size_t count = std::min<size_t>(indexRemaining_, buffer.size());
      if (!readExact(file_.get(), buffer.data(), count)) return finish(Status::ReadFailed);
      if (!indexValidator_->feed(buffer.data(), count)) return finish(Status::Corrupt);
      indexRemaining_ -= static_cast<uint32_t>(count);
      if (indexRemaining_ != 0) return false;
      if (!indexValidator_->finish() || entries_.size() != indexValidator_->entryCount())
        return finish(Status::Corrupt);
      file_.reset();
      indexValidator_.reset();
      if (!map_nearby_query::prepareFrontier(entries_.data(), entries_.size(),
              rider_, selectedMask_, radiusM_, frontier_))
        return finish(Status::Corrupt);
      result_.candidateBlocks = static_cast<uint32_t>(frontier_.size());
      phase_ = Phase::Block;
      return false;
    }
    if (phase_ == Phase::Block) {
      if (nextBlock_ == frontier_.size() ||
          nearest_.canFinishBefore(frontier_[nextBlock_].lowerBoundM())) {
        if (coverage_ == nullptr) return finish(Status::Ok);
        // The nearest set stays private until coverage is known too.
        coverageScan_ = map_nearby_coverage::CompletenessScan(
            *coverage_, rider_, radiusM_);
        phase_ = Phase::Coverage;
        return false;
      }
      entry_ = entries_[frontier_[nextBlock_].index];
      const auto relative = map_poi_index::relativeBlockPath(entry_.blockX, entry_.blockY);
      if (relative.empty()) return finish(Status::Corrupt);
      file_ = open(root_ + "/" + relative);
      if (!file_ || !fileSize(file_.get(), size_)) return finish(Status::ReadFailed);
      if (size_ < 112 || size_ > map_poi_index::kMaximumBlockBytes)
        return finish(Status::Corrupt);
      uint8_t header[6]{};
      if (!readExact(file_.get(), header, sizeof(header))) return finish(Status::ReadFailed);
      if (header[0] != 'F' || header[1] != 'M' ||
          header[2] != 'B' || header[3] != 6) return finish(Status::Corrupt);
      position_ = sizeof(header);
      shapes_ = map_poi_index::u16(header + 4);
      phase_ = Phase::Polygons;
      return false;
    }
    if (phase_ == Phase::Coverage) {
      if (!coverageScan_.step(kCoverageBlocksPerStep)) return false;
      return finish(Status::Ok);
    }
    if (phase_ == Phase::Polygons || phase_ == Phase::Lines) {
      const bool polygons = phase_ == Phase::Polygons;
      const size_t headerSize = polygons ? 14U : 15U;
      for (size_t batch = 0; shapes_ != 0 && batch < 128; ++batch, --shapes_) {
        if (cancelled(cancel, context)) return finish(Status::Cancelled);
        if (position_ > size_ || headerSize > size_ - position_)
          return finish(Status::Corrupt);
        uint8_t header[15]{};
        if (!readExact(file_.get(), header, headerSize)) return finish(Status::ReadFailed);
        position_ += static_cast<uint32_t>(headerSize);
        const uint32_t coordinates = map_poi_index::u16(header + headerSize - 2) * 4U;
        if (coordinates > size_ - position_) return finish(Status::Corrupt);
        position_ += coordinates;
        if (!seek(file_.get(), position_)) return finish(Status::ReadFailed);
      }
      if (shapes_ != 0) return false;
      if (polygons) {
        if (size_ - position_ < 2) return finish(Status::Corrupt);
        uint8_t count[2]{};
        if (!readExact(file_.get(), count, 2)) return finish(Status::ReadFailed);
        position_ += 2;
        shapes_ = map_poi_index::u16(count);
        phase_ = Phase::Lines;
      } else phase_ = Phase::Directory;
      return false;
    }
    if (phase_ == Phase::Directory) {
      std::array<uint8_t, 104> directory{};
      if (position_ > size_ || size_ - position_ < directory.size())
        return finish(Status::Corrupt);
      if (!readExact(file_.get(), directory.data(), directory.size()))
        return finish(Status::ReadFailed);
      if (directory[0] != 'E' || directory[1] != 'X' ||
          directory[2] != 'T' || directory[3] != '6' ||
          directory[4] != 6 || directory[5] || directory[6] || directory[7])
        return finish(Status::Corrupt);
      const uint8_t *section = directory.data() + 8 + 5 * 16;
      const uint32_t offset = map_poi_index::u32(section + 4);
      const uint32_t length = map_poi_index::u32(section + 8);
      expectedCrc_ = map_poi_index::u32(section + 12);
      if (section[0] != 6 || section[1] != 1 || section[2] || section[3] ||
          offset != entry_.sectionOffset || length != entry_.sectionBytes ||
          length != 8U + entry_.recordCount() * 8U ||
          offset < position_ + directory.size() || offset > size_ ||
          length > size_ - offset) return finish(Status::Corrupt);
      if (!seek(file_.get(), offset)) return finish(Status::ReadFailed);
      uint8_t header[8]{};
      if (!readExact(file_.get(), header, sizeof(header))) return finish(Status::ReadFailed);
      if (map_poi_index::u16(header) != entry_.recordCount() ||
          map_poi_index::u16(header + 2) != 8 ||
          map_poi_index::u32(header + 4) != entry_.categoryMask)
        return finish(Status::Corrupt);
      crc_ = crcUpdate(0xffffffffU, header, sizeof(header));
      ordinal_ = 0;
      counts_ = {};
      phase_ = Phase::Records;
      return false;
    }
    std::array<uint8_t, map_nearby_query::kMaximumBatchRecords * 8U> records{};
    const size_t count = std::min<size_t>(records.size() / 8U,
                                        entry_.recordCount() - ordinal_);
    if (!readExact(file_.get(), records.data(), count * 8U)) return finish(Status::ReadFailed);
    crc_ = crcUpdate(crc_, records.data(), count * 8U);
    for (size_t index = 0; index < count; ++index) {
      const uint8_t category = records[index * 8U + 4U];
      if (category < 1 || category > 5) return finish(Status::Corrupt);
      ++counts_[category - 1U];
    }
    if (!nearest_.consume(entry_, ordinal_, records.data(), count))
      return finish(Status::Corrupt);
    ordinal_ += static_cast<uint16_t>(count);
    if (ordinal_ == entry_.recordCount()) {
      if (counts_ != entry_.categoryCounts || (crc_ ^ 0xffffffffU) != expectedCrc_)
        return finish(Status::Corrupt);
      file_.reset();
      ++nextBlock_;
      ++result_.searchedBlocks;
      phase_ = Phase::Block;
    }
    return false;
  }

 private:
  enum class Phase {
    Index, IndexRead, Block, Polygons, Lines, Directory, Records, Coverage, Done
  };
  static constexpr uint32_t kCoverageBlocksPerStep = 64;
  bool finish(Status status) {
    result_.status = status;
    if (status == Status::Ok) {
      result_.count = static_cast<uint8_t>(nearest_.size());
      for (size_t index = 0; index < nearest_.size(); ++index)
        result_.places[index] = nearest_[index];
      result_.coverageComplete = coverageScan_.complete();
    } else result_.count = 0; // never expose a partially searched set
    file_.reset();
    indexValidator_.reset();
    phase_ = Phase::Done;
    return true;
  }
  std::string root_;
  map_nearby_query::Position rider_;
  uint32_t selectedMask_;
  double radiusM_;
  const std::vector<map_nearby_coverage::Block> *coverage_;
  map_nearby_query::NearestByCategory nearest_;
  SearchResult result_{};
  MapNearbyVector<map_poi_index::Entry> entries_;
  MapNearbyVector<map_nearby_query::FrontierItem> frontier_;
  File file_{};
  std::unique_ptr<map_poi_index::StreamValidator> indexValidator_;
  map_nearby_coverage::CompletenessScan coverageScan_;
  uint32_t indexRemaining_ = 0;
  map_poi_index::Entry entry_{};
  Phase phase_ = Phase::Index;
  size_t nextBlock_ = 0;
  uint32_t size_ = 0, position_ = 0, expectedCrc_ = 0, crc_ = 0;
  uint16_t shapes_ = 0, ordinal_ = 0;
  std::array<uint16_t, 5> counts_{};
};

inline SearchResult search(const std::string &root,
                           map_nearby_query::Position rider,
                           uint32_t selectedMask, double radiusM,
                           Cancel cancel = nullptr, void *context = nullptr,
                           const std::vector<map_nearby_coverage::Block> *coverage = nullptr) {
  SearchCursor cursor(root, rider, selectedMask, radiusM, coverage);
  while (!cursor.step(cancel, context)) {}
  return cursor.result();
}
} // namespace map_nearby_storage
