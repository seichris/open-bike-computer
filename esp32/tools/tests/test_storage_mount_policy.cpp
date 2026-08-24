#include "../../lib/storage/storage_mount_policy.hpp"

#include <cassert>
#include <iostream>

int main() {
  using storage_mount_policy::diagnosticsMountReady;
  using storage_mount_policy::shouldAttemptAutomaticRemovableRetry;
  using storage_mount_policy::shouldAttemptDiagnosticsRemovableRetry;
  using storage_mount_policy::shouldRestoreFallbackAfterFailedRetry;
  using storage_mount_policy::validEspVfsMountPathLength;

  assert(validEspVfsMountPathLength(sizeof("/diag-sd") - 1));
  assert(!validEspVfsMountPathLength(1));
  assert(!validEspVfsMountPathLength(16));

  assert(diagnosticsMountReady(true, true, true));
  assert(!diagnosticsMountReady(false, true, true));
  assert(!diagnosticsMountReady(true, false, true));
  assert(!diagnosticsMountReady(true, true, false));

  assert(shouldAttemptAutomaticRemovableRetry(false, false));
  assert(!shouldAttemptAutomaticRemovableRetry(true, false));
  assert(!shouldAttemptAutomaticRemovableRetry(false, true));
  assert(!shouldAttemptAutomaticRemovableRetry(true, true));

  assert(shouldAttemptDiagnosticsRemovableRetry(false, false, false));
  assert(shouldAttemptDiagnosticsRemovableRetry(false, false, true));
  assert(!shouldAttemptDiagnosticsRemovableRetry(true, false, false));
  assert(!shouldAttemptDiagnosticsRemovableRetry(false, true, true));

  assert(!shouldRestoreFallbackAfterFailedRetry(false, false));
  assert(shouldRestoreFallbackAfterFailedRetry(true, false));
  assert(shouldRestoreFallbackAfterFailedRetry(false, true));
  assert(shouldRestoreFallbackAfterFailedRetry(true, true));

  std::cout << "storage mount policy tests passed\n";
  return 0;
}
