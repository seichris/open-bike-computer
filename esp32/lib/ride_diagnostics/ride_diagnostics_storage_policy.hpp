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

} // namespace ride_diagnostics::storage_policy
