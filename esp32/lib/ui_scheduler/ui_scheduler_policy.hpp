#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>

namespace ui_scheduler {

constexpr uint32_t kConnectedNavigationMaximumWaitMs = 50;
constexpr uint32_t kStaticMaximumWaitMs = 250;
constexpr uint32_t kNoDeadline = std::numeric_limits<uint32_t>::max();

enum class WakeReason : uint32_t {
  None = 0,
  Ble = 1u << 0,
  Touch = 1u << 1,
  Boot = 1u << 2,
  Display = 1u << 3,
  Transfer = 1u << 4,
  Audio = 1u << 5,
};

constexpr uint32_t reasonBits(WakeReason reason) {
  return static_cast<uint32_t>(reason);
}

constexpr bool hasReason(uint32_t reasons, WakeReason reason) {
  return (reasons & reasonBits(reason)) != 0;
}

struct DeadlineContext {
  uint32_t lvglDelayMs = kNoDeadline;
  uint32_t housekeepingDelayMs = kNoDeadline;
  bool connectedNavigation = false;
  bool lvglBlocked = false;
  bool displayOff = false;
};

constexpr uint32_t elapsedMs(uint32_t nowMs, uint32_t sinceMs) {
  return nowMs - sinceMs;
}

constexpr uint32_t remainingUntil(uint32_t nowMs, uint32_t lastRunMs,
                                  uint32_t periodMs) {
  const uint32_t elapsed = elapsedMs(nowMs, lastRunMs);
  return elapsed >= periodMs ? 0 : periodMs - elapsed;
}

constexpr bool isDue(uint32_t nowMs, uint32_t lastRunMs, uint32_t periodMs) {
  return remainingUntil(nowMs, lastRunMs, periodMs) == 0;
}

constexpr bool shouldRunForReason(uint32_t reasons, WakeReason reason,
                                  uint32_t nowMs, uint32_t lastRunMs,
                                  uint32_t periodMs) {
  return hasReason(reasons, reason) ||
         isDue(nowMs, lastRunMs, periodMs);
}

constexpr uint32_t nextWaitMs(const DeadlineContext &context) {
  uint32_t waitMs = context.connectedNavigation
                        ? kConnectedNavigationMaximumWaitMs
                        : kStaticMaximumWaitMs;
  if (!context.displayOff && !context.lvglBlocked) {
    waitMs = std::min(waitMs, context.lvglDelayMs);
  }
  waitMs = std::min(waitMs, context.housekeepingDelayMs);
  return waitMs;
}

} // namespace ui_scheduler
