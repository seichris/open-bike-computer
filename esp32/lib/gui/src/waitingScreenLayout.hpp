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
  bool round;
  Rect battery;
  Rect fullBrand;
  Rect compactBrand;
  Rect welcomeHeadline;
  Rect qr;
  Rect welcomeCopy;
  Rect pairingHeadline;
  Rect pairingCode;
  Rect pairingCopy;
  Rect statusHero;
  Rect statusHeadline;
  Rect statusCopy;
};

// Reviewed against LVGL 9.2's Montserrat 38 font. Keep a small horizontal
// margin so these one-line labels cannot silently wrap into their fixed-height
// boxes on either display profile.
constexpr int16_t kConfirmCodeTextWidth = 346;
constexpr int16_t kWaitingForIPhoneTextWidth = 368;
constexpr int16_t kHeadlineHorizontalMargin = 12;

constexpr int16_t centeredX(int16_t screenWidth, int16_t width) {
  return static_cast<int16_t>((screenWidth - width) / 2);
}

constexpr Layout makeLayout(int16_t width, int16_t height) {
  if (width == 466 && height == 466) {
    return {width,
            height,
            true,
            {158, 28, 150, 34},
            {143, 76, 180, 40},
            {153, 76, 160, 38},
            {73, 122, 320, 48},
            {150, 174, 165, 165},
            {98, 350, 270, 56},
            {43, 126, 380, 48},
            {83, 190, 300, 62},
            {63, 286, 340, 64},
            {177, 144, 112, 112},
            {43, 276, 380, 52},
            {88, 340, 290, 64}};
  }

  return {width,
          height,
          false,
          {centeredX(width, 170), 28, 170, 34},
          {centeredX(width, 190), 78, 190, 40},
          {centeredX(width, 170), 82, 170, 38},
          {24, 130, static_cast<int16_t>(width - 48), 48},
          {centeredX(width, 165), 182, 165, 165},
          {35, 366, static_cast<int16_t>(width - 70), 66},
          {12, 148, static_cast<int16_t>(width - 24), 48},
          {35, 214, static_cast<int16_t>(width - 70), 62},
          {24, 300, static_cast<int16_t>(width - 48), 64},
          {centeredX(width, 112), 150, 112, 112},
          {12, 286, static_cast<int16_t>(width - 24), 52},
          {24, 350, static_cast<int16_t>(width - 48), 64}};
}

constexpr bool fits(const Rect &rect, int16_t width, int16_t height) {
  return rect.x >= 0 && rect.y >= 0 && rect.right() <= width &&
         rect.bottom() <= height;
}

constexpr bool cornersFitCircle(const Rect &rect, int16_t diameter,
                                int16_t inset = 8) {
  const int32_t center = diameter / 2;
  const int32_t radius = center - inset;
  const int32_t left = rect.x - center;
  const int32_t right = rect.right() - center;
  const int32_t top = rect.y - center;
  const int32_t bottom = rect.bottom() - center;
  const int32_t radiusSquared = radius * radius;
  return left * left + top * top <= radiusSquared &&
         right * right + top * top <= radiusSquared &&
         left * left + bottom * bottom <= radiusSquared &&
         right * right + bottom * bottom <= radiusSquared;
}

constexpr bool isValid(const Layout &layout) {
  return fits(layout.battery, layout.screenWidth, layout.screenHeight) &&
         fits(layout.fullBrand, layout.screenWidth, layout.screenHeight) &&
         fits(layout.compactBrand, layout.screenWidth, layout.screenHeight) &&
         fits(layout.welcomeHeadline, layout.screenWidth,
              layout.screenHeight) &&
         fits(layout.qr, layout.screenWidth, layout.screenHeight) &&
         fits(layout.welcomeCopy, layout.screenWidth, layout.screenHeight) &&
         fits(layout.pairingHeadline, layout.screenWidth,
              layout.screenHeight) &&
         fits(layout.pairingCode, layout.screenWidth, layout.screenHeight) &&
         fits(layout.pairingCopy, layout.screenWidth, layout.screenHeight) &&
         fits(layout.statusHero, layout.screenWidth, layout.screenHeight) &&
         fits(layout.statusHeadline, layout.screenWidth,
              layout.screenHeight) &&
         fits(layout.statusCopy, layout.screenWidth, layout.screenHeight) &&
         layout.battery.bottom() <= layout.fullBrand.y &&
         layout.battery.bottom() <= layout.compactBrand.y &&
         layout.fullBrand.bottom() <= layout.welcomeHeadline.y &&
         layout.welcomeHeadline.bottom() <= layout.qr.y &&
         layout.qr.bottom() <= layout.welcomeCopy.y &&
         layout.compactBrand.bottom() <= layout.pairingHeadline.y &&
         layout.pairingHeadline.bottom() <= layout.pairingCode.y &&
         layout.pairingCode.bottom() <= layout.pairingCopy.y &&
         layout.compactBrand.bottom() <= layout.statusHero.y &&
         layout.statusHero.bottom() <= layout.statusHeadline.y &&
         layout.statusHeadline.bottom() <= layout.statusCopy.y &&
         layout.pairingHeadline.width >=
             kConfirmCodeTextWidth + kHeadlineHorizontalMargin &&
         layout.statusHeadline.width >=
             kWaitingForIPhoneTextWidth + kHeadlineHorizontalMargin;
}

constexpr bool roundOpaqueContentIsSafe(const Layout &layout) {
  return !layout.round ||
         (cornersFitCircle(layout.battery, layout.screenWidth) &&
          cornersFitCircle(layout.fullBrand, layout.screenWidth) &&
          cornersFitCircle(layout.compactBrand, layout.screenWidth) &&
          cornersFitCircle(layout.welcomeHeadline, layout.screenWidth) &&
          cornersFitCircle(layout.qr, layout.screenWidth) &&
          cornersFitCircle(layout.welcomeCopy, layout.screenWidth) &&
          cornersFitCircle(layout.pairingHeadline, layout.screenWidth) &&
          cornersFitCircle(layout.pairingCode, layout.screenWidth) &&
          cornersFitCircle(layout.pairingCopy, layout.screenWidth) &&
          cornersFitCircle(layout.statusHero, layout.screenWidth) &&
          cornersFitCircle(layout.statusHeadline, layout.screenWidth) &&
          cornersFitCircle(layout.statusCopy, layout.screenWidth));
}

} // namespace waiting_screen_layout
