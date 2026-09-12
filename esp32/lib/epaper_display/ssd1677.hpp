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
           command(0x3C, {0x01}) && window({0, 0, width, height});
  }

  bool present(const uint8_t *image, Window dirty, bool full) {
    if (!image || dirty.empty()) return false;
    if (full) {
      if (!initialize() || !plane(0x24, image, {0, 0, width, height}) ||
          !window({0, 0, width, height}) ||
          !plane(0x26, image, {0, 0, width, height})) return false;
    } else {
      // Vendor partial mode resets/configures the window without SWRESET,
      // retaining the base plane. Only use it after a successful full/base.
      io_.reset();
      if (!io_.waitReady(busyTimeoutMs) || !command(0x18, {0x80}) ||
          !command(0x3C, {0x80}) || !window(dirty) ||
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
  bool window(Window w) {
    if (w.empty() || w.right > width || w.bottom > height ||
        w.x % 8 || w.right % 8) return false;
    const uint16_t right = w.right - 1, bottom = w.bottom - 1;
    // Explicit x/y incrementing scan order for our top-to-bottom packed rows.
    // Both full and partial use the same order, unlike the demo's implicit
    // reset defaults. SSD1677 RAM coordinates are pixels, not byte indices.
    return command(0x11, {0x03}) &&
           command(0x44, {uint8_t(w.x), uint8_t(w.x >> 8),
                          uint8_t(right), uint8_t(right >> 8)}) &&
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
