#pragma once

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

} // namespace storage_mount_policy
