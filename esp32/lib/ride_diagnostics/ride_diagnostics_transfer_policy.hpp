#pragma once

#include <cstdint>

namespace ride_diagnostics::transfer_policy {

enum class StoragePreparation : uint8_t {
  ReadyRemovable = 0,
  ReadyInternalFallback,
  MountFailed,
  CardMissing,
  WritableProbeFailed,
};

enum class SealPreparation : uint8_t {
  Ready = 0,
  RecorderUnavailable,
  StorageUnavailable,
  SealFailed,
  DrainTimeout,
  FlushFailed,
  CloseFailed,
};

struct Failure {
  const char *code;
  const char *message;
};

constexpr bool storageReady(StoragePreparation result) {
  return result == StoragePreparation::ReadyRemovable ||
         result == StoragePreparation::ReadyInternalFallback;
}

constexpr bool usingInternalFallback(StoragePreparation result) {
  return result == StoragePreparation::ReadyInternalFallback;
}

constexpr Failure storageFailure(StoragePreparation result) {
  switch (result) {
  case StoragePreparation::MountFailed:
    return {"diagnostics_mount_failed",
            "device diagnostics could not mount storage"};
  case StoragePreparation::CardMissing:
    return {"diagnostics_card_missing",
            "device diagnostics could not detect the removable card"};
  case StoragePreparation::WritableProbeFailed:
    return {"diagnostics_writable_probe_failed",
            "diagnostics storage mounted but failed its writable probe"};
  case StoragePreparation::ReadyRemovable:
  case StoragePreparation::ReadyInternalFallback:
    return {"", ""};
  }
  return {"diagnostics_mount_failed",
          "device diagnostics storage preparation failed"};
}

constexpr bool sealReady(SealPreparation result) {
  return result == SealPreparation::Ready;
}

constexpr Failure sealFailure(SealPreparation result) {
  switch (result) {
  case SealPreparation::FlushFailed:
    return {"diagnostics_flush_failed",
            "device diagnostics could not flush the active checkpoint"};
  case SealPreparation::CloseFailed:
    return {"diagnostics_close_failed",
            "device diagnostics could not close the active checkpoint"};
  case SealPreparation::DrainTimeout:
    return {"diagnostics_seal_timeout",
            "device diagnostics timed out while draining the recorder"};
  case SealPreparation::RecorderUnavailable:
  case SealPreparation::StorageUnavailable:
  case SealPreparation::SealFailed:
    return {"diagnostics_seal_failed",
            "device diagnostics could not seal a readable checkpoint"};
  case SealPreparation::Ready:
    return {"", ""};
  }
  return {"diagnostics_seal_failed",
          "device diagnostics could not seal a readable checkpoint"};
}

} // namespace ride_diagnostics::transfer_policy
