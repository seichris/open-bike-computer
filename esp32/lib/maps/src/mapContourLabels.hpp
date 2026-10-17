#pragma once
#include "mapSurface.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
namespace map_contour_labels {
struct Box {
  float x = 0, y = 0, w = 0, h = 0;
};
inline bool overlaps(Box a, Box b) {
  return std::abs(a.x - b.x) * 2 < a.w + b.w &&
         std::abs(a.y - b.y) * 2 < a.h + b.h;
}
inline int characterCount(int elevation) {
  int count = 2 + (elevation < 0); // Space and unit, plus an optional sign.
  int magnitude = std::abs(elevation);
  do {
    ++count;
    magnitude /= 10;
  } while (magnitude);
  return count;
}
inline bool segmentHits(Box box, float ax, float ay, float bx, float by,
                        float margin) {
  // Liang-Barsky against the text rectangle expanded by road/route width.
  float lo = 0, hi = 1, dx = bx - ax, dy = by - ay;
  const float p[] = {-dx, dx, -dy, dy}, q[] = {ax - box.x + box.w / 2 + margin,
                                               box.x + box.w / 2 + margin - ax,
                                               ay - box.y + box.h / 2 + margin,
                                               box.y + box.h / 2 + margin - ay};
  for (int i = 0; i < 4; ++i) {
    if (p[i] == 0) {
      if (q[i] < 0)
        return false;
    } else {
      float t = q[i] / p[i];
      if (p[i] < 0)
        lo = std::max(lo, t);
      else
        hi = std::min(hi, t);
      if (lo > hi)
        return false;
    }
  }
  return true;
}
// Firmware-owned numeric glyphs; old map font assets need not contain digits.
inline void draw(map_surface::LabelSurface surface, int cx, int cy,
                 int elevation, int scale = 2) {
  static constexpr uint8_t glyphs[][5] = {{0x3e, 0x51, 0x49, 0x45, 0x3e},
                                          {0, 0x42, 0x7f, 0x40, 0},
                                          {0x42, 0x61, 0x51, 0x49, 0x46},
                                          {0x21, 0x41, 0x45, 0x4b, 0x31},
                                          {0x18, 0x14, 0x12, 0x7f, 0x10},
                                          {0x27, 0x45, 0x45, 0x45, 0x39},
                                          {0x3c, 0x4a, 0x49, 0x49, 0x30},
                                          {1, 0x71, 9, 5, 3},
                                          {0x36, 0x49, 0x49, 0x49, 0x36},
                                          {6, 0x49, 0x49, 0x29, 0x1e},
                                          {8, 8, 8, 8, 8},
                                          {0x7c, 4, 0x18, 4, 0x78}};
  char text[16];
  std::snprintf(text, sizeof(text), "%d m", elevation);
  const int left = cx - int(std::strlen(text)) * 3 * scale,
            top = cy - 7 * scale / 2;
  for (int pass = 0; pass < 2; ++pass)
    for (size_t c = 0; c < std::strlen(text); ++c) {
      const int index = text[c] >= '0' && text[c] <= '9' ? text[c] - '0'
                        : text[c] == '-'                 ? 10
                        : text[c] == 'm'                 ? 11
                                                         : -1;
      if (index < 0)
        continue;
      for (int x = 0; x < 5; ++x)
        for (int y = 0; y < 7; ++y)
          if (glyphs[index][x] & (1 << y))
            for (int sy = pass ? 0 : -1; sy < scale + (pass ? 0 : 1); ++sy)
              for (int sx = pass ? 0 : -1; sx < scale + (pass ? 0 : 1); ++sx) {
                int px = left + int(c) * 6 * scale + x * scale + sx,
                    py = top + y * scale + sy;
                if (!surface.color.contains(px, py))
                  continue;
                surface.color.pixels[py * surface.color.stridePixels + px] =
                    pass ? 0x6204 : 0xffff;
                if (surface.transparent())
                  surface.alpha[py * surface.alphaStrideBytes + px] = 255;
              }
    }
}
} // namespace map_contour_labels
