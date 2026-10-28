#pragma once

#include <cstdint>

namespace ride_diagnostics::storage_policy {

struct Budget {
  uint64_t retentionBytes;
  uint64_t minimumFreeBytes;
};

// Removable storage keeps the original generous evidence window and reserve.
// Internal FFat is shared with maps and firmware-transfer files, so diagnostics
// gets a deliberately smaller quota and protects 2 MiB for those owners. The
// FFat limits remain valid if a future dual-4-MiB layout reduces it to 7 MiB.
constexpr Budget kRemovableBudget{
    32ULL * 1024ULL * 1024ULL,
    8ULL * 1024ULL * 1024ULL,
};
constexpr Budget kInternalFfatBudget{
    1ULL * 1024ULL * 1024ULL,
    2ULL * 1024ULL * 1024ULL,
};

inline constexpr Budget budgetForBackend(bool internalFfat) {
  return internalFfat ? kInternalFfatBudget : kRemovableBudget;
}

inline constexpr bool hasWriteReserve(uint64_t freeBytes,
                                      uint64_t nextChunkBytes,
                                      Budget budget) {
  if (freeBytes == UINT64_MAX)
    return true;
  if (nextChunkBytes > UINT64_MAX - budget.minimumFreeBytes)
    return false;
  return freeBytes >= budget.minimumFreeBytes + nextChunkBytes;
}

inline constexpr bool constraintsExceeded(uint64_t retainedBytes,
                                          uint64_t freeBytes,
                                          uint64_t nextChunkBytes,
                                          Budget budget) {
  return retainedBytes > budget.retentionBytes ||
         !hasWriteReserve(freeBytes, nextChunkBytes, budget);
}

// Recorder file I/O borrows internal DMA-capable RAM. FatFs keeps its sector
// buffers in PSRAM on these boards, so each SDMMC sector transfer allocates a
// 512-byte bounce (ESP-IDF sdmmc_cmd.c); FFat reads into PSRAM borrow one too.
// Starting that work during a short BLE crypto or Wi-Fi peak only turns the
// peak into I/O errors and an abandoned chunk. The writer waits instead, and
// never takes the headroom that the authenticated-BLE crypto guard requires
// (device_ownership: 4096 bytes free, 1024 largest) plus one bounce.
constexpr uint32_t kSdmmcBounceBytes = 512;
constexpr uint32_t kBackgroundIoMinimumDmaFreeBytes = 4096 + kSdmmcBounceBytes;
constexpr uint32_t kBackgroundIoMinimumDmaLargestBytes = 1024;
// Short enough to drain soon after a peak, long enough that a waiting writer
// samples the heap at most 50 times a second.
constexpr uint32_t kBackgroundIoRetryMs = 20;

struct MemoryHeadroom {
  uint32_t dmaFree = 0;
  uint32_t dmaLargest = 0;
};

inline constexpr bool admitsBackgroundIo(MemoryHeadroom headroom) {
  return headroom.dmaFree >= kBackgroundIoMinimumDmaFreeBytes &&
         headroom.dmaLargest >= kBackgroundIoMinimumDmaLargestBytes;
}

// A recorder write fault re-probes the pinned backend with a create, write,
// fsync and unlink. Repeating that every few seconds while memory or the card
// keeps failing only multiplies uncertain FAT updates. The first probe waits
// one base interval after the fault is seen; each failed probe doubles the
// wait up to the cap, and a fault that clears resets it.
class RecoveryBackoff {
public:
  static constexpr uint32_t kBaseMs = 5000;
  static constexpr uint32_t kMaximumMs = 60000;

  // Arms on the first call after a fault and reports whether a probe is due.
  bool due(uint32_t nowMs) {
    if (!armed_) {
      armed_ = true;
      waitStartedMs_ = nowMs;
      delayMs_ = kBaseMs;
      return false;
    }
    return static_cast<uint32_t>(nowMs - waitStartedMs_) >= delayMs_;
  }

  void probeFailed(uint32_t nowMs) {
    waitStartedMs_ = nowMs;
    delayMs_ = delayMs_ >= kMaximumMs / 2 ? kMaximumMs : delayMs_ * 2;
  }

  void reset() {
    armed_ = false;
    delayMs_ = kBaseMs;
  }

  uint32_t delayMs() const { return delayMs_; }

private:
  bool armed_ = false;
  uint32_t waitStartedMs_ = 0;
  uint32_t delayMs_ = kBaseMs;
};

} // namespace ride_diagnostics::storage_policy
