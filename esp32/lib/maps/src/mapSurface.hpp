/**
 * @file mapSurface.hpp
 * @brief LVGL-independent raw surfaces used by the map render worker.
 *
 * The renderer owns only these plain buffers.  Binding a completed buffer to an
 * LVGL canvas is deliberately left to the UI task.
 */

#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace map_surface {

struct Rgb565Surface {
  uint16_t *pixels = nullptr;
  int32_t width = 0;
  int32_t height = 0;
  size_t stridePixels = 0;

  constexpr bool valid() const {
    return pixels != nullptr && width > 0 && height > 0 &&
           stridePixels >= static_cast<size_t>(width);
  }

  constexpr size_t byteSize() const {
    return valid() ? stridePixels * static_cast<size_t>(height) *
                         sizeof(uint16_t)
                   : 0U;
  }

  void clear(uint16_t color) const {
    if (!valid())
      return;
    for (int32_t y = 0; y < height; ++y) {
      std::fill_n(pixels + static_cast<size_t>(y) * stridePixels,
                  static_cast<size_t>(width), color);
    }
  }

  constexpr bool contains(int32_t x, int32_t y) const {
    return x >= 0 && y >= 0 && x < width && y < height;
  }

  uint16_t *row(int32_t y) const {
    return valid() && y >= 0 && y < height
               ? pixels + static_cast<size_t>(y) * stridePixels
               : nullptr;
  }
};

struct Rgb565A8Surface {
  uint16_t *pixels = nullptr;
  uint8_t *alpha = nullptr;
  int32_t width = 0;
  int32_t height = 0;
  size_t colorStridePixels = 0;
  size_t alphaStrideBytes = 0;

  constexpr bool valid() const {
    return pixels != nullptr && alpha != nullptr && width > 0 && height > 0 &&
           colorStridePixels >= static_cast<size_t>(width) &&
           alphaStrideBytes >= static_cast<size_t>(width);
  }

  void clearAlpha() const {
    if (!valid())
      return;
    for (int32_t y = 0; y < height; ++y) {
      std::fill_n(alpha + static_cast<size_t>(y) * alphaStrideBytes,
                  static_cast<size_t>(width), uint8_t{0});
    }
  }

  void clear() const {
    if (!valid())
      return;
    for (int32_t y = 0; y < height; ++y) {
      std::fill_n(pixels + static_cast<size_t>(y) * colorStridePixels,
                  static_cast<size_t>(width), uint16_t{0});
    }
    clearAlpha();
  }
};

struct LabelSurface {
  Rgb565Surface color{};
  uint8_t *alpha = nullptr;
  size_t alphaStrideBytes = 0;
  const Rgb565Surface *contrast = nullptr;
  int32_t contrastOffsetX = 0;
  int32_t contrastOffsetY = 0;

  constexpr bool valid() const { return color.valid(); }
  constexpr bool transparent() const {
    return valid() && alpha != nullptr &&
           alphaStrideBytes >= static_cast<size_t>(color.width);
  }
};

} // namespace map_surface
