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

  std::cout << "storage mount policy tests passed\n";
  return 0;
}
