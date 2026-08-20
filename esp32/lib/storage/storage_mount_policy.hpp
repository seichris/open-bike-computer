#pragma once

namespace storage_mount_policy {

inline bool shouldAttemptAutomaticRemovableRetry(bool removableMounted,
                                                 bool fallbackMounted) {
  return !removableMounted && !fallbackMounted;
}

inline bool shouldRestoreFallbackAfterFailedRetry(bool callerAllowsFallback,
                                                  bool fallbackWasMounted) {
  return callerAllowsFallback || fallbackWasMounted;
}

} // namespace storage_mount_policy
