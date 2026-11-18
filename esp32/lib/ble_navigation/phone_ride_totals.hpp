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
// and keep arriving. Losing the session withdraws them at once, and a
// reconnect never revives them: only the next packet replaces them.
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

inline bool fresh(const Stamp &stamp, uint32_t nowMs,
                  uint32_t currentSessionGeneration) {
  return stamp.sessionGeneration != 0 &&
         stamp.sessionGeneration == currentSessionGeneration &&
         static_cast<uint32_t>(nowMs - stamp.receivedAtMs) < kFreshMs;
}

} // namespace phone_ride_totals
