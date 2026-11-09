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

void assertPlacement(const Image &plane, const Image &source) {
  for (unsigned row = 0; row < epaper::height; ++row)
    for (unsigned byte = 0; byte < epaper::stride; ++byte)
      assert(plane[(epaper::height - 1 - row) * epaper::stride + byte] ==
             source[row * epaper::stride + byte]);
}

void assertPlacement(const Ram &ram, const Image &source) {
  assertPlacement(ram.current, source);
}

void exercise(bool resetRegisters) {
  Image desired{};
  // Asymmetric, nonuniform contents reveal transposition, mirrored windows,
  // row wrap and accidental overwrites of unchanged bytes.
  for (size_t i = 0; i < desired.size(); ++i)
    desired[i] = static_cast<uint8_t>((i * 37 + i / epaper::stride * 19) & 255);
  Ram incremental(resetRegisters);
  epaper::Ssd1677<Ram> panel(incremental);
  assert(panel.present(desired.data(), nullptr, whole, true));
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
      assert(panel.present(desired.data(), before.data(), dirty, false));
      Ram full(resetRegisters);
      epaper::Ssd1677<Ram> reference(full);
      assert(reference.present(desired.data(), nullptr, whole, true));
      assert(incremental.current == full.current);
      assertPlacement(incremental, desired);
      assertPlacement(incremental.previous, before);
    }
    // Reestablish history after both a cleaning refresh and sleep/wake;
    // subsequent narrow partials must retain the identical coordinate space.
    if (cycle % 2) assert(panel.sleep());
    assert(panel.present(desired.data(), nullptr, whole, true));
    assertPlacement(incremental, desired);
    assert(incremental.previous == incremental.current);
  }
  // Exercise the same asymmetric images the operator will see on the glass.
  assert(epaper::diagnostic::paint(5, desired.data()));
  assert(panel.present(desired.data(), nullptr, whole, true));
  for (unsigned pattern : {6U, 5U, 7U, 5U, 8U, 5U, 6U, 7U, 8U}) {
    const auto before = desired;
    assert(epaper::diagnostic::paint(pattern, desired.data()));
    const auto difference = epaper::compareFrames(desired.data(), before.data());
    assert(difference.changedBytes == 72 || difference.changedBytes == 144);
    assert(difference.window.x == 200 && difference.window.right == 224);
    assert(panel.present(desired.data(), before.data(), difference.window, false));
    assertPlacement(incremental, desired);
  }
  const auto ui = desired;
  assert(!epaper::diagnostic::paint(4, desired.data()) && ui == desired);
  assert(!epaper::diagnostic::paint(99, desired.data()) && ui == desired);
}
// Glass model for the RAM history between differential updates. Each 0x22 0xFF
// update drives only pixels where the previous and new RAM differ. The
// controller then swaps the two RAM roles (what the 3.97-inch glass showed in
// E397-11), copies new into previous, or keeps both. Physical waveform quality
// remains a hardware gate.
enum class History { Swap, Copy, Keep };

struct Glass {
  std::array<Image, 2> ram{};
  Image glass{};
  const History history;
  unsigned current = 0; // Physical RAM addressed by 0x24.
  uint8_t command = 0, update = 0, mode = 3;
  unsigned xs = 0, xe = 959, ys = 0, ye = 679, x = 0, y = 0;
  explicit Glass(History value) : history(value) {
    for (auto &plane : ram) plane.fill(0xff);
    glass.fill(0xff);
  }
  void reset() { mode = 3; xs = 0; xe = 959; ys = 0; ye = 679; x = 0; y = 0; }
  void yield() {}
  bool waitReady(uint32_t) { return true; }
  bool waitWaveform(uint32_t) { return true; }
  static unsigned word(const uint8_t *p) { return p[0] | (unsigned(p[1]) << 8); }
  void activate() {
    Image &next = ram[current], &prior = ram[1 - current];
    if (update == 0xF7) {
      glass = next;
      return;
    }
    assert(update == 0xFF);
    for (size_t i = 0; i < glass.size(); ++i) {
      const uint8_t changed = next[i] ^ prior[i];
      glass[i] = static_cast<uint8_t>((glass[i] & ~changed) | (next[i] & changed));
    }
    if (history == History::Swap) current = 1 - current;
    else if (history == History::Copy) prior = next;
  }
  bool write(bool data, const uint8_t *bytes, size_t size) {
    if (!data) {
      command = bytes[0];
      if (command == 0x12) reset();
      if (command == 0x20) activate();
      return true;
    }
    switch (command) {
    case 0x11: mode = bytes[0]; break;
    case 0x22: update = bytes[0]; break;
    case 0x44: xs = word(bytes); xe = word(bytes + 2); break;
    case 0x45: ys = word(bytes); ye = word(bytes + 2); break;
    case 0x4e: x = word(bytes); break;
    case 0x4f: y = word(bytes); break;
    case 0x24:
    case 0x26:
      for (size_t i = 0; i < size; ++i) {
        ram[command == 0x24 ? current : 1 - current][y * epaper::stride + x / 8] = bytes[i];
        x += 8;
        if (x > std::max(xs, xe)) {
          x = std::min(xs, xe);
          const auto low = std::min(ys, ye), high = std::max(ys, ye);
          y = y == low ? high : y - 1;
        }
      }
      break;
    default: break;
    }
    return true;
  }
};

// The driver before E397-11: only the dirty window of the new plane.
void legacyPartial(Glass &device, const Image &image, epaper::Window w) {
  const auto send = [&](uint8_t reg, std::initializer_list<uint8_t> data) {
    device.write(false, &reg, 1);
    if (data.size()) device.write(true, data.begin(), data.size());
  };
  const uint16_t lastX = w.right - 1, firstY = epaper::height - 1 - w.y,
                 lastY = epaper::height - w.bottom;
  send(0x11, {0x01});
  send(0x44, {uint8_t(w.x), uint8_t(w.x >> 8), uint8_t(lastX), uint8_t(lastX >> 8)});
  send(0x45, {uint8_t(firstY), uint8_t(firstY >> 8), uint8_t(lastY), uint8_t(lastY >> 8)});
  send(0x4E, {uint8_t(w.x), uint8_t(w.x >> 8)});
  send(0x4F, {uint8_t(firstY), uint8_t(firstY >> 8)});
  send(0x24, {});
  for (uint16_t row = w.y; row < w.bottom; ++row)
    device.write(true, image.data() + size_t(row) * epaper::stride + w.x / 8, w.rowBytes());
  send(0x22, {0xFF});
  send(0x20, {});
}

// Native x 768..799 is the portrait footer; x 0..687 is the moving map.
void change(Image &frame, unsigned firstByte, unsigned lastByte, uint8_t salt) {
  for (unsigned row = 0; row < epaper::height; row += 3)
    for (unsigned byte = firstByte; byte <= lastByte; ++byte)
      frame[row * epaper::stride + byte] ^= static_cast<uint8_t>(salt + row + byte);
}

bool presentFooterThenMap(History history, bool legacy) {
  Glass device(history);
  epaper::Ssd1677<Glass> panel(device);
  Image shown{}, frame{};
  for (size_t i = 0; i < frame.size(); ++i)
    frame[i] = static_cast<uint8_t>((i * 29 + i / epaper::stride * 7) & 255);
  assert(panel.present(frame.data(), nullptr, whole, true));
  shown = frame;
  bool glassMatched = true;
  for (unsigned step = 0; step < 6; ++step) {
    if (step == 0) change(frame, 96, 99, 0x35); // Footer text, once.
    else change(frame, 0, 85, static_cast<uint8_t>(step * 17));
    const auto difference = epaper::compareFrames(frame.data(), shown.data());
    assert(!difference.window.empty());
    if (legacy) legacyPartial(device, frame, difference.window);
    else assert(panel.present(frame.data(), shown.data(), difference.window, false));
    shown = frame;
    for (unsigned row = 0; row < epaper::height; ++row)
      for (unsigned byte = 0; byte < epaper::stride; ++byte)
        glassMatched &= device.glass[(epaper::height - 1 - row) * epaper::stride + byte] ==
                        frame[row * epaper::stride + byte];
  }
  return glassMatched;
}

void exerciseHistory() {
  // The old window-only plane reproduces the recorded footer flip on swapping
  // RAM roles; the complete planes keep the glass equal to every frame.
  assert(!presentFooterThenMap(History::Swap, true));
  for (const History history : {History::Swap, History::Copy, History::Keep})
    assert(presentFooterThenMap(history, false));
}
} // namespace

int main() {
  exercise(false);
  exercise(true);
  exerciseHistory();
  std::cout << "SSD1677 full/partial RAM placement, edges, recovery and RAM history passed\n";
}
