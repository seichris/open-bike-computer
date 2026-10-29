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

// How long an unauthenticated client may hold the single link: the pairing
// comparison's lifetime while a code is open, otherwise a short window for
// authentication. The window starts when the link is accepted and again when
// the client registers ownership on it. CONFIRM succeeds only after the
// physical BOOT press, and the new owner still has to send OWNER and PROOF, so
// a slow human confirmation must not consume that window.
constexpr uint32_t pairingUnauthenticatedLimitMs = 120000;
constexpr uint32_t unauthenticatedLimitMs = 12000;

// Unsigned subtraction keeps the comparison correct across millis() wrap.
inline bool unauthenticatedDeadlinePassed(uint32_t nowMs, uint32_t windowStartMs,
                                          bool pairingActive) {
  return nowMs - windowStartMs > (pairingActive ? pairingUnauthenticatedLimitMs
                                                : unauthenticatedLimitMs);
}

} // namespace ble_connection_policy
