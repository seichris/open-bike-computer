#include "../../lib/maps/src/mapLabelRasterizer.hpp"

#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

uint32_t fnv1a(const uint16_t *pixels, size_t count) {
  uint32_t value = 2166136261U;
  for (size_t index = 0; index < count; ++index) {
    value ^= pixels[index] & 0xffU;
    value *= 16777619U;
    value ^= pixels[index] >> 8U;
    value *= 16777619U;
  }
  return value;
}

} // namespace

int main() {
  using namespace map_label_rasterizer;
  assert(blendRgb565(0x0000, 0xffff, 0) == 0x0000);
  assert(blendRgb565(0x0000, 0xffff, 15) == 0xffff);
  assert(project26_6(64, -128, {}).x == 1);
  assert(project26_6(64, -128, {}).y == -2);

  std::array<uint16_t, 81> pixels{};
  pixels.fill(0x4208);
  const std::array<uint8_t, 9> fill = {0, 0, 0, 0, 15, 0, 0, 0, 0};
  const std::array<uint8_t, 9> distance = {3, 3, 3, 3, 0, 3, 3, 3, 3};
  const TransformQ15 identity{4, 4, kQ15One, 0};
  assert(drawGlyphPass(pixels.data(), 9, 9, 9, fill.data(), distance.data(),
                       3, 3, -64, -64, identity, 0, 0xffff, 0x0000));
  assert(drawGlyphPass(pixels.data(), 9, 9, 9, fill.data(), distance.data(),
                       3, 3, -64, -64, identity, 1, 0xffff, 0x0000));
  for (int y = 3; y <= 5; ++y) {
    for (int x = 3; x <= 5; ++x)
      assert(pixels[y * 9 + x] == (x == 4 && y == 4 ? 0xffff : 0x0000));
  }
  const uint32_t checksum = fnv1a(pixels.data(), pixels.size());
  std::cout << "label raster checksum=" << checksum << "\n";
  assert(checksum == 2180876963U);

  uint16_t transparentBlendColor = 0;
  uint8_t transparentBlendAlpha = 0;
  blendRgb565A8(transparentBlendColor, transparentBlendAlpha, 0xffff, 8);
  assert(transparentBlendColor == 0xffff);
  assert(transparentBlendAlpha == 136);
  uint16_t opaqueBlendColor = 0x001f;
  const uint16_t expectedOpaqueBlend =
      blendRgb565(opaqueBlendColor, 0xffff, 8);
  uint8_t opaqueBlendAlpha = 255;
  blendRgb565A8(opaqueBlendColor, opaqueBlendAlpha, 0xffff, 8);
  assert(opaqueBlendColor == expectedOpaqueBlend);
  assert(opaqueBlendAlpha == 255);

  std::array<uint16_t, 81> overlayColors{};
  std::array<uint8_t, 81> overlayAlpha{};
  assert(drawGlyphPassRgb565A8(
      overlayColors.data(), overlayAlpha.data(), 9, 9, 9, 9, fill.data(),
      distance.data(), 3, 3, -64, -64, identity, 0, 0x0000, 0xffff));
  assert(drawGlyphPassRgb565A8(
      overlayColors.data(), overlayAlpha.data(), 9, 9, 9, 9, fill.data(),
      distance.data(), 3, 3, -64, -64, identity, 1, 0x0000, 0xffff));
  for (int y = 3; y <= 5; ++y) {
    for (int x = 3; x <= 5; ++x) {
      const size_t index = static_cast<size_t>(y) * 9 + x;
      assert(overlayAlpha[index] == 255);
      assert(overlayColors[index] ==
             (x == 4 && y == 4 ? 0x0000 : 0xffff));
    }
  }
  overlayColors[0] = 0x1234;
  overlayColors[1] = 0x4321;
  overlayColors[2] = 0x1234;
  overlayAlpha[0] = 0;
  overlayAlpha[1] = 7;
  overlayAlpha[2] = 12;
  assert(makeColorOpaque(overlayColors.data(), overlayAlpha.data(), 3, 1, 3,
                         3, 0x1234) == 2);
  assert(overlayAlpha[0] == 255);
  assert(overlayAlpha[1] == 7);
  assert(overlayAlpha[2] == 255);
  return 0;
}
