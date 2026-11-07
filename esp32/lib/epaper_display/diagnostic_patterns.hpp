#pragma once
#include "epaper_raster.hpp"

namespace epaper::diagnostic {
constexpr int patternCount = 9;
inline const char *name(unsigned pattern) {
  constexpr const char *names[] = {"white", "black", "checker", "edges", "UI",
      "asymmetric-base", "left-update", "center-update", "right-update"};
  return pattern < patternCount ? names[pattern] : "invalid";
}

inline void black(uint8_t *image, uint16_t x, uint16_t y) {
  const auto point = nativePoint(x, y);
  image[size_t(point.y) * stride + point.x / 8] &= ~(0x80u >> (point.x % 8));
}

// 5..8 share fixed portrait rulers and asymmetric corner marks. Only a small
// square changes at three off-center/center positions; full-screen patterns
// alone cannot expose a shifted differential window. 4 preserves the real UI.
inline bool paint(unsigned pattern, uint8_t *image) {
  if (pattern == 4 || pattern >= patternCount) return false;
  std::memset(image, pattern == 1 ? 0 : 0xff, frameBytes);
  if (pattern <= 1) return true;
  for (uint16_t y = 0; y < logicalHeight; ++y) {
    for (uint16_t x = 0; x < logicalWidth; ++x) {
      const bool edges = x == 0 || x == logicalWidth - 1 ||
                         y == 0 || y == logicalHeight - 1;
      bool ink = pattern == 2 ? (x / 8 + y / 8) % 2 == 0 : edges;
      if (pattern >= 5) {
        ink = edges || (y == 80 && x >= 24 && x <= 456) ||
              (x % 40 == 0 && y >= 72 && y <= 88) ||
              (x == 24 && y >= 80 && y <= 760) ||
              (y % 40 == 0 && x >= 16 && x <= 32) ||
              (x >= 40 && x < 56 && y >= 24 && y < 48) ||
              (x >= 404 && x < 444 && y >= 720 && y < 736);
        // One, two, three fixed bars label the left/center/right targets.
        for (unsigned i = 0; i < 3; ++i) {
          const unsigned center = 80 + i * 160;
          ink |= x >= center - 24 && x <= center + 24 && y == 184;
          for (unsigned bar = 0; bar <= i; ++bar)
            ink |= x >= center - 12 + bar * 8 && x < center - 8 + bar * 8 &&
                   y >= 152 && y < 168;
        }
        if (pattern >= 6) {
          const unsigned center = 80 + (pattern - 6) * 160;
          ink |= x >= center - 12 && x < center + 12 && y >= 200 && y < 224;
        }
      }
      if (ink) black(image, x, y);
    }
  }
  return true;
}
} // namespace epaper::diagnostic
