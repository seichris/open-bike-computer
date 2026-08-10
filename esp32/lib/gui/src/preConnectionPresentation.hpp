#pragma once

#include <cstdint>
#include <cstdio>

namespace pre_connection_presentation {

struct Snapshot {
  bool claimed = false;
  bool connected = false;
  bool authenticated = false;
  bool pairingActive = false;
  bool pairingConfirmedOnDevice = false;
  uint32_t pairingCode = 0;
};

enum class Phase : uint8_t {
  Welcome,
  PairingComparison,
  PairingConfirmed,
  WaitingForIPhone,
  Connecting,
  GettingLocation,
};

constexpr Phase resolve(const Snapshot &snapshot) {
  if (snapshot.connected && snapshot.pairingActive) {
    return snapshot.pairingConfirmedOnDevice ? Phase::PairingConfirmed
                                             : Phase::PairingComparison;
  }
  if (snapshot.connected && snapshot.authenticated) {
    return Phase::GettingLocation;
  }
  if (snapshot.connected) {
    return Phase::Connecting;
  }
  if (snapshot.claimed) {
    return Phase::WaitingForIPhone;
  }
  return Phase::Welcome;
}

inline void formatPairingCode(uint32_t code, char (&text)[8]) {
  code %= 1000000U;
  std::snprintf(text, sizeof(text), "%03lu %03lu",
                static_cast<unsigned long>(code / 1000U),
                static_cast<unsigned long>(code % 1000U));
}

} // namespace pre_connection_presentation
