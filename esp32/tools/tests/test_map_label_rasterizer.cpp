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
  return 0;
}
