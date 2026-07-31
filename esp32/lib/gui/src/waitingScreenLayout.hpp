#pragma once

#include <cstdint>

namespace waiting_screen_layout {

struct Rect {
  int16_t x;
  int16_t y;
  int16_t width;
  int16_t height;

  constexpr int16_t right() const { return x + width; }
  constexpr int16_t bottom() const { return y + height; }
};

struct Layout {
  int16_t screenWidth;
  int16_t screenHeight;
  Rect battery;
  Rect title;
  Rect state;
  Rect message;
};

constexpr Layout makeLayout(int16_t width, int16_t height) {
  const int16_t margin = 16;
  const int16_t contentWidth = width - margin * 2;
  return {width,
          height,
          {margin, 34, contentWidth, 34},
          {margin, 88, contentWidth, 58},
          {static_cast<int16_t>((width - 112) / 2),
           static_cast<int16_t>((height - 72) / 2 - 8), 112, 72},
          {margin, static_cast<int16_t>(height - 130), contentWidth, 98}};
}

constexpr bool fits(const Rect &rect, int16_t width, int16_t height) {
  return rect.x >= 0 && rect.y >= 0 && rect.right() <= width &&
         rect.bottom() <= height;
}

constexpr bool isValid(const Layout &layout) {
  return fits(layout.battery, layout.screenWidth, layout.screenHeight) &&
         fits(layout.title, layout.screenWidth, layout.screenHeight) &&
         fits(layout.state, layout.screenWidth, layout.screenHeight) &&
         fits(layout.message, layout.screenWidth, layout.screenHeight) &&
         layout.battery.bottom() <= layout.title.y &&
         layout.title.bottom() <= layout.state.y &&
         layout.state.bottom() <= layout.message.y;
}

} // namespace waiting_screen_layout
