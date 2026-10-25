#include "mapLabelLayout.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <unordered_set>

#ifdef ARDUINO
template <typename T>
using MapLabelLayoutSet =
    std::unordered_set<T, std::hash<T>, std::equal_to<T>, PsramAllocator<T>>;
#else
template <typename T> using MapLabelLayoutSet = std::unordered_set<T>;
#endif

namespace map_label_layout {
namespace {

struct Axis {
  float x;
  float y;
};

struct Rectangle {
  float centerX;
  float centerY;
  float halfWidth;
  float halfHeight;
  Axis horizontal;
  Axis vertical;
};

Rectangle rectangle(const Option &option, float padding) {
  const float cosine = std::cos(option.angleRadians);
  const float sine = std::sin(option.angleRadians);
  return {option.centerX,
          option.centerY,
          option.width * 0.5F + padding,
          option.height * 0.5F + padding,
          {cosine, sine},
          {-sine, cosine}};
}

float projectionRadius(const Rectangle &value, Axis axis) {
  return value.halfWidth *
             std::fabs(value.horizontal.x * axis.x +
                       value.horizontal.y * axis.y) +
         value.halfHeight *
             std::fabs(value.vertical.x * axis.x + value.vertical.y * axis.y);
}

bool intersects(const Rectangle &lhs, const Rectangle &rhs) {
  const float deltaX = rhs.centerX - lhs.centerX;
  const float deltaY = rhs.centerY - lhs.centerY;
  const std::array<Axis, 4> axes = {lhs.horizontal, lhs.vertical,
                                    rhs.horizontal, rhs.vertical};
  for (const Axis axis : axes) {
    const float distance = std::fabs(deltaX * axis.x + deltaY * axis.y);
    if (distance > projectionRadius(lhs, axis) + projectionRadius(rhs, axis))
      return false;
  }
  return true;
}

bool inside(const Rectangle &value, Bounds screen) {
  const float extentX =
      std::fabs(value.horizontal.x) * value.halfWidth +
      std::fabs(value.vertical.x) * value.halfHeight;
  const float extentY =
      std::fabs(value.horizontal.y) * value.halfWidth +
      std::fabs(value.vertical.y) * value.halfHeight;
  return value.centerX - extentX >= 0 && value.centerY - extentY >= 0 &&
         value.centerX + extentX < screen.width &&
         value.centerY + extentY < screen.height;
}

} // namespace

MapLabelLayoutVector<Placement>
place(MapLabelLayoutVector<Option> options, Bounds screen, uint8_t density,
      const MapLabelLayoutVector<ReservedRegion> &reserved,
      Diagnostics *diagnostics) {
  if (diagnostics != nullptr) {
    *diagnostics = {};
    diagnostics->gathered = options.size();
  }
  if (density == 0 || screen.width <= 0 || screen.height <= 0) {
    if (diagnostics != nullptr)
      diagnostics->invalidOrDensityRejected = options.size();
    return {};
  }
  const uint8_t boundedDensity = std::min<uint8_t>(density, 3);
  const uint8_t maximumRank = boundedDensity == 1 ? 1U
                              : boundedDensity == 2 ? 4U
                                                    : 6U;
  const size_t maximumLabels = 96U;
  const float padding = boundedDensity == 1 ? 5.0F
                         : boundedDensity == 2 ? 3.0F
                                               : 1.5F;

  const size_t beforeFilter = options.size();
  options.erase(std::remove_if(options.begin(), options.end(),
                               [&](const Option &option) {
                                 return option.labelKey == 0 ||
                                        option.repeatGroup == 0 ||
                                        option.rank > maximumRank ||
                                        option.width <= 0 || option.height <= 0;
                               }),
                options.end());
  if (diagnostics != nullptr)
    diagnostics->invalidOrDensityRejected = beforeFilter - options.size();
  const float screenCenterX = screen.width * 0.5F;
  const float screenCenterY = screen.height * 0.5F;
  std::stable_sort(options.begin(), options.end(),
                   [&](const Option &lhs, const Option &rhs) {
                     if (lhs.rank != rhs.rank)
                       return lhs.rank < rhs.rank;
                     if (lhs.quality != rhs.quality)
                       return lhs.quality > rhs.quality;
                     const float lhsX = lhs.centerX - screenCenterX;
                     const float lhsY = lhs.centerY - screenCenterY;
                     const float rhsX = rhs.centerX - screenCenterX;
                     const float rhsY = rhs.centerY - screenCenterY;
                     const float lhsDistance = lhsX * lhsX + lhsY * lhsY;
                     const float rhsDistance = rhsX * rhsX + rhsY * rhsY;
                     if (lhsDistance != rhsDistance)
                       return lhsDistance < rhsDistance;
                     if (lhs.repeatGroup != rhs.repeatGroup)
                       return lhs.repeatGroup < rhs.repeatGroup;
                     if (lhs.blockOrder != rhs.blockOrder)
                       return lhs.blockOrder < rhs.blockOrder;
                     if (lhs.labelOrder != rhs.labelOrder)
                       return lhs.labelOrder < rhs.labelOrder;
                     return lhs.labelKey < rhs.labelKey;
                   });

  MapLabelLayoutVector<Placement> placements;
  MapLabelLayoutVector<Rectangle> occupied;
  MapLabelLayoutSet<uint32_t> placedLabels;
  MapLabelLayoutSet<uint16_t> placedRepeatGroups;
  placements.reserve(std::min(maximumLabels, options.size()));
  occupied.reserve(placements.capacity());
  for (const ReservedRegion &region : reserved) {
    if (region.width > 0 && region.height > 0) {
      Option value;
      value.centerX = region.centerX;
      value.centerY = region.centerY;
      value.width = region.width;
      value.height = region.height;
      occupied.push_back(rectangle(value, padding));
    }
  }
  for (size_t optionIndex = 0; optionIndex < options.size(); optionIndex++) {
    const Option &option = options[optionIndex];
    if (placements.size() >= maximumLabels) {
      if (diagnostics != nullptr)
        diagnostics->capacityRejected += options.size() - optionIndex;
      break;
    }
    if (placedLabels.count(option.labelKey) != 0 ||
        placedRepeatGroups.count(option.repeatGroup) != 0) {
      if (diagnostics != nullptr)
        diagnostics->duplicateRejected++;
      continue;
    }
    const Rectangle candidate = rectangle(option, padding);
    if (!inside(candidate, screen)) {
      if (diagnostics != nullptr)
        diagnostics->outsideScreenRejected++;
      continue;
    }
    if (diagnostics != nullptr)
      diagnostics->collisionTested++;
    if (std::any_of(occupied.begin(), occupied.end(),
                    [&](const Rectangle &existing) {
                      return intersects(candidate, existing);
                    })) {
      if (diagnostics != nullptr)
        diagnostics->collisionRejected++;
      continue;
    }
    placements.push_back({option});
    occupied.push_back(candidate);
    placedLabels.insert(option.labelKey);
    placedRepeatGroups.insert(option.repeatGroup);
  }
  if (diagnostics != nullptr)
    diagnostics->accepted = placements.size();
  return placements;
}

} // namespace map_label_layout
