#pragma once
#include <cstddef>

namespace full_frame_allocation {
struct Buffers {
  void *draw = nullptr;
  void *rotation = nullptr;
  size_t bytes = 0;
  bool ready() const { return draw != nullptr; }
};

// Admission is all-or-nothing. FULL refresh never accepts a partial buffer or
// consumes scarce internal RAM as a fallback for a missing PSRAM frame.
template <typename Allocate, typename Release>
Buffers reserve(size_t pixels, bool rotate, Allocate allocate, Release release) {
  if (pixels == 0 || pixels > static_cast<size_t>(-1) / 2)
    return {};
  const size_t bytes = pixels * 2;
  void *draw = allocate(bytes);
  if (draw == nullptr)
    return {};
  void *rotation = rotate ? allocate(bytes) : nullptr;
  if (rotate && rotation == nullptr) {
    release(draw);
    return {};
  }
  return {draw, rotation, bytes};
}
} // namespace full_frame_allocation
