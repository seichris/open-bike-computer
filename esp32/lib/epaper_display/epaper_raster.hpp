#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace epaper {
constexpr uint16_t width = 800, height = 480;
constexpr uint16_t logicalWidth = 480, logicalHeight = 800;
constexpr size_t stride = width / 8, frameBytes = stride * height;
constexpr size_t rgbBytes = size_t(logicalWidth) * logicalHeight * 2;

struct Point { uint16_t x, y; };
constexpr Point nativePoint(uint16_t x, uint16_t y) {
  return {y, static_cast<uint16_t>(height - 1 - x)};
}
constexpr Point logicalPoint(uint16_t x, uint16_t y) {
  return {static_cast<uint16_t>(height - 1 - y), x};
}

// Exclusive right/bottom; the packed x axis is always byte aligned.
struct Window {
  uint16_t x = 0, y = 0, right = 0, bottom = 0;
  bool empty() const { return x >= right || y >= bottom; }
  size_t rowBytes() const { return (right - x) / 8; }
};

inline Window dirtyWindow(const uint8_t *next, const uint8_t *shown) {
  Window result{width, height, 0, 0};
  for (uint16_t y = 0; y < height; ++y) {
    for (uint16_t byte = 0; byte < stride; ++byte) {
      const size_t offset = size_t(y) * stride + byte;
      if (next[offset] == shown[offset]) continue;
      const uint16_t x = byte * 8;
      if (x < result.x) result.x = x;
      if (y < result.y) result.y = y;
      if (x + 8 > result.right) result.right = x + 8;
      if (y + 1 > result.bottom) result.bottom = y + 1;
    }
  }
  return result;
}

// Deterministic binary threshold: no temporal dithering, especially for QR/code.
inline bool white565(uint16_t pixel) {
  const unsigned r = ((pixel >> 11) & 31) * 255 / 31;
  const unsigned g = ((pixel >> 5) & 63) * 255 / 63;
  const unsigned b = (pixel & 31) * 255 / 31;
  return r * 299 + g * 587 + b * 114 >= 128000;
}

inline void packPortrait(const uint16_t *rgb, uint8_t *output) {
  std::memset(output, 0xFF, frameBytes);
  for (uint16_t y = 0; y < logicalHeight; ++y) {
    for (uint16_t x = 0; x < logicalWidth; ++x) {
      if (white565(rgb[size_t(y) * logicalWidth + x])) continue;
      const Point p = nativePoint(x, y);
      output[size_t(p.y) * stride + p.x / 8] &= ~(0x80u >> (p.x % 8));
    }
  }
}
} // namespace epaper
