#pragma once

#include <cstdint>

namespace device_ownership {

// Authenticated BLE frames are small, but the ESP32-S3 hardware AES path
// allocates DMA descriptors and may copy an input/output block into DMA-capable
// internal memory. Rejecting a frame before the allocator reaches exhaustion
// is safer than entering ESP-IDF's allocation-error logging path.
constexpr uint32_t kMinimumCryptoDmaFreeBytes = 4096;
constexpr uint32_t kMinimumCryptoDmaLargestBlockBytes = 1024;

struct CryptoResourceSnapshot {
  uint32_t dmaFree = 0;
  uint32_t dmaLargest = 0;
};

struct CryptoResourceDiagnostics {
  CryptoResourceSnapshot current{};
  uint32_t minimumDmaFree = 0;
  uint32_t minimumDmaLargest = 0;
  uint32_t headroomRejections = 0;
  uint32_t operationFailures = 0;
};

constexpr bool hasCryptoDmaHeadroom(const CryptoResourceSnapshot &snapshot) {
  return snapshot.dmaFree >= kMinimumCryptoDmaFreeBytes &&
         snapshot.dmaLargest >= kMinimumCryptoDmaLargestBlockBytes;
}

CryptoResourceDiagnostics cryptoResourceDiagnostics();

#ifdef DEVICE_OWNERSHIP_HOST_TEST
void setCryptoResourceSnapshotForTesting(CryptoResourceSnapshot snapshot);
void clearCryptoResourceSnapshotForTesting();
void resetCryptoResourceDiagnosticsForTesting();
#endif

} // namespace device_ownership
