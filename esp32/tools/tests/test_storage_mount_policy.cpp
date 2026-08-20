#include "../../lib/storage/storage_mount_policy.hpp"

#include <cassert>
#include <iostream>

int main() {
  using storage_mount_policy::shouldAttemptAutomaticRemovableRetry;
  using storage_mount_policy::shouldRestoreFallbackAfterFailedRetry;

  assert(shouldAttemptAutomaticRemovableRetry(false, false));
  assert(!shouldAttemptAutomaticRemovableRetry(true, false));
  assert(!shouldAttemptAutomaticRemovableRetry(false, true));
  assert(!shouldAttemptAutomaticRemovableRetry(true, true));

  assert(!shouldRestoreFallbackAfterFailedRetry(false, false));
  assert(shouldRestoreFallbackAfterFailedRetry(true, false));
  assert(shouldRestoreFallbackAfterFailedRetry(false, true));
  assert(shouldRestoreFallbackAfterFailedRetry(true, true));

  std::cout << "storage mount policy tests passed\n";
  return 0;
}
