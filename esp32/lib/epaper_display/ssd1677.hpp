#pragma once

// Register/waveform sequences adapted from Waveshare EPD_3in97.cpp at
// 9b12d40731a80213b927ee8a421cae4082952819. See LICENSE.waveshare.
#include "epaper_raster.hpp"
#include "epaper_policy.hpp"
#include <initializer_list>

namespace epaper {
// Transport owns hardware, deadlines and yielding. No LVGL or I2C calls here.
template <typename Transport> class Ssd1677 {
public:
  explicit Ssd1677(Transport &transport) : io_(transport) {}

  bool initialize() {
    io_.reset();
    if (!io_.waitReady(busyTimeoutMs) || !command(0x12) ||
        !io_.waitReady(busyTimeoutMs)) return false;
    return command(0x18, {0x80}) &&
           command(0x0C, {0xAE, 0xC7, 0xC3, 0xC0, 0x80}) &&
           command(0x01, {0xDF, 0x01, 0x02}) &&
           command(0x3C, {0x01}) && fullWindow();
  }

  bool present(const uint8_t *image, Window dirty, bool full) {
    if (!image || dirty.empty()) return false;
    if (full) {
      if (!initialize() || !plane(0x24, image, {0, 0, width, height}) ||
          !plane(0x26, image, {0, 0, width, height})) return false;
    } else {
      // Vendor partial mode resets/configures the window without SWRESET,
      // retaining the base plane. Only use it after a successful full/base.
      io_.reset();
      if (!io_.waitReady(busyTimeoutMs) || !command(0x18, {0x80}) ||
          !command(0x3C, {0x80}) || !partialWindow(dirty) ||
          !plane(0x24, image, dirty)) return false;
    }
    return command(0x22, {static_cast<uint8_t>(full ? 0xF7 : 0xFF)}) &&
           command(0x20) && io_.waitWaveform(busyTimeoutMs);
  }

  bool sleep() { return command(0x10, {0x01}); }

private:
  bool command(uint8_t reg, std::initializer_list<uint8_t> data = {}) {
    return io_.write(false, &reg, 1) &&
           (data.size() == 0 || io_.write(true, data.begin(), data.size()));
  }
  bool fullWindow() {
    // Match Waveshare's proven SSD1677 full-refresh sequence exactly. The
    // controller consumes our packed rows in stream order while its Y window
    // is configured from the last gate line back to zero.
    return command(0x11, {0x01}) &&
           command(0x44, {0x00, 0x00, uint8_t((width - 1) & 0xFF),
                          uint8_t((width - 1) >> 8)}) &&
           command(0x45, {uint8_t((height - 1) & 0xFF),
                          uint8_t((height - 1) >> 8), 0x00, 0x00}) &&
           command(0x4E, {0x00, 0x00}) &&
           command(0x4F, {0x00, 0x00});
  }
  bool partialWindow(Window w) {
    if (w.empty() || w.right > width || w.bottom > height ||
        w.x % 8 || w.right % 8) return false;
    const uint16_t lastByteStart = w.right - 8;
    const uint16_t bottom = w.bottom - 1;
    // The vendor partial-update endpoint is the first pixel of the last byte,
    // rather than the last pixel in that byte. Data-entry mode is retained
    // from the preceding successful full refresh.
    return command(0x44, {uint8_t(w.x), uint8_t(w.x >> 8),
                          uint8_t(lastByteStart),
                          uint8_t(lastByteStart >> 8)}) &&
           command(0x45, {uint8_t(w.y), uint8_t(w.y >> 8),
                          uint8_t(bottom), uint8_t(bottom >> 8)}) &&
           command(0x4E, {uint8_t(w.x), uint8_t(w.x >> 8)}) &&
           command(0x4F, {uint8_t(w.y), uint8_t(w.y >> 8)});
  }
  bool plane(uint8_t reg, const uint8_t *image, Window w) {
    if (!command(reg)) return false;
    for (uint16_t y = w.y; y < w.bottom; ++y) {
      if (!io_.write(true, image + size_t(y) * stride + w.x / 8,
                     w.rowBytes())) return false;
      if (y % 16 == 15) io_.yield();
    }
    return true;
  }
  Transport &io_;
};
} // namespace epaper
