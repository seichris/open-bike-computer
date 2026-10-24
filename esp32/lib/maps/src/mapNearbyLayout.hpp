#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace map_nearby_layout {
constexpr size_t kMaximumResults = 10;
constexpr double kPi = 3.14159265358979323846;

struct Input {
  double x = 0.0;
  double y = 0.0;
  // An off-near-plane bird's-eye point has no valid projected anchor. Its
  // ground direction is still usable for an edge marker.
  double directionX = 0.0;
  double directionY = 0.0;
  bool projected = false;
  uint8_t category = 0;
  double directDistanceM = 0.0;
};

struct Placement {
  double x = 0.0;
  double y = 0.0;
  uint16_t members = 0;
  double nearestDistanceM = 0.0;
  uint8_t category = 0; // zero means mixed categories
  uint8_t count = 0;
  bool edge = false;
  double directionX = 0.0;
  double directionY = -1.0;
};

struct Layout {
  std::array<Placement, kMaximumResults> placements{};
  std::array<bool, kMaximumResults> onMap{};
  size_t count = 0;
};

// Results arrive nearest-first. A mixed group keeps its category=0 marker for
// chooser semantics, but still needs a recognizable icon on the map.
inline uint8_t displayCategory(const Placement &placement,
                               const Input *inputs, size_t inputCount) {
  if (placement.category >= 1 && placement.category <= 5)
    return placement.category;
  if (inputs == nullptr || inputCount > kMaximumResults) return 0;
  for (size_t index = 0; index < inputCount; ++index) {
    if ((placement.members & (1U << index)) != 0 &&
        inputs[index].category >= 1 && inputs[index].category <= 5)
      return inputs[index].category;
  }
  return 0;
}

// Preserve the current unit through ordinary GPS noise near one kilometre.
// The caller owns the per-result bit and carries it across result refreshes.
inline bool formatDirectDistance(double meters, bool &kilometres,
                                 char *buffer, size_t capacity) {
  if (buffer == nullptr || capacity == 0) return false;
  if (!std::isfinite(meters) || meters < 0.0) {
    const int written = std::snprintf(buffer, capacity, "--");
    return written >= 0 && static_cast<size_t>(written) < capacity;
  }
  if (kilometres) {
    if (meters < 950.0) kilometres = false;
  } else if (meters > 1050.0) {
    kilometres = true;
  }
  const int written = kilometres
      ? std::snprintf(buffer, capacity, "%.1f km",
                      std::round(meters / 100.0) / 10.0)
      : std::snprintf(buffer, capacity, "%.0f m",
                      std::round(meters / 10.0) * 10.0);
  return written >= 0 && static_cast<size_t>(written) < capacity;
}

inline bool pinFits(double x, double y, double width, double height,
                    bool round, double topInset, double bottomInset,
                    bool wasOnMap) {
  if (!std::isfinite(x) || !std::isfinite(y)) return false;
  const double margin = wasOnMap ? 21.0 : 29.0;
  if (x < margin || x > width - margin ||
      y < topInset + margin || y > height - bottomInset - margin)
    return false;
  if (!round) return true;
  const double dx = x - width / 2.0;
  const double dy = y - height / 2.0;
  const double radius = std::min(width, height) / 2.0 - margin;
  return dx * dx + dy * dy <= radius * radius;
}

inline Layout arrange(const Input *inputs, size_t inputCount, double width,
                      double height, bool round, double topInset,
                      double bottomInset,
                      const std::array<bool, kMaximumResults> &wasOnMap = {}) {
  Layout layout;
  if (inputs == nullptr || inputCount > kMaximumResults ||
      !std::isfinite(width) || !std::isfinite(height) || width < 150.0 ||
      height < 150.0 || topInset < 0.0 || bottomInset < 0.0 ||
      topInset + bottomInset > height - 100.0)
    return layout;
  const double centerX = width / 2.0;
  const double centerY = (topInset + height - bottomInset) / 2.0;
  const double halfWidth = width / 2.0 - 49.0;
  const double halfHeight = (height - topInset - bottomInset) / 2.0 - 39.0;
  const double roundRadius = std::min(width, height) / 2.0 - 60.0;
  if (halfWidth <= 0.0 || halfHeight <= 0.0 ||
      (round && roundRadius <= 0.0)) return layout;

  for (size_t index = 0; index < inputCount; ++index) {
    const Input &input = inputs[index];
    if (input.category < 1 || input.category > 5 ||
        !std::isfinite(input.directDistanceM) ||
        input.directDistanceM < 0.0) continue;
    const bool onMap = input.projected &&
        pinFits(input.x, input.y, width, height, round, topInset,
                bottomInset, wasOnMap[index]);
    layout.onMap[index] = onMap;
    double x = input.x;
    double y = input.y;
    if (!onMap) {
      double dx = input.projected ? input.x - centerX : input.directionX;
      double dy = input.projected ? input.y - centerY : input.directionY;
      if (!std::isfinite(dx) || !std::isfinite(dy) ||
          (std::fabs(dx) < 1e-9 && std::fabs(dy) < 1e-9)) {
        dx = 0.0;
        dy = -1.0;
      }
      double scale = round
          ? roundRadius / std::hypot(dx, dy)
          : std::min(halfWidth / std::max(1e-9, std::fabs(dx)),
                     halfHeight / std::max(1e-9, std::fabs(dy)));
      x = centerX + dx * scale;
      y = centerY + dy * scale;
      // The physical round clip and the reserved control bands both apply.
      x = std::clamp(x, 49.0, width - 49.0);
      y = std::clamp(y, topInset + 39.0, height - bottomInset - 39.0);
    }

    double directionX = input.directionX;
    double directionY = input.directionY;
    if (input.projected && (!std::isfinite(directionX) ||
        !std::isfinite(directionY) || std::hypot(directionX, directionY) < 1e-9)) {
      directionX = input.x - width / 2.0;
      directionY = input.y - height / 2.0;
    }
    const double length = std::hypot(directionX, directionY);
    if (!std::isfinite(length) || length < 1e-9) {
      directionX = 0.0;
      directionY = -1.0;
    } else {
      directionX /= length;
      directionY /= length;
    }
    layout.placements[layout.count++] = {
        x, y, static_cast<uint16_t>(1U << index), input.directDistanceM,
        input.category, 1, !onMap, directionX, directionY};
  }

  // Mixed pin/edge footprints also collide. Merge to a fixed point because
  // promoting a pin group to an edge marker enlarges/moves its footprint.
  // At most nine merges are possible. Nearest-first metadata and true bearing
  // remain those of the nearest member, not of the clamped/grouped anchor.
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t first = 0; first < layout.count && !changed; ++first) {
      auto &group = layout.placements[first];
      for (size_t second = first + 1; second < layout.count; ++second) {
        const auto &other = layout.placements[second];
        const double widthSum = (group.edge ? 80.0 : 44.0) +
                                (other.edge ? 80.0 : 44.0);
        const double heightSum = (group.edge ? 68.0 : 44.0) +
                                 (other.edge ? 68.0 : 44.0);
        if (std::fabs(group.x - other.x) * 2.0 >= widthSum ||
            std::fabs(group.y - other.y) * 2.0 >= heightSum) continue;
        if (!group.edge && other.edge) {
          group.x = other.x;
          group.y = other.y;
          group.edge = true;
        }
        group.members |= other.members;
        group.count += other.count;
        if (group.category != other.category) group.category = 0;
        for (size_t item = second + 1; item < layout.count; ++item)
          layout.placements[item - 1] = layout.placements[item];
        --layout.count;
        changed = true;
        break;
      }
    }
  }
  return layout;
}
} // namespace map_nearby_layout
