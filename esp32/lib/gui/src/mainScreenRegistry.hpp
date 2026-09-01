#pragma once

#include "mainScreenTypes.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace main_screen_registry {

enum class DeviceScreenId : uint8_t {
  Map = 0,
  Navigation = 1,
  RideStats = 2,
  MapPlusNavigation = 3,
  BatteryStatus = 4,
  WorldRadio = 5,
};

struct Descriptor {
  tileName tile;
  DeviceScreenId deviceScreen;
  bool mapBacked;
  const char *debugName;
};

inline constexpr std::array<Descriptor, 6> SCREENS{{
    {MAP_GUIDANCE, DeviceScreenId::MapPlusNavigation, true,
     "map guidance"},
    {RIDESTATS, DeviceScreenId::RideStats, false, "ride telemetry"},
    {MAP, DeviceScreenId::Map, true, "map"},
    {NAV, DeviceScreenId::Navigation, false, "navigation"},
    {WORLD_RADIO, DeviceScreenId::WorldRadio, false, "world radio"},
    {BATTERY_STATUS, DeviceScreenId::BatteryStatus, false, "battery status"},
}};

constexpr uint8_t bit(DeviceScreenId id) {
  return static_cast<uint8_t>(1U << static_cast<uint8_t>(id));
}

constexpr uint8_t supportedMask() {
  uint8_t mask = 0;
  for (const Descriptor &screen : SCREENS) {
    mask = static_cast<uint8_t>(mask | bit(screen.deviceScreen));
  }
  return mask;
}

inline constexpr uint8_t SUPPORTED_MASK = supportedMask();

constexpr const Descriptor *descriptorForTile(tileName tile) {
  for (const Descriptor &screen : SCREENS) {
    if (screen.tile == tile) {
      return &screen;
    }
  }
  return nullptr;
}

constexpr const Descriptor *descriptorForDeviceScreen(uint8_t deviceScreen) {
  for (const Descriptor &screen : SCREENS) {
    if (static_cast<uint8_t>(screen.deviceScreen) == deviceScreen) {
      return &screen;
    }
  }
  return nullptr;
}

constexpr bool isMapBacked(tileName tile) {
  const Descriptor *screen = descriptorForTile(tile);
  return screen != nullptr && screen->mapBacked;
}

constexpr uint8_t deviceScreenForTile(
    tileName tile,
    DeviceScreenId fallback = DeviceScreenId::Map) {
  const Descriptor *screen = descriptorForTile(tile);
  return screen == nullptr ? static_cast<uint8_t>(fallback)
                           : static_cast<uint8_t>(screen->deviceScreen);
}

constexpr tileName tileForDeviceScreen(uint8_t deviceScreen,
                                       tileName fallback = MAP) {
  const Descriptor *screen = descriptorForDeviceScreen(deviceScreen);
  return screen == nullptr ? fallback : screen->tile;
}

constexpr bool isEnabled(tileName tile, uint8_t enabledMask) {
  const Descriptor *screen = descriptorForTile(tile);
  return screen != nullptr &&
         (enabledMask & bit(screen->deviceScreen)) != 0;
}

constexpr uint8_t normalizedMask(uint8_t mask) {
  const uint8_t supported = static_cast<uint8_t>(mask & SUPPORTED_MASK);
  return supported == 0 ? SUPPORTED_MASK : supported;
}

constexpr uint8_t normalizedDefault(uint8_t requested, uint8_t enabledMask) {
  const uint8_t normalized = normalizedMask(enabledMask);
  const Descriptor *requestedScreen = descriptorForDeviceScreen(requested);
  if (requestedScreen != nullptr &&
      (normalized & bit(requestedScreen->deviceScreen)) != 0) {
    return requested;
  }
  for (const Descriptor &screen : SCREENS) {
    if ((normalized & bit(screen.deviceScreen)) != 0) {
      return static_cast<uint8_t>(screen.deviceScreen);
    }
  }
  return static_cast<uint8_t>(DeviceScreenId::MapPlusNavigation);
}

constexpr tileName nextEnabled(tileName current, uint8_t enabledMask) {
  const uint8_t normalized = normalizedMask(enabledMask);
  std::size_t currentIndex = 0;
  for (std::size_t index = 0; index < SCREENS.size(); ++index) {
    if (SCREENS[index].tile == current) {
      currentIndex = index;
      break;
    }
  }
  for (std::size_t offset = 1; offset <= SCREENS.size(); ++offset) {
    const Descriptor &candidate =
        SCREENS[(currentIndex + offset) % SCREENS.size()];
    if ((normalized & bit(candidate.deviceScreen)) != 0) {
      return candidate.tile;
    }
  }
  return tileForDeviceScreen(normalizedDefault(
      static_cast<uint8_t>(DeviceScreenId::MapPlusNavigation), normalized));
}

constexpr bool nextEnabledMapBacked(tileName current, uint8_t enabledMask,
                                    tileName &next) {
  const uint8_t normalized = normalizedMask(enabledMask);
  std::size_t currentIndex = 0;
  for (std::size_t index = 0; index < SCREENS.size(); ++index) {
    if (SCREENS[index].tile == current) {
      currentIndex = index;
      break;
    }
  }
  for (std::size_t offset = 1; offset <= SCREENS.size(); ++offset) {
    const Descriptor &candidate =
        SCREENS[(currentIndex + offset) % SCREENS.size()];
    if (candidate.mapBacked &&
        (normalized & bit(candidate.deviceScreen)) != 0) {
      next = candidate.tile;
      return true;
    }
  }
  return false;
}

} // namespace main_screen_registry
