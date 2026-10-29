#pragma once

#include <cstdint>

namespace storage_mount_policy {

// Only removable SD holds map data: blocks, terrain, map fonts, Nearby/POI
// indexes and the catalog/activation journals. The FFat fallback keeps bounded
// diagnostics and other device files, never maps; an unmounted boot has none.
constexpr bool removableHoldsMaps(bool removableMounted, bool fallbackMounted) {
  return removableMounted && !fallbackMounted;
}

// setup() pins the boot's backend before any file owner starts. Afterwards a
// request may only validate it: unmounting, remounting or replacing /sdcard
// would invalidate open renderer, font, recorder and transfer files. A card
// that fails, is removed or is inserted later takes effect after a restart.
constexpr bool mayChangeMount(bool backendPinned) { return !backendPinned; }

// A recorder write fault re-probes the pinned backend. With nothing mounted
// there is nothing to probe, and nothing may be mounted at runtime.
constexpr bool shouldReprobeDiagnostics(bool recorderHealthy,
                                        bool backendMounted) {
  return !recorderHealthy && backendMounted;
}

// The FFat geometry this device last mounted, kept in NVS by the firmware.
enum class InternalGeometryRecord : uint8_t { Absent, Matches, Differs };

enum class InternalMountPlan : uint8_t {
  FormatErased,    // nothing to lose: initialise the erased partition
  MountExisting,   // mount without formatting
  RefuseRelocated, // FFat moved since its last mount: bytes are not ours
};

enum class InternalMountFailure : uint8_t {
  ReformatOwned, // our filesystem at this geometry: keep corruption recovery
  Refuse,        // unknown provenance: leave the bytes, run without FFat
};

// FFat may hold another layout's data: a dual-3-MiB device whose partition
// table was replaced without the signed migration's erase still has the old
// filesystem shifted underneath, and vendor images leave their own data. A
// mount must never silently format such bytes. Formatting is allowed only for
// a fully erased partition, or for this device's own filesystem at the same
// geometry. Decide from raw pre-mount facts: a wear-levelling mount rewrites
// its metadata when it does not recognise the contents.
constexpr InternalMountPlan internalMountPlan(bool partitionErased,
                                              InternalGeometryRecord record) {
  if (partitionErased)
    return InternalMountPlan::FormatErased;
  return record == InternalGeometryRecord::Differs
             ? InternalMountPlan::RefuseRelocated
             : InternalMountPlan::MountExisting;
}

constexpr InternalMountFailure
internalMountFailure(InternalGeometryRecord record) {
  return record == InternalGeometryRecord::Matches
             ? InternalMountFailure::ReformatOwned
             : InternalMountFailure::Refuse;
}

} // namespace storage_mount_policy
