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

enum class Group : uint8_t {
  Welcome,
  Pairing,
  Status,
};

enum class Artwork : uint8_t {
  PairingConfirmed,
  WaitingForIPhone,
  Connecting,
  GettingLocation,
  None = UINT8_MAX,
};

struct Content {
  Group group;
  Artwork artwork;
  const char *headline;
  const char *copy;
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

constexpr Content content(Phase phase) {
  switch (phase) {
  case Phase::Welcome:
    return {Group::Welcome, Artwork::None, "Welcome",
            "Download the Bicino app\nand add your new device!"};
  case Phase::PairingComparison:
    return {Group::Pairing, Artwork::None, "Confirm this code",
            "If it matches your iPhone,\npress either device button."};
  case Phase::PairingConfirmed:
    return {Group::Status, Artwork::PairingConfirmed, "Confirmed here",
            "Tap Codes Match\non your iPhone."};
  case Phase::WaitingForIPhone:
    return {Group::Status, Artwork::WaitingForIPhone, "Waiting for iPhone",
            "Open Bicino on your iPhone."};
  case Phase::Connecting:
    return {Group::Status, Artwork::Connecting, "Connecting...",
            "Creating a secure connection."};
  case Phase::GettingLocation:
    return {Group::Status, Artwork::GettingLocation, "iPhone connected",
            "Getting your location..."};
  }
  return {Group::Welcome, Artwork::None, "", ""};
}

constexpr bool needsUpdate(bool hasDisplayedPhase, Phase displayedPhase,
                           uint32_t displayedPairingCode, Phase nextPhase,
                           uint32_t nextPairingCode) {
  return !hasDisplayedPhase || displayedPhase != nextPhase ||
         (nextPhase == Phase::PairingComparison &&
          displayedPairingCode != nextPairingCode);
}

constexpr bool isVisibleComparisonFrame(bool waitingScreenActive,
                                        Phase displayedPhase) {
  return waitingScreenActive && displayedPhase == Phase::PairingComparison;
}

// Keep the physical comparison gate behind presentation. Firmware supplies
// the critical-section callbacks; host tests verify the ordering and every
// phase's request/cancel decision without depending on LVGL or FreeRTOS.
template <typename Present, typename RequestGate, typename CancelGate>
void presentThenUpdateComparisonGate(const Snapshot &snapshot,
                                     uint32_t pairingGeneration,
                                     Present present, RequestGate requestGate,
                                     CancelGate cancelGate) {
  const Phase phase = resolve(snapshot);
  present(snapshot, phase);
  if (phase == Phase::PairingComparison) {
    requestGate(pairingGeneration);
  } else {
    cancelGate();
  }
}

inline void formatPairingCode(uint32_t code, char (&text)[8]) {
  code %= 1000000U;
  std::snprintf(text, sizeof(text), "%03lu %03lu",
                static_cast<unsigned long>(code / 1000U),
                static_cast<unsigned long>(code % 1000U));
}

} // namespace pre_connection_presentation
