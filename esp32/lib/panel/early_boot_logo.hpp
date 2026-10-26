#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace early_boot_logo {

// The existing LVGL wordmark is RGB565 followed by an A8 plane. Render it
// without starting LVGL, allocating a framebuffer, or accessing storage.
struct Image {
  const uint8_t *data;
  size_t dataSize;
  uint16_t width;
  uint16_t height;
  uint16_t stride;
};

inline uint16_t onBlack(uint16_t color, uint8_t alpha) {
  const uint16_t red = (((color >> 11) & 31) * alpha + 127) / 255;
  const uint16_t green = (((color >> 5) & 63) * alpha + 127) / 255;
  const uint16_t blue = ((color & 31) * alpha + 127) / 255;
  return (red << 11) | (green << 5) | blue;
}

// The sink synchronously writes one native-panel row. A 256-byte stack buffer
// avoids consuming the internal heap needed by later Wi-Fi/BLE initialization.
template <typename WriteRow>
bool drawCentered(const Image &image, uint16_t panelWidth,
                  uint16_t panelHeight, bool clockwise, WriteRow writeRow) {
  constexpr size_t kMaxRowPixels = 128;
  const uint16_t width = clockwise ? image.height : image.width;
  const uint16_t height = clockwise ? image.width : image.height;
  const size_t colorBytes = size_t{image.stride} * image.height;
  const size_t alphaStride = image.stride / 2;
  if (image.data == nullptr || width == 0 || height == 0 ||
      width > kMaxRowPixels || width > panelWidth || height > panelHeight ||
      image.stride < size_t{image.width} * 2 || image.stride % 2 != 0 ||
      image.dataSize < colorBytes + alphaStride * image.height) {
    return false;
  }

  // Center in logical coordinates, then use the same clockwise transform as
  // the normal LVGL flush (including the odd-height wordmark's one-pixel gap).
  const uint16_t x = clockwise
                         ? (panelWidth - width + 1) / 2
                         : (panelWidth - width) / 2;
  const uint16_t y = (panelHeight - height) / 2;
  std::array<uint16_t, kMaxRowPixels> row;
  for (uint16_t dy = 0; dy < height; ++dy) {
    for (uint16_t dx = 0; dx < width; ++dx) {
      const uint16_t sx = clockwise ? dy : dx;
      const uint16_t sy = clockwise ? image.height - 1 - dx : dy;
      const size_t offset = size_t{sy} * image.stride + size_t{sx} * 2;
      const uint16_t color = uint16_t{image.data[offset]} |
                             (uint16_t{image.data[offset + 1]} << 8);
      const uint8_t alpha = image.data[colorBytes + sy * alphaStride + sx];
      row[dx] = onBlack(color, alpha);
    }
    writeRow(x, y + dy, row.data(), width);
  }
  return true;
}

} // namespace early_boot_logo
