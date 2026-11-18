#pragma once

#include <cstdint>

// Freshness of the ride totals (distance travelled, elapsed time and route
// remaining) that only the phone or Watch supplies, in its GPS packets.
//
// The totals must not borrow the position's freshness. On a board with its
// own receiver the position stays fresh after the phone is gone, so frozen
// phone totals looked live (GNSS bench, 2026-11-18). Totals are live only
// while they come from the current ride payload generation (one per
// authenticated controller lease; it advances when the link or lease ends)
// and that session stays alive: a packet, or a confirmed ride-lease renewal
// after the packet, within kFreshMs. Losing the session withdraws them at
// once, and a reconnect never revives them: only the next packet replaces
// them.
//
// The lease renewal matters for the Watch. It sends GPS only when it moves
// but renews its ride lease every five seconds, so a rider waiting at a light
// keeps their last totals and Route Left, as before. When renewals stop the
// lease itself expires after fifteen seconds.
namespace phone_ride_totals {

// The phone sends GPS about once a second while navigating. Allow for the
// gaps a critical-command acknowledgement wait or a Core Location stall
// leaves (up to about nine seconds on the 2026-11-18 bench) without letting
// a stopped stream look live for long.
constexpr uint32_t kFreshMs = 10'000;

struct Stamp {
  uint32_t receivedAtMs = 0;
  // Ride payload generation of the packet; zero means no packet yet.
  uint32_t sessionGeneration = 0;
};

inline Stamp received(uint32_t nowMs, uint32_t sessionGeneration) {
  return {nowMs, sessionGeneration};
}

// Time from `thenMs` to `nowMs` across the 32-bit wrap. A timestamp up to a
// second ahead (written after `nowMs` was read) counts as zero elapsed;
// anything older, even beyond 2^31 ms, is plain elapsed time.
inline uint32_t elapsedMs(uint32_t nowMs, uint32_t thenMs) {
  const uint32_t raw = nowMs - thenMs;
  return raw > UINT32_MAX - 1'000U ? 0U : raw;
}

// `leaseRenewedAtMs` is the last confirmed ride-lease renewal of the
// connected controller, or zero for none. It counts only when it follows the
// packet, so a renewal from before the totals cannot extend them.
inline bool fresh(const Stamp &stamp, uint32_t nowMs,
                  uint32_t currentSessionGeneration,
                  uint32_t leaseRenewedAtMs = 0) {
  if (stamp.sessionGeneration == 0 ||
      stamp.sessionGeneration != currentSessionGeneration)
    return false;
  if (elapsedMs(nowMs, stamp.receivedAtMs) < kFreshMs)
    return true;
  const bool renewedAfterPacket =
      leaseRenewedAtMs != 0 &&
      static_cast<int32_t>(leaseRenewedAtMs - stamp.receivedAtMs) >= 0;
  return renewedAfterPacket &&
         elapsedMs(nowMs, leaseRenewedAtMs) < kFreshMs;
}

} // namespace phone_ride_totals
