#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace map_label_rasterizer {

constexpr int32_t kQ15One = 32768;
constexpr int64_t kCoordinateDenominator = 64LL * kQ15One;

struct TransformQ15 {
  int32_t centerX = 0;
  int32_t centerY = 0;
  int32_t cosine = kQ15One;
  int32_t sine = 0;
};

struct Point {
  int32_t x = 0;
  int32_t y = 0;
};

using InterruptCheck = bool (*)();

inline int32_t roundedDivide(int64_t numerator, int64_t denominator) {
  const int64_t half = denominator / 2;
  return static_cast<int32_t>(numerator >= 0
                                  ? (numerator + half) / denominator
                                  : (numerator - half) / denominator);
}

inline Point project26_6(int32_t localX26_6, int32_t localY26_6,
                         const TransformQ15 &transform) {
  const int64_t rotatedX =
      static_cast<int64_t>(localX26_6) * transform.cosine -
      static_cast<int64_t>(localY26_6) * transform.sine;
  const int64_t rotatedY =
      static_cast<int64_t>(localX26_6) * transform.sine +
      static_cast<int64_t>(localY26_6) * transform.cosine;
  return {transform.centerX + roundedDivide(rotatedX, kCoordinateDenominator),
          transform.centerY + roundedDivide(rotatedY, kCoordinateDenominator)};
}

inline uint16_t blendRgb565(uint16_t destination, uint16_t source,
                            uint8_t alpha) {
  alpha = std::min<uint8_t>(alpha, 15);
  if (alpha == 0)
    return destination;
  if (alpha == 15)
    return source;
  const uint8_t inverse = static_cast<uint8_t>(15U - alpha);
  const uint32_t red = (((destination >> 11U) & 0x1fU) * inverse +
                        ((source >> 11U) & 0x1fU) * alpha + 7U) /
                       15U;
  const uint32_t green = (((destination >> 5U) & 0x3fU) * inverse +
                          ((source >> 5U) & 0x3fU) * alpha + 7U) /
                         15U;
  const uint32_t blue = ((destination & 0x1fU) * inverse +
                         (source & 0x1fU) * alpha + 7U) /
                        15U;
  return static_cast<uint16_t>((red << 11U) | (green << 5U) | blue);
}

// Composite a 4-bit source sample into a straight-alpha RGB565A8 surface.
// LVGL stores the packed RGB565 plane first and the A8 plane second. Keeping
// this operation here makes the label renderer usable both on the opaque map
// framebuffer and on a viewport-sized transparent foreground surface.
inline void blendRgb565A8(uint16_t &destinationColor,
                          uint8_t &destinationAlpha, uint16_t sourceColor,
                          uint8_t sourceAlpha4) {
  sourceAlpha4 = std::min<uint8_t>(sourceAlpha4, 15);
  if (sourceAlpha4 == 0)
    return;

  const uint32_t sourceAlpha = sourceAlpha4 * 17U;
  const uint32_t inverseSourceAlpha = 255U - sourceAlpha;
  const uint32_t outputAlphaNumerator =
      sourceAlpha * 255U + destinationAlpha * inverseSourceAlpha;
  if (outputAlphaNumerator == 0)
    return;

  const auto composite = [&](uint32_t destination, uint32_t source) {
    const uint32_t numerator =
        source * sourceAlpha * 255U +
        destination * destinationAlpha * inverseSourceAlpha;
    return (numerator + outputAlphaNumerator / 2U) / outputAlphaNumerator;
  };
  const uint32_t red = composite((destinationColor >> 11U) & 0x1fU,
                                 (sourceColor >> 11U) & 0x1fU);
  const uint32_t green = composite((destinationColor >> 5U) & 0x3fU,
                                   (sourceColor >> 5U) & 0x3fU);
  const uint32_t blue = composite(destinationColor & 0x1fU,
                                  sourceColor & 0x1fU);
  destinationColor =
      static_cast<uint16_t>((red << 11U) | (green << 5U) | blue);
  destinationAlpha = static_cast<uint8_t>(
      std::min<uint32_t>(255U, (outputAlphaNumerator + 127U) / 255U));
}

// Draw one halo/fill pass from pre-rasterized 4-bit masks. Coordinates and
// glyph origins use HarfBuzz-compatible 26.6 units while rotation is Q15, so
// the per-pixel loop performs no floating-point work.
inline bool drawGlyphPass(
    uint16_t *pixels, int32_t screenWidth, int32_t screenHeight,
    uint32_t stride, const uint8_t *fill, const uint8_t *distance,
    uint16_t glyphWidth, uint16_t glyphHeight, int32_t glyphX26_6,
    int32_t glyphY26_6, const TransformQ15 &transform, uint8_t pass,
    uint16_t fillColor, uint16_t haloColor,
    InterruptCheck shouldInterrupt = nullptr) {
  if (pixels == nullptr || fill == nullptr || distance == nullptr ||
      screenWidth <= 0 || screenHeight <= 0 ||
      stride < static_cast<uint32_t>(screenWidth) ||
      pass > 1)
    return true;
  for (uint16_t y = 0; y < glyphHeight; ++y) {
    if ((y & 0x07U) == 0 && shouldInterrupt != nullptr && shouldInterrupt())
      return false;
    for (uint16_t x = 0; x < glyphWidth; ++x) {
      const size_t bitmapIndex = static_cast<size_t>(y) * glyphWidth + x;
      uint8_t alpha = 0;
      uint16_t color = fillColor;
      if (pass == 0 && fill[bitmapIndex] == 0 &&
          distance[bitmapIndex] != 0) {
        alpha = std::min<uint8_t>(
            15, static_cast<uint8_t>(distance[bitmapIndex] * 5U));
        color = haloColor;
      } else if (pass == 1) {
        alpha = fill[bitmapIndex];
      }
      if (alpha == 0)
        continue;
      const Point target =
          project26_6(glyphX26_6 + static_cast<int32_t>(x) * 64,
                      glyphY26_6 + static_cast<int32_t>(y) * 64, transform);
      if (target.x >= 0 && target.x < screenWidth && target.y >= 0 &&
          target.y < screenHeight) {
        uint16_t &destination = pixels[target.y * stride + target.x];
        destination = blendRgb565(destination, color, alpha);
      }
    }
  }
  return true;
}

// RGB565A8 counterpart to drawGlyphPass. Labels rendered into this surface
// remain independent from the rolling base-map raster, so collision layout is
// performed once in real viewport coordinates instead of once per scratch
// cell. The route and native position marker can then remain visually above
// the street names.
inline bool drawGlyphPassRgb565A8(
    uint16_t *pixels, uint8_t *alphaPixels, int32_t screenWidth,
    int32_t screenHeight, uint32_t colorStride, uint32_t alphaStride,
    const uint8_t *fill, const uint8_t *distance, uint16_t glyphWidth,
    uint16_t glyphHeight, int32_t glyphX26_6, int32_t glyphY26_6,
    const TransformQ15 &transform, uint8_t pass, uint16_t fillColor,
    uint16_t haloColor, InterruptCheck shouldInterrupt = nullptr) {
  if (pixels == nullptr || alphaPixels == nullptr || fill == nullptr ||
      distance == nullptr || screenWidth <= 0 || screenHeight <= 0 ||
      colorStride < static_cast<uint32_t>(screenWidth) ||
      alphaStride < static_cast<uint32_t>(screenWidth) || pass > 1)
    return true;
  for (uint16_t y = 0; y < glyphHeight; ++y) {
    if ((y & 0x07U) == 0 && shouldInterrupt != nullptr && shouldInterrupt())
      return false;
    for (uint16_t x = 0; x < glyphWidth; ++x) {
      const size_t bitmapIndex = static_cast<size_t>(y) * glyphWidth + x;
      uint8_t alpha = 0;
      uint16_t color = fillColor;
      if (pass == 0 && fill[bitmapIndex] == 0 &&
          distance[bitmapIndex] != 0) {
        alpha = std::min<uint8_t>(
            15, static_cast<uint8_t>(distance[bitmapIndex] * 5U));
        color = haloColor;
      } else if (pass == 1) {
        alpha = fill[bitmapIndex];
      }
      if (alpha == 0)
        continue;
      const Point target =
          project26_6(glyphX26_6 + static_cast<int32_t>(x) * 64,
                      glyphY26_6 + static_cast<int32_t>(y) * 64, transform);
      if (target.x >= 0 && target.x < screenWidth && target.y >= 0 &&
          target.y < screenHeight) {
        uint16_t &destinationColor =
            pixels[target.y * colorStride + target.x];
        uint8_t &destinationAlpha =
            alphaPixels[target.y * alphaStride + target.x];
        blendRgb565A8(destinationColor, destinationAlpha, color, alpha);
      }
    }
  }
  return true;
}

inline size_t makeColorOpaque(uint16_t *pixels, uint8_t *alphaPixels,
                              int32_t screenWidth, int32_t screenHeight,
                              uint32_t colorStride, uint32_t alphaStride,
                              uint16_t color) {
  if (pixels == nullptr || alphaPixels == nullptr || screenWidth <= 0 ||
      screenHeight <= 0 ||
      colorStride < static_cast<uint32_t>(screenWidth) ||
      alphaStride < static_cast<uint32_t>(screenWidth))
    return 0;
  size_t changed = 0;
  for (int32_t y = 0; y < screenHeight; ++y) {
    for (int32_t x = 0; x < screenWidth; ++x) {
      const size_t colorIndex = static_cast<size_t>(y) * colorStride + x;
      const size_t alphaIndex = static_cast<size_t>(y) * alphaStride + x;
      if (pixels[colorIndex] == color) {
        alphaPixels[alphaIndex] = 255;
        changed++;
      }
    }
  }
  return changed;
}

} // namespace map_label_rasterizer
