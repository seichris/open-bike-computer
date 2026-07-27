#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace ride_metric_font_selection {

struct Candidate {
  int32_t width = 0;
  bool supportsText = false;
};

template <std::size_t N>
constexpr std::size_t firstFittingIndex(
    const std::array<Candidate, N> &candidates, int32_t availableWidth) {
  for (std::size_t index = 0; index < N; ++index) {
    if (candidates[index].supportsText &&
        candidates[index].width <= availableWidth) {
      return index;
    }
  }
  return N;
}

} // namespace ride_metric_font_selection
