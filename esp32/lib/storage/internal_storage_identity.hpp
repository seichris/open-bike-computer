#pragma once

#include "storage_mount_policy.hpp"

#include <cstdint>

namespace internal_storage {

// Raw facts about the FFat partition, read before any mount attempt.
struct Assessment {
  bool partitionFound = false;
  bool erased = false;
  // A wear-levelling state copy that WL_Flash::init accepts at this geometry.
  bool wearLevellingValid = false;
  storage_mount_policy::InternalGeometryRecord record =
      storage_mount_policy::InternalGeometryRecord::Absent;
  uint32_t address = 0;
  uint32_t size = 0;
};

// Reads the partition and the NVS geometry record. Flash and NVS access must
// run on an internal-RAM stack; elsewhere it reports no partition.
Assessment assess(const char *label);

// Records that this device owns the geometry: before formatting an erased
// partition, and after mounting a volume adopted by its wear-levelling state.
bool recordGeometry(const Assessment &assessment);

} // namespace internal_storage
