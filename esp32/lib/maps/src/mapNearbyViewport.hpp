#pragma once

#include <cstdint>

namespace map_nearby_viewport {
// UI-owned transient viewport state; no storage or worker access.
struct Bookmark {
  bool active = false;
  bool follow = true;
  int32_t x = 0, y = 0;

  template <typename Point>
  void capture(bool currentFollow, const Point &center) {
    if (active) return;
    active = true;
    follow = currentFollow;
    x = center.x;
    y = center.y;
  }

  template <typename Point>
  bool restore(bool &currentFollow, Point &center) {
    if (!active) return false;
    currentFollow = follow;
    center.x = x;
    center.y = y;
    active = false;
    return true;
  }
};
} // namespace map_nearby_viewport
