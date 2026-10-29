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

// The FFat geometry this device owns, kept in NVS by the firmware.
enum class InternalGeometryRecord : uint8_t { Absent, Matches, Differs };

enum class InternalMountPlan : uint8_t {
  FormatErased,       // nothing to lose: own the geometry, then format
  MountExisting,      // ours: mount, and reformat after a failed mount
  RefuseRelocated,    // FFat moved since this device owned it
  RefuseUnrecognized, // no ownership evidence: leave every byte untouched
};

// FFat may hold another layout's data: a dual-3-MiB device whose partition
// table was replaced without the signed migration's erase still has the old
// filesystem shifted underneath, and vendor images leave their own data. Even
// a mount without format rewrites wear-levelling metadata it does not
// recognise. So decide from raw pre-mount facts, and mount only with evidence
// that the volume belongs to this exact geometry: the NVS record, or (for a
// volume formatted before the record existed) wear-levelling state that is
// valid at this geometry. Owned volumes keep the previous recovery: a failed
// mount is reformatted. A fully erased partition is formatted after the
// geometry is recorded, so a torn first format is recognised on the next boot.
constexpr InternalMountPlan
internalMountPlan(bool partitionErased, InternalGeometryRecord record,
                  bool wearLevellingStateValid) {
  if (partitionErased)
    return InternalMountPlan::FormatErased;
  if (record == InternalGeometryRecord::Differs)
    return InternalMountPlan::RefuseRelocated;
  if (record == InternalGeometryRecord::Absent && !wearLevellingStateValid)
    return InternalMountPlan::RefuseUnrecognized;
  return InternalMountPlan::MountExisting;
}

} // namespace storage_mount_policy
