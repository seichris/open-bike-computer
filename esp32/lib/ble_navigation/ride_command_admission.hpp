#pragma once

#include <cstdint>

namespace ride_command_admission {

// Handshake decoding is the only entry point that may accept plaintext. Every
// feature callback uses the protected entry point, including multiplexed frames.
constexpr bool mayDecode(bool handshake, bool ownershipReady,
                         bool transportAuthenticated,
                         bool ownershipAuthenticated) {
  return handshake || (ownershipReady && transportAuthenticated &&
                       ownershipAuthenticated);
}

struct Authorization {
  uint32_t sessionGeneration = 0;
  uint32_t leaseGeneration = 0;
};

constexpr bool mayApply(Authorization admitted, Authorization current,
                        bool authenticated) {
  return authenticated && admitted.sessionGeneration != 0 &&
         admitted.leaseGeneration != 0 &&
         admitted.sessionGeneration == current.sessionGeneration &&
         admitted.leaseGeneration == current.leaseGeneration;
}

enum class NotificationChannel { None, Native, Navigation };

constexpr NotificationChannel notificationChannel(bool nativeSubscribed,
                                                  bool navigationSubscribed,
                                                  uint16_t mtu,
                                                  unsigned payloadBytes) {
  constexpr unsigned wireOverhead = 22 + 3; // protected envelope + ATT header
  if (nativeSubscribed && mtu >= payloadBytes + wireOverhead)
    return NotificationChannel::Native;
  if (navigationSubscribed && mtu >= payloadBytes + wireOverhead + 4)
    return NotificationChannel::Navigation;
  return NotificationChannel::None;
}

} // namespace ride_command_admission
