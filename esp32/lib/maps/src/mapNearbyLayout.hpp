#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

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
};

struct Layout {
  std::array<Placement, kMaximumResults> placements{};
  std::array<bool, kMaximumResults> onMap{};
  size_t count = 0;
};

inline bool pinFits(double x, double y, double width, double height,
                    bool round, double topInset, double bottomInset,
                    bool wasOnMap) {
  if (!std::isfinite(x) || !std::isfinite(y)) return false;
  const double margin = wasOnMap ? 15.0 : 23.0;
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
  const double halfHeight = (height - topInset - bottomInset) / 2.0 - 35.0;
  const double roundRadius = std::min(width, height) / 2.0 - 56.0;
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
      y = std::clamp(y, topInset + 35.0, height - bottomInset - 35.0);
    }

    // The search supplies nearest-first input. Co-located pins and close
    // edge anchors share one deterministic group, preserving all ten members.
    size_t group = layout.count;
    for (size_t candidate = 0; candidate < layout.count; ++candidate) {
      const Placement &placed = layout.placements[candidate];
      if (placed.edge != !onMap) continue;
      const double deltaX = placed.x - x;
      const double deltaY = placed.y - y;
      const bool collides = onMap
          ? std::fabs(deltaX) < 30.0 && std::fabs(deltaY) < 30.0
          : std::fabs(deltaX) < 76.0 && std::fabs(deltaY) < 56.0;
      if (collides) {
        group = candidate;
        break;
      }
    }
    if (group == layout.count) {
      if (layout.count >= layout.placements.size()) continue;
      layout.placements[group] = {
          x, y, static_cast<uint16_t>(1U << index), input.directDistanceM,
          input.category, 1, !onMap};
      ++layout.count;
    } else {
      Placement &placed = layout.placements[group];
      placed.members |= static_cast<uint16_t>(1U << index);
      placed.category = placed.category == input.category ? placed.category : 0;
      ++placed.count;
    }
  }
  return layout;
}
} // namespace map_nearby_layout
