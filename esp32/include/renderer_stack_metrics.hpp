#pragma once

// Shared leaf API: keep outside renderer_diagnostics so PlatformIO deep LDF
// does not import the renderer/BLE/GUI library graph into device_transfer.
#include <atomic>
#include <cstdint>

namespace renderer_diagnostics {
// Self-sampled by the renderer only. Readers never dereference a task handle
// that shutdown may already have deleted. Availability is separate from zero.
inline std::atomic<uint32_t> rendererStackMinimumBytes{UINT32_MAX};
inline void sampleRendererStackBytes(uint32_t bytes) {
  uint32_t previous = rendererStackMinimumBytes.load(std::memory_order_relaxed);
  while ((bytes < previous) &&
         !rendererStackMinimumBytes.compare_exchange_weak(
             previous, bytes, std::memory_order_relaxed)) {}
}
inline bool rendererStackSampleAvailable() {
  return rendererStackMinimumBytes.load(std::memory_order_relaxed) != UINT32_MAX;
}
inline uint32_t rendererStackHighWaterBytes() {
  const uint32_t value = rendererStackMinimumBytes.load(std::memory_order_relaxed);
  return value == UINT32_MAX ? 0 : value;
}
} // namespace renderer_diagnostics
