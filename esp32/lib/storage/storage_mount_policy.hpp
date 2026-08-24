#pragma once

#include <cstddef>

namespace storage_mount_policy {

constexpr std::size_t kMaximumEspVfsMountPathBytes = 15;

constexpr bool validEspVfsMountPathLength(std::size_t length) {
  return length > 1 && length <= kMaximumEspVfsMountPathBytes;
}

constexpr bool diagnosticsMountReady(bool mounted, bool cardPresent,
                                     bool writableProbeSucceeded) {
  return mounted && cardPresent && writableProbeSucceeded;
}

inline bool shouldAttemptAutomaticRemovableRetry(bool removableMounted,
                                                 bool fallbackMounted) {
  return !removableMounted && !fallbackMounted;
}

inline bool shouldRestoreFallbackAfterFailedRetry(bool callerAllowsFallback,
                                                  bool fallbackWasMounted) {
  return callerAllowsFallback || fallbackWasMounted;
}

inline bool shouldAttemptDiagnosticsRemovableRetry(
    bool removableMounted, bool diagnosticsAlternateMounted,
    bool fallbackMounted) {
  (void)fallbackMounted;
  return !removableMounted && !diagnosticsAlternateMounted;
}

} // namespace storage_mount_policy
