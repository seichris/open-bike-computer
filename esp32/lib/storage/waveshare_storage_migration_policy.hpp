#pragma once

namespace waveshare_storage_migration_policy {

enum class Backend {
  Unavailable,
  NativeSdmmc,
  LegacySpiMigration,
};

struct MountResult {
  Backend backend;
  bool nativeAttempted;
  bool legacyAttempted;
};

// The compatibility path is deliberately one-way per boot: native SDMMC is
// always attempted first, and the legacy SPI transport is considered only
// after native mounting has failed. A card power cycle lets the next boot
// select NativeSdmmc without any persisted migration flag.
template <typename MountNative, typename MountLegacy>
MountResult mountNativeFirst(MountNative mountNative,
                             MountLegacy mountLegacy) {
  if (mountNative()) {
    return MountResult{Backend::NativeSdmmc, true, false};
  }
  if (mountLegacy()) {
    return MountResult{Backend::LegacySpiMigration, true, true};
  }
  return MountResult{Backend::Unavailable, true, true};
}

constexpr bool requiresCardPowerCycle(Backend backend) {
  return backend == Backend::LegacySpiMigration;
}

} // namespace waveshare_storage_migration_policy
