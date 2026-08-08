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

int32_t countSet(const Buffer &buffer) {
  int32_t count = 0;
  for (int32_t y = 0; y < HEIGHT; ++y) {
    for (int32_t x = 0; x < WIDTH; ++x)
      count += isSet(buffer, x, y);
  }
  return count;
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

void assertRowEquals(const Buffer &buffer, int32_t y, int32_t first,
                     int32_t last) {
  for (int32_t x = 0; x < WIDTH; ++x)
    assert(isSet(buffer, x, y) == (x >= first && x <= last));
}

} // namespace

int main() {
  {
    Buffer thin = makeBuffer();
    line_rasterizer::drawFilledLine(thin.data(), WIDTH, HEIGHT, STRIDE, 4, 5,
                                    9, 10, FOREGROUND, 1);
    for (int32_t i = 0; i <= 5; ++i)
      assert(isSet(thin, 4 + i, 5 + i));
    assert(countSet(thin) == 6);

    Buffer reversed = makeBuffer();
    line_rasterizer::drawFilledLine(reversed.data(), WIDTH, HEIGHT, STRIDE, 9,
                                    10, 4, 5, FOREGROUND, 1);
    assert(thin == reversed);
    assertPaddingUntouched(thin);
  }

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

    Buffer reversed = makeBuffer();
    line_rasterizer::drawFilledLine(
        reversed.data(), WIDTH, HEIGHT, STRIDE, 32, 32, 5, 5, FOREGROUND, 8);
    assert(diagonal == reversed);
  }

  {
    Buffer diagonal = makeBuffer();
    line_rasterizer::drawFilledLine(
        diagonal.data(), WIDTH, HEIGHT, STRIDE, 2, 3, 13, 29, FOREGROUND, 2);

    Buffer reversed = makeBuffer();
    line_rasterizer::drawFilledLine(
        reversed.data(), WIDTH, HEIGHT, STRIDE, 13, 29, 2, 3, FOREGROUND, 2);
    assert(diagonal == reversed);
    assert(isSet(diagonal, 2, 3));
    assert(isSet(diagonal, 13, 29));
    assert(countSet(diagonal) > 20);
    assertPaddingUntouched(diagonal);
  }

  {
    Buffer steep = makeBuffer();
    line_rasterizer::drawFilledLine(steep.data(), WIDTH, HEIGHT, STRIDE, 30, 3,
                                    18, 34, FOREGROUND, 7);

    Buffer reversed = makeBuffer();
    line_rasterizer::drawFilledLine(reversed.data(), WIDTH, HEIGHT, STRIDE, 18,
                                    34, 30, 3, FOREGROUND, 7);
    assert(steep == reversed);
    assert(isSet(steep, 30, 3));
    assert(isSet(steep, 18, 34));
    assert(countSet(steep) > 150);
    assertPaddingUntouched(steep);
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
    Buffer verticallyClipped = makeBuffer();
    line_rasterizer::drawFilledLine(verticallyClipped.data(), WIDTH, HEIGHT,
                                    STRIDE, 20, -300, 20, 300, FOREGROUND, 4);
    for (int32_t y = 0; y < HEIGHT; ++y) {
      for (int32_t x = 19; x <= 22; ++x)
        assert(isSet(verticallyClipped, x, y));
    }
    assertPaddingUntouched(verticallyClipped);

    Buffer rejected = makeBuffer();
    line_rasterizer::drawFilledLine(rejected.data(), WIDTH, HEIGHT, STRIDE,
                                    -300, -300, -200, -250, FOREGROUND, 8);
    assert(rejected == makeBuffer());
  }

  {
    Buffer capped = makeBuffer();
    line_rasterizer::drawFilledLine(capped.data(), WIDTH, HEIGHT, STRIDE, 10,
                                    15, 25, 15, FOREGROUND, 4);
    assert(isSet(capped, 9, 15));
    assert(isSet(capped, 26, 15));
    assert(!isSet(capped, 8, 15));
    assert(!isSet(capped, 27, 15));
    assertPaddingUntouched(capped);
  }

  {
    Buffer narrowPoint = makeBuffer();
    line_rasterizer::drawFilledLine(narrowPoint.data(), WIDTH, HEIGHT, STRIDE,
                                    20, 20, 20, 20, FOREGROUND, 2);
    assertRowEquals(narrowPoint, 20, 20, 21);
    assertRowEquals(narrowPoint, 21, 20, 21);
    assert(countSet(narrowPoint) == 4);
    assertPaddingUntouched(narrowPoint);

    Buffer point = makeBuffer();
    line_rasterizer::drawFilledLine(point.data(), WIDTH, HEIGHT, STRIDE, 20,
                                    20, 20, 20, FOREGROUND, 4);
    assertRowEquals(point, 19, 20, 21);
    assertRowEquals(point, 20, 19, 22);
    assertRowEquals(point, 21, 19, 22);
    assertRowEquals(point, 22, 20, 21);
    assert(countSet(point) == 12);
    assertPaddingUntouched(point);

    Buffer oddPoint = makeBuffer();
    line_rasterizer::drawFilledLine(oddPoint.data(), WIDTH, HEIGHT, STRIDE, 20,
                                    20, 20, 20, FOREGROUND, 5);
    assertRowEquals(oddPoint, 18, 20, 20);
    assertRowEquals(oddPoint, 19, 19, 21);
    assertRowEquals(oddPoint, 20, 18, 22);
    assertRowEquals(oddPoint, 21, 19, 21);
    assertRowEquals(oddPoint, 22, 20, 20);
    assert(countSet(oddPoint) == 13);
    assertPaddingUntouched(oddPoint);
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


  {
    constexpr uint8_t ALPHA = 0xFF;
    constexpr uint32_t ALPHA_STRIDE = 43;
    std::vector<uint8_t> alpha(ALPHA_STRIDE * HEIGHT, 0);
    line_rasterizer::drawFilledLine(
        alpha.data(), WIDTH, HEIGHT, ALPHA_STRIDE, 3, 8, 34, 27, ALPHA, 5);
    assert(alpha[8 * ALPHA_STRIDE + 3] == ALPHA);
    assert(alpha[27 * ALPHA_STRIDE + 34] == ALPHA);
    for (int32_t y = 0; y < HEIGHT; ++y) {
      for (uint32_t x = WIDTH; x < ALPHA_STRIDE; ++x)
        assert(alpha[y * ALPHA_STRIDE + x] == 0);
    }
  }

  return 0;
}
