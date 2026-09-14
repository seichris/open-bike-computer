#pragma once
#include <cstdint>
#include <cstring>

namespace world_radio_raster {
// Compose only the visible 2x viewport. LVGL can then copy a native-size image
// instead of repeatedly transforming wrapped 2048x1024 images in software.
inline void render(const uint16_t *world, int worldWidth, int worldStride,
                   uint16_t *output, int width, int height, int stride,
                   int cameraX, int cameraY) {
  int previousY = -1;
  for (int y = 0; y < height; ++y) {
    const int sourceY = (y - cameraY) / 2;
    auto *row = output + y * stride;
    if (sourceY == previousY) {
      std::memcpy(row, row - stride, width * sizeof(uint16_t));
    } else {
      const auto *source = world + sourceY * worldStride;
      int sourceX = (-cameraX / 2) % worldWidth;
      for (int x = 0; x < width; ++x) {
        row[x] = source[sourceX];
        if ((x - cameraX) % 2 == 1 && ++sourceX == worldWidth) sourceX = 0;
      }
    }
    previousY = sourceY;
  }
}
} // namespace world_radio_raster
