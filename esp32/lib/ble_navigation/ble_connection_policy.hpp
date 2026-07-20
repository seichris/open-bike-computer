#pragma once

#include <cstdint>

namespace ble_connection_policy {

constexpr uint16_t noConnection = 0xFFFF;

inline bool accepts(uint16_t activeHandle, uint16_t candidateHandle) {
  return activeHandle == noConnection || activeHandle == candidateHandle;
}

inline bool tearsDownSession(uint16_t activeHandle,
                             uint16_t disconnectedHandle) {
  return activeHandle != noConnection && activeHandle == disconnectedHandle;
}

template <typename ResetSession>
bool beginSession(uint16_t &activeHandle, uint16_t candidateHandle,
                  ResetSession resetSession) {
  if (!accepts(activeHandle, candidateHandle) || !resetSession()) {
    return false;
  }
  activeHandle = candidateHandle;
  return true;
}

template <typename ResetSession>
bool endSession(uint16_t &activeHandle, uint16_t disconnectedHandle,
                ResetSession resetSession) {
  if (!tearsDownSession(activeHandle, disconnectedHandle) ||
      !resetSession()) {
    return false;
  }
  activeHandle = noConnection;
  return true;
}

} // namespace ble_connection_policy
