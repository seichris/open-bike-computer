#pragma once

#include <cstdint>

namespace navigation_content_mode {

enum class Mode : uint8_t {
  FavoriteDestinations,
  ActiveGuidance,
};

constexpr Mode forNavigationState(bool hasNavigationData) {
  return hasNavigationData ? Mode::ActiveGuidance
                           : Mode::FavoriteDestinations;
}

} // namespace navigation_content_mode
