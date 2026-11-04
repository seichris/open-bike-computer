#pragma once

#include <cstdint>
#include <string>

// What an enabled transfer session does when the owner's BLE link is lost.
//
// A map or diagnostics transfer keeps its token, authorization generation,
// listener and in-flight client for a bounded grace window instead of the
// immediate fail-closed teardown. The owner's link usually returns within
// seconds after a connection supervision timeout; under transfer load it has
// been seen to need 24 s (a first reconnect that never authenticated before
// the 12-s unauthenticated deadline, then four links shorter than 3 s). The
// window is therefore 15 s from the loss, moved to 15 s from each BLE link
// that appears while it is open, and never later than 45 s after the loss.
// Only the owner credential can authenticate, so the rebind inside the window
// is the same owner by construction, and a stray central can at most hold the
// session to that cap. The window expiring without a rebind, a mode
// replacement, an explicit exit and every other mode keep the existing
// teardown.
namespace transfer_link_grace_policy {

constexpr uint32_t graceMs = 15000;
constexpr uint32_t graceMaxMs = 45000;

// Wrap-safe "a is later than b" for millis() values that are never more than
// half the counter range apart.
inline bool isAfter(uint32_t a, uint32_t b) {
  return a != b && static_cast<uint32_t>(a - b) < UINT32_MAX / 2;
}

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

// A BLE link appearing while the window is open is the owner coming back (or
// a stray central, which the cap bounds): the deadline moves to a full window
// from that link, no later than the cap from the first loss, and never
// earlier than it already is. A link arriving once the deadline has passed,
// before the loop's expiry check ran, does not revive the window.
inline uint32_t extendedDeadlineMs(uint32_t nowMs, uint32_t lossMs,
                                   uint32_t deadlineMs) {
  if (graceExpired(nowMs, deadlineMs))
    return deadlineMs;
  const uint32_t cap = lossMs + graceMaxMs;
  uint32_t candidate = nowMs + graceMs;
  if (isAfter(candidate, cap))
    candidate = cap;
  return isAfter(candidate, deadlineMs) ? candidate : deadlineMs;
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
