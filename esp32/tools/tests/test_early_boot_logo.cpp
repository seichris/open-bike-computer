#include "../../lib/panel/early_boot_logo.hpp"

#include <array>
#include <cassert>
#include <cstdint>
#include <vector>

int main() {
  // Asymmetric 3x2 image, with row padding, tests orientation, RGB byte order,
  // transparency and half-opacity without requiring LVGL or display hardware.
  const uint8_t pixels[] = {
      0x00, 0xf8, 0xe0, 0x07, 0x1f, 0x00, 0xaa, 0xaa,
      0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xbb, 0xbb,
      255, 255, 255, 0, 0, 128, 255, 0};
  early_boot_logo::Image image{pixels, sizeof(pixels), 3, 2, 8};
  const auto render = [&](bool clockwise, uint16_t expectedX,
                          uint16_t expectedY, uint16_t expectedWidth) {
    std::vector<uint16_t> result;
    uint16_t rows = 0;
    assert(early_boot_logo::drawCentered(
        image, 9, 9, clockwise,
        [&](uint16_t x, uint16_t y, const uint16_t *row, uint16_t width) {
          assert(x == expectedX);
          assert(y == expectedY + rows++);
          assert(width == expectedWidth);
          result.insert(result.end(), row, row + width);
        }));
    return result;
  };
  assert((render(false, 3, 3, 3) ==
          std::vector<uint16_t>{0xf800, 0x07e0, 0x001f, 0, 0x8410, 0xffff}));
  assert((render(true, 4, 3, 2) ==
          std::vector<uint16_t>{0, 0xf800, 0x8410, 0x07e0, 0xffff, 0x001f}));

  const auto noWrite = [](uint16_t, uint16_t, uint16_t *, uint16_t) {
    assert(false && "invalid image must not write to the panel");
  };
  image.dataSize--;
  assert(!early_boot_logo::drawCentered(image, 9, 9, true, noWrite));
  image.dataSize++;
  assert(!early_boot_logo::drawCentered(image, 1, 9, true, noWrite));
  assert(!early_boot_logo::drawCentered(image, 9, 2, true, noWrite));
  image.stride = 5;
  assert(!early_boot_logo::drawCentered(image, 9, 9, false, noWrite));
  image = {nullptr, 0, 0, 0, 0};
  assert(!early_boot_logo::drawCentered(image, 9, 9, true, noWrite));
}
