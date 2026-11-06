#include "../../lib/storage/storage_mount_policy.hpp"

#include <cassert>
#include <iostream>

int main() {
  using storage_mount_policy::mayChangeMount;
  using storage_mount_policy::removableHoldsMaps;
  using storage_mount_policy::shouldReprobeDiagnostics;

  // Maps live only on removable SD. FFat and an unmounted boot hold none.
  static_assert(removableHoldsMaps(true, false));
  static_assert(!removableHoldsMaps(false, true));
  static_assert(!removableHoldsMaps(false, false));
  static_assert(!removableHoldsMaps(true, true));

  // Setup may mount; once the backend is pinned nothing may change it.
  static_assert(mayChangeMount(false));
  static_assert(!mayChangeMount(true));

  // A recorder fault re-probes the mounted backend and never mounts another.
  assert(shouldReprobeDiagnostics(false, true));
  assert(!shouldReprobeDiagnostics(false, false));
  assert(!shouldReprobeDiagnostics(true, true));
  assert(!shouldReprobeDiagnostics(true, false));

  // FFat is formatted only when the raw partition is erased, and mounted only
  // with ownership evidence: the NVS record or valid wear-levelling state.
  using storage_mount_policy::internalMountPlan;
  using storage_mount_policy::InternalGeometryRecord;
  using storage_mount_policy::InternalMountPlan;
  for (const auto record :
       {InternalGeometryRecord::Absent, InternalGeometryRecord::Matches,
        InternalGeometryRecord::Differs})
    for (const bool wearLevelling : {false, true})
      assert(internalMountPlan(true, record, wearLevelling) ==
             InternalMountPlan::FormatErased);
  static_assert(internalMountPlan(false, InternalGeometryRecord::Matches, false) ==
                InternalMountPlan::MountExisting);
  static_assert(internalMountPlan(false, InternalGeometryRecord::Matches, true) ==
                InternalMountPlan::MountExisting);
  static_assert(internalMountPlan(false, InternalGeometryRecord::Absent, true) ==
                InternalMountPlan::MountExisting);
  static_assert(internalMountPlan(false, InternalGeometryRecord::Absent, false) ==
                InternalMountPlan::RefuseUnrecognized);
  static_assert(internalMountPlan(false, InternalGeometryRecord::Differs, true) ==
                InternalMountPlan::RefuseRelocated);
  static_assert(internalMountPlan(false, InternalGeometryRecord::Differs, false) ==
                InternalMountPlan::RefuseRelocated);

  std::cout << "storage mount policy tests passed\n";
  return 0;
}
