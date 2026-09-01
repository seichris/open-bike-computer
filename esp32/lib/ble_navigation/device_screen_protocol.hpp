#pragma once

#include <cstdint>

namespace device_screen_protocol {

// Bit 30 marks the current protocol. Unmarked values predate extension
// screens; preserve the firmware's current extension selection when those
// clients send their four-screen mask.
constexpr int32_t CURRENT_MASK_MARKER = 1 << 30;
constexpr int32_t BATTERY_STATUS_BIT = 1 << 4;
constexpr int32_t WORLD_RADIO_BIT = 1 << 5;
constexpr int32_t EXTENSION_SCREEN_BITS =
    BATTERY_STATUS_BIT | WORLD_RADIO_BIT;

inline int32_t applyCompatibility(int32_t incomingMask,
                                  uint8_t currentMask) {
  const bool currentProtocol = (incomingMask & CURRENT_MASK_MARKER) != 0;
  int32_t requestedMask = incomingMask & ~CURRENT_MASK_MARKER;
  if (!currentProtocol) {
    requestedMask = (requestedMask & ~EXTENSION_SCREEN_BITS) |
                    (currentMask & EXTENSION_SCREEN_BITS);
  }
  return requestedMask;
}

} // namespace device_screen_protocol
