#include "../../lib/epaper_display/ssd1677.hpp"
#include "../../lib/epaper_display/diagnostic_patterns.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <iostream>

namespace {
using Image = std::array<uint8_t, epaper::frameBytes>;
constexpr epaper::Window whole{0, 0, epaper::width, epaper::height};

// Controller-address model, not a waveform/panel emulator. Registers and
// direction bits follow SSD1677 Rev 1.0 sections 8.2-8.5, independently of the
// driver's coordinate helper. The physical orientation remains a hardware gate.
struct Ram {
  Image current{}, previous{};
  const bool resetRegisters;
  uint8_t command = 0, mode = 3;
  unsigned xs = 0, xe = 959, ys = 0, ye = 679, x = 0, y = 0;
  explicit Ram(bool reset) : resetRegisters(reset) {
    current.fill(0xff);
    previous.fill(0xff);
  }
  void defaults() {
    mode = 3; xs = 0; xe = 959; ys = 0; ye = 679; x = 0; y = 0;
  }
  void reset() { if (resetRegisters) defaults(); }
  void yield() {}
  bool waitReady(uint32_t) { return true; }
  bool waitWaveform(uint32_t) { return true; }
  static unsigned word(const uint8_t *p) { return p[0] | (unsigned(p[1]) << 8); }
  bool write(bool data, const uint8_t *bytes, size_t size) {
    if (!data) {
      assert(size == 1);
      command = bytes[0];
      if (command == 0x12) defaults(); // SWRESET leaves RAM intact.
      return true;
    }
    switch (command) {
    case 0x11: assert(size == 1); mode = bytes[0]; break;
    case 0x44: assert(size == 4); xs = word(bytes); xe = word(bytes + 2); break;
    case 0x45: assert(size == 4); ys = word(bytes); ye = word(bytes + 2); break;
    case 0x4e: assert(size == 2); x = word(bytes); break;
    case 0x4f: assert(size == 2); y = word(bytes); break;
    case 0x24:
    case 0x26:
      assert((mode & 4) == 0 && (mode & 1) != 0); // X first, increasing X.
      for (size_t i = 0; i < size; ++i) {
        assert(x < epaper::width && y < epaper::height);
        auto &ram = command == 0x24 ? current : previous;
        ram[y * epaper::stride + x / 8] = bytes[i];
        x += 8;
        if (x > std::max(xs, xe)) {
          x = std::min(xs, xe);
          const auto low = std::min(ys, ye), high = std::max(ys, ye);
          if (mode & 2) y = y == high ? low : y + 1;
          else y = y == low ? high : y - 1;
        }
      }
      break;
    default: break;
    }
    return true;
  }
};

void assertPlacement(const Ram &ram, const Image &source) {
  for (unsigned row = 0; row < epaper::height; ++row)
    for (unsigned byte = 0; byte < epaper::stride; ++byte)
      assert(ram.current[(epaper::height - 1 - row) * epaper::stride + byte] ==
             source[row * epaper::stride + byte]);
}

void exercise(bool resetRegisters) {
  Image desired{};
  // Asymmetric, nonuniform contents reveal transposition, mirrored windows,
  // row wrap and accidental overwrites of unchanged bytes.
  for (size_t i = 0; i < desired.size(); ++i)
    desired[i] = static_cast<uint8_t>((i * 37 + i / epaper::stride * 19) & 255);
  Ram incremental(resetRegisters);
  epaper::Ssd1677<Ram> panel(incremental);
  assert(panel.present(desired.data(), whole, true));
  assertPlacement(incremental, desired);
  assert(incremental.previous == incremental.current);

  const std::array<epaper::Window, 10> windows{{
      {0, 0, 8, 1}, {792, 479, 800, 480}, {160, 20, 168, 21},
      {160, 100, 168, 101}, {160, 240, 168, 241},
      {160, 380, 168, 381}, {8, 7, 80, 43}, {600, 13, 800, 28},
      {0, 300, 128, 480}, {312, 197, 488, 283},
  }};
  for (unsigned cycle = 0; cycle < 4; ++cycle) {
    for (const auto window : windows) {
      const Image before = desired;
      for (unsigned row = window.y; row < window.bottom; ++row)
        for (unsigned byte = window.x / 8; byte < window.right / 8; ++byte)
          desired[row * epaper::stride + byte] ^= 0x5b;
      const auto dirty = epaper::dirtyWindow(desired.data(), before.data());
      assert(panel.present(desired.data(), dirty, false));
      Ram full(resetRegisters);
      epaper::Ssd1677<Ram> reference(full);
      assert(reference.present(desired.data(), whole, true));
      assert(incremental.current == full.current);
      assertPlacement(incremental, desired);
    }
    // Reestablish history after both a cleaning refresh and sleep/wake;
    // subsequent narrow partials must retain the identical coordinate space.
    if (cycle % 2) assert(panel.sleep());
    assert(panel.present(desired.data(), whole, true));
    assertPlacement(incremental, desired);
    assert(incremental.previous == incremental.current);
  }
  // Exercise the same asymmetric images the operator will see on the glass.
  assert(epaper::diagnostic::paint(5, desired.data()));
  assert(panel.present(desired.data(), whole, true));
  for (unsigned pattern : {6U, 5U, 7U, 5U, 8U, 5U, 6U, 7U, 8U}) {
    const auto before = desired;
    assert(epaper::diagnostic::paint(pattern, desired.data()));
    const auto difference = epaper::compareFrames(desired.data(), before.data());
    assert(difference.changedBytes == 72 || difference.changedBytes == 144);
    assert(difference.window.x == 200 && difference.window.right == 224);
    assert(panel.present(desired.data(), difference.window, false));
    assertPlacement(incremental, desired);
  }
  const auto ui = desired;
  assert(!epaper::diagnostic::paint(4, desired.data()) && ui == desired);
  assert(!epaper::diagnostic::paint(99, desired.data()) && ui == desired);
}
} // namespace

int main() {
  exercise(false);
  exercise(true);
  std::cout << "SSD1677 full/partial RAM placement, edges and recovery passed\n";
}
