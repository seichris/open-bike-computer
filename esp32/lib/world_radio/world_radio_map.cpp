#include "world_radio_map.hpp"

// Never put the preview texture in production images, even if link-time
// dead-code elimination changes. Keep it in flash, not writable data memory.
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
namespace {
#include "world_radio_map_data.inc"
} // namespace
#endif

bool world_radio_map::render(uint16_t *destination, std::size_t capacityPixels,
                             std::size_t stridePixels) {
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
  return decode(kMapPackets, sizeof(kMapPackets), kMapPalette, destination,
                capacityPixels, WIDTH, HEIGHT, stridePixels);
#else
  (void)destination;
  (void)capacityPixels;
  (void)stridePixels;
  return false;
#endif
}
