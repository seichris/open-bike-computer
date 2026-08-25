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

inline bool shouldAttemptDiagnosticsRemovableRetry(bool removableMounted,
                                                   bool fallbackMounted) {
  // A recorder that started on FFat must keep one stable root for the whole
  // boot. Switching it to an alternate removable mount can split one boot's
  // chunks across two filesystems while an FFat FILE is still open.
  return !removableMounted && !fallbackMounted;
}

} // namespace storage_mount_policy
