#pragma once

#include "mapSurface.hpp"
#include <array>
#include <cstdint>

namespace map_nearby_icons {
constexpr int kSize = 16;
// White category silhouettes with a one-pixel black halo. The alpha plane
// leaves the map (and the black picker) visible around the actual symbol.
constexpr std::array<std::array<uint16_t, kSize>, 5> kGlyphs{{
    {{0,0,0x03C0,0x0660,0x0420,0x1FF8,0x1008,0x1008,
      0x1008,0x1008,0x1008,0x1008,0x1FF8,0,0,0}}, // shopping bag
    {{0,0,0x2A18,0x2A38,0x2A38,0x3E38,0x1C38,0x0838,
      0x0818,0x0818,0x0818,0x0818,0x0818,0,0,0}}, // fork and knife
    {{0,0,0x1830,0x1830,0,0x3C78,0x3C78,0x3C78,
      0x1830,0x1858,0x1858,0x1858,0x1858,0,0,0}}, // people / toilets
    {{0,0,0x1F80,0x10C0,0x16A0,0x16B0,0x10B8,0x1F88,
      0x10A8,0x10A8,0x1098,0x1080,0x3FC0,0,0,0}}, // fuel pump and hose
    {{0,0,0,0x0180,0x00C0,0x0F60,0x0460,0x0640,
      0x1BEC,0x24D2,0x2A92,0x2492,0x186C,0,0,0}}, // bicycle
}};

inline bool ink(uint8_t category, int x, int y) {
  return category >= 1 && category <= kGlyphs.size() &&
      x >= 0 && x < kSize && y >= 0 && y < kSize &&
      (kGlyphs[category - 1U][y] & (uint16_t{1} << (kSize - 1 - x)));
}

inline void draw(map_surface::Rgb565A8Surface surface, uint8_t category) {
  if (!surface.valid() || surface.width != kSize || surface.height != kSize)
    return;
  surface.clear();
  for (int y = 0; y < kSize; ++y) {
    for (int x = 0; x < kSize; ++x) {
      const bool foreground = ink(category, x, y);
      bool halo = false;
      for (int dy = -1; dy <= 1 && !halo; ++dy)
        for (int dx = -1; dx <= 1; ++dx)
          halo = halo || ink(category, x + dx, y + dy);
      surface.pixels[y * surface.colorStridePixels + x] = foreground ? 0xFFFF : 0;
      surface.alpha[y * surface.alphaStrideBytes + x] = halo ? 255 : 0;
    }
  }
}
} // namespace map_nearby_icons
