#pragma once

#include "storage_mount_policy.hpp"

#include <cstdint>

namespace internal_storage {

// Raw facts about the FFat partition, read before any mount attempt.
struct Assessment {
  bool partitionFound = false;
  bool erased = false;
  storage_mount_policy::InternalGeometryRecord record =
      storage_mount_policy::InternalGeometryRecord::Absent;
  uint32_t address = 0;
  uint32_t size = 0;
};

// Reads the partition and the NVS geometry record. Flash and NVS access must
// run on an internal-RAM stack; elsewhere it reports no partition.
Assessment assess(const char *label);

// Records the geometry after a successful mount, so a later mount failure at
// the same place is recognised as this device's own filesystem.
bool recordGeometry(const Assessment &assessment);

} // namespace internal_storage
