#pragma once

#include <cstdint>

#include "../ride_automation/ride_automation_protocol.hpp"
#include "ride_ble_protocol.generated.hpp"

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

// ATT handle-value notification header: opcode plus attribute handle.
constexpr unsigned kAttNotificationHeaderBytes = 3;

constexpr NotificationChannel notificationChannel(bool nativeSubscribed,
                                                  bool navigationSubscribed,
                                                  uint16_t mtu,
                                                  unsigned payloadBytes) {
  constexpr unsigned wireOverhead =
      static_cast<unsigned>(
          ride_ble_protocol_generated::PROTECTED_FRAME_OVERHEAD) +
      kAttNotificationHeaderBytes;
  constexpr unsigned fallbackPrefix =
      static_cast<unsigned>(ride_automation_protocol::FALLBACK_PREFIX_SIZE);
  if (nativeSubscribed && mtu >= payloadBytes + wireOverhead)
    return NotificationChannel::Native;
  if (navigationSubscribed &&
      mtu >= payloadBytes + wireOverhead + fallbackPrefix)
    return NotificationChannel::Navigation;
  return NotificationChannel::None;
}

} // namespace ride_command_admission
