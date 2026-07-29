#pragma once

#include <cstdint>

namespace destination_picker_layout {

constexpr int32_t kMinimumRowHeight = 88;
constexpr int32_t kRowGap = 4;
constexpr int32_t kTextVerticalPadding = 8;
constexpr int32_t kBasePickerPadding = 4;
constexpr int32_t kRectangularScreenInset = 16;

constexpr bool usesRoundScreenSafeArea(int32_t screenWidth,
                                       int32_t screenHeight) {
  return screenWidth == screenHeight;
}

constexpr int32_t fullScreenInset(int32_t screenWidth,
                                  int32_t screenHeight) {
  // Move interactive content away from the clipped corners of the round
  // 1.75-inch panel. The first row starts below the heading, where this inset
  // keeps both its favorite star and wrapped address text visible.
  return usesRoundScreenSafeArea(screenWidth, screenHeight)
             ? (screenWidth + 8) / 9
             : kRectangularScreenInset;
}

constexpr int32_t bottomPadding(int32_t screenWidth, int32_t screenHeight,
                                uint8_t rowCount) {
  // On the round 1.75-inch panel, the third row sits near the narrowing
  // bottom edge. Extra scroll extent lets the user move that row to the
  // screen's wide center before reading or selecting it.
  return screenWidth == screenHeight && rowCount >= 3
             ? (screenHeight * 2) / 5
             : kBasePickerPadding;
}

constexpr int32_t rowHeightForText(int32_t textHeight) {
  const int32_t wrappedHeight = textHeight + kTextVerticalPadding;
  return wrappedHeight > kMinimumRowHeight ? wrappedHeight
                                           : kMinimumRowHeight;
}

constexpr int32_t rowsContentHeight(int32_t totalRowHeight,
                                    uint8_t rowCount) {
  return totalRowHeight +
         (rowCount > 0 ? (rowCount - 1) * kRowGap : 0);
}

constexpr bool needsScrolling(int32_t totalRowHeight, uint8_t rowCount,
                              int32_t availableHeight) {
  return rowsContentHeight(totalRowHeight, rowCount) > availableHeight;
}

} // namespace destination_picker_layout
