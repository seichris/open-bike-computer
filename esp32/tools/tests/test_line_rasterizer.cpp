#include "../../lib/utils/src/line_rasterizer.hpp"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <vector>

namespace {

constexpr int32_t WIDTH = 40;
constexpr int32_t HEIGHT = 40;
constexpr uint32_t STRIDE = 44;
constexpr uint16_t BACKGROUND = 0x0000;
constexpr uint16_t FOREGROUND = 0xA55A;

using Buffer = std::vector<uint16_t>;

Buffer makeBuffer() {
  return Buffer(STRIDE * HEIGHT, BACKGROUND);
}

bool isSet(const Buffer &buffer, int32_t x, int32_t y) {
  return buffer[y * STRIDE + x] == FOREGROUND;
}

void assertPaddingUntouched(const Buffer &buffer) {
  for (int32_t y = 0; y < HEIGHT; ++y) {
    for (uint32_t x = WIDTH; x < STRIDE; ++x)
      assert(buffer[y * STRIDE + x] == BACKGROUND);
  }
}

void assertRowHasNoInteriorHoles(const Buffer &buffer, int32_t y) {
  int32_t first = -1;
  int32_t last = -1;
  for (int32_t x = 0; x < WIDTH; ++x) {
    if (isSet(buffer, x, y)) {
      if (first < 0)
        first = x;
      last = x;
    }
  }

  assert(first >= 0);
  for (int32_t x = first; x <= last; ++x)
    assert(isSet(buffer, x, y));
}

} // namespace

int main() {
  {
    Buffer horizontal = makeBuffer();
    line_rasterizer::drawFilledLine(
        horizontal.data(), WIDTH, HEIGHT, STRIDE, 5, 10, 30, 10, FOREGROUND, 4);

    for (int32_t y = 9; y <= 12; ++y) {
      for (int32_t x = 5; x <= 30; ++x)
        assert(isSet(horizontal, x, y));
    }
    assert(!isSet(horizontal, 15, 8));
    assert(!isSet(horizontal, 15, 13));
    assertPaddingUntouched(horizontal);

    Buffer reversed = makeBuffer();
    line_rasterizer::drawFilledLine(
        reversed.data(), WIDTH, HEIGHT, STRIDE, 30, 10, 5, 10, FOREGROUND, 4);
    assert(horizontal == reversed);
  }

  {
    Buffer diagonal = makeBuffer();
    line_rasterizer::drawFilledLine(
        diagonal.data(), WIDTH, HEIGHT, STRIDE, 5, 5, 32, 32, FOREGROUND, 8);

    for (int32_t y = 7; y <= 30; ++y)
      assertRowHasNoInteriorHoles(diagonal, y);
    assertPaddingUntouched(diagonal);
  }

  {
    Buffer clipped = makeBuffer();
    line_rasterizer::drawFilledLine(clipped.data(), WIDTH, HEIGHT, STRIDE, -300,
                                    20, 300, 20, FOREGROUND, 4);
    for (int32_t y = 19; y <= 22; ++y) {
      for (int32_t x = 0; x < WIDTH; ++x)
        assert(isSet(clipped, x, y));
    }
    assertPaddingUntouched(clipped);
  }

  {
    Buffer polyline = makeBuffer();
    line_rasterizer::drawFilledLine(polyline.data(), WIDTH, HEIGHT, STRIDE, 5,
                                    30, 20, 10, FOREGROUND, 6);
    line_rasterizer::drawFilledLine(polyline.data(), WIDTH, HEIGHT, STRIDE, 20,
                                    10, 35, 30, FOREGROUND, 6);
    assert(isSet(polyline, 20, 10));
    assertRowHasNoInteriorHoles(polyline, 10);
    assertPaddingUntouched(polyline);
  }

  return 0;
}
