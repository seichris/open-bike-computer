#pragma once

#include <cstdint>
#include <string>

// What an enabled transfer session does when the owner's BLE link is lost.
//
// A map or diagnostics transfer keeps its token, authorization generation,
// listener and in-flight client for a short grace window instead of the
// immediate fail-closed teardown. The owner's link returns within seconds
// after a connection supervision timeout and only the owner credential can
// authenticate, so the rebind inside the window is the same owner by
// construction. The window expiring without a rebind, a mode replacement, an
// explicit exit and every other mode keep the existing teardown.
namespace transfer_link_grace_policy {

constexpr uint32_t graceMs = 15000;

inline bool modeKeepsSessionAcrossLinkLoss(const std::string &mode) {
  return mode == "map" || mode == "diagnostics";
}

// Whether a lost link opens the grace window: only the authenticated owner's
// own link, lost without the firmware asking for it (an unauthenticated
// deadline, an ownership revocation or a maintenance teardown are not link
// losses). Firmware maintenance has its own suspend path and a commit
// boundary must never be interrupted.
inline bool startsGrace(bool enabled, uint64_t boundSessionId,
                        bool commitActive, bool maintenanceActive,
                        const std::string &mode, bool linkWasAuthenticated,
                        bool firmwareRequested) {
  return enabled && boundSessionId != 0 && !commitActive &&
         !maintenanceActive && linkWasAuthenticated && !firmwareRequested &&
         modeKeepsSessionAcrossLinkLoss(mode);
}

enum class LinkLoss : uint8_t {
  TearDown = 0,   // the existing fail-closed teardown runs now
  Started = 1,    // a new window opened with the full grace
  Continuing = 2, // a window is already open: it keeps its deadline
};

// A later disconnect during an open window (a stray central, or the owner
// dropping again before authenticating) must neither restart the window nor
// tear the session down; the original deadline decides.
inline LinkLoss linkLoss(bool graceActive, bool starts) {
  if (graceActive)
    return LinkLoss::Continuing;
  return starts ? LinkLoss::Started : LinkLoss::TearDown;
}

// Unsigned subtraction keeps the comparison correct across millis() wrap: the
// window is far shorter than half the counter range.
inline bool graceExpired(uint32_t nowMs, uint32_t deadlineMs) {
  return static_cast<uint32_t>(nowMs - deadlineMs) < UINT32_MAX / 2;
}

enum class Rebind : uint8_t {
  Reject = 0, // a different session while a live binding exists
  Keep = 1,   // the bound session itself
  Adopt = 2,  // the owner back inside the grace window: token and generation stay
  Rotate = 3, // a new binding: fresh token when enabled, new generation
};

inline Rebind rebind(bool enabled, bool graceActive, uint64_t boundSessionId,
                     uint64_t newSessionId) {
  if (newSessionId == 0)
    return Rebind::Reject;
  if (boundSessionId == newSessionId)
    return Rebind::Keep;
  if (graceActive)
    return Rebind::Adopt;
  if (enabled && boundSessionId != 0)
    return Rebind::Reject;
  return Rebind::Rotate;
}

} // namespace transfer_link_grace_policy
