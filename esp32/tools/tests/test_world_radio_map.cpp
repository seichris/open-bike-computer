#include "../../lib/world_radio/world_radio_map.hpp"

#include <array>
#include <cassert>
#include <iostream>
#include <limits>
#include <vector>

int main() {
  using namespace world_radio_map;
  uint16_t palette[256]{};
  palette[1] = 0x1234;
  palette[2] = 0x5678;
  constexpr uint16_t guard = 0xabcd;
  std::array<uint16_t, 10> pixels{};
  pixels.fill(guard);
  // Three repeated pixels followed by three literals; row padding untouched.
  const uint8_t valid[] = {0x82, 1, 2, 2, 1, 2};
  assert(decode(valid, sizeof(valid), palette, pixels.data() + 1, 8, 3, 2, 4));
  assert(pixels[0] == guard && pixels[9] == guard);
  assert(pixels[4] == guard && pixels[8] == guard);
  assert(pixels[1] == 0x1234 && pixels[3] == 0x1234);
  assert(pixels[5] == 0x5678 && pixels[6] == 0x1234 && pixels[7] == 0x5678);
  assert(!decode(valid, sizeof(valid), palette, nullptr, 8, 3, 2, 4));
  assert(!decode(nullptr, 1, palette, pixels.data(), 8, 3, 2, 4));
  assert(!decode(valid, sizeof(valid), palette, pixels.data(), 7, 3, 2, 4));
  assert(!decode(valid, sizeof(valid), palette, pixels.data(), 8, 3, 2, 2));
  assert(!decode(valid, sizeof(valid), palette, pixels.data(), 8, 0, 2, 0));
  assert(!decode(valid, sizeof(valid), palette, pixels.data(), 8, 3, 0, 4));
  assert(!decode(valid, sizeof(valid), palette, pixels.data(), 8, 3,
                 std::numeric_limits<std::size_t>::max(), 4));
  const uint8_t truncatedRun[] = {0x85};
  const uint8_t truncatedLiteral[] = {5, 1, 2};
  const uint8_t oversizedRun[] = {0xff, 1};
  const uint8_t extraPacket[] = {0x85, 1, 0, 2};
  const uint8_t incomplete[] = {0x84, 1};
  for (const auto &packet : {std::vector<uint8_t>{truncatedRun, truncatedRun + 1},
                             std::vector<uint8_t>{truncatedLiteral, truncatedLiteral + 3},
                             std::vector<uint8_t>{oversizedRun, oversizedRun + 2},
                             std::vector<uint8_t>{extraPacket, extraPacket + 4},
                             std::vector<uint8_t>{incomplete, incomplete + 2}}) {
    pixels.fill(guard);
    assert(!decode(packet.data(), packet.size(), palette, pixels.data() + 1,
                   8, 3, 2, 4));
    assert(pixels[0] == guard && pixels[9] == guard);
    assert(pixels[4] == guard && pixels[8] == guard);
  }

  // Decode the actual shipped texture with a padded canvas and compare every
  // pixel to the generator's RGB565 fingerprint, including row/wrap edges.
  constexpr std::size_t stride = WIDTH + 4;
  std::vector<uint16_t> canvas(stride * HEIGHT + 2, guard);
  const bool rendered = render(canvas.data() + 1, stride * HEIGHT, stride);
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
  assert(rendered);
  uint32_t fingerprint = 2166136261U;
  for (int y = 0; y < HEIGHT; ++y) {
    for (int x = 0; x < WIDTH; ++x) {
      const auto color = canvas[1 + y * stride + x];
      fingerprint = (fingerprint ^ (color & 0xff)) * 16777619U;
      fingerprint = (fingerprint ^ (color >> 8)) * 16777619U;
    }
    for (std::size_t x = WIDTH; x < stride; ++x) {
      assert(canvas[1 + y * stride + x] == guard);
    }
  }
  assert(fingerprint == 0x6099e8cdU);
#else
  assert(!rendered);
  for (const auto pixel : canvas) assert(pixel == guard);
#endif
  assert(canvas.front() == guard && canvas.back() == guard);
  std::cout << "World Radio map tests passed\n";
}
