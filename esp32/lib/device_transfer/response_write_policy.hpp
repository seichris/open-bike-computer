#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace device_transfer::response_write_policy {

struct Budget {
  size_t chunkBytes;
  uint32_t delayMs;
};

// AES/TCP writes need contiguous DMA-capable memory even when PSRAM is ample.
// Back off before the largest block reaches the sub-kilobyte values observed
// at fatal TLS writes during sustained diagnostic responses.
inline Budget budget(size_t remaining, size_t maximumChunkBytes,
                     uint32_t baseDelayMs, uint32_t dmaLargestBytes) {
  if (dmaLargestBytes < 2048)
    return {0, 4};
  if (dmaLargestBytes < 4096)
    return {std::min({remaining, maximumChunkBytes, size_t{512}}),
            std::max(baseDelayMs, uint32_t{5})};
  return {std::min(remaining, maximumChunkBytes), baseDelayMs};
}

} // namespace device_transfer::response_write_policy
