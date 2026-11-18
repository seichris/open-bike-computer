#pragma once

#include <cstdint>

namespace disconnected_shutdown_policy {

constexpr uint32_t registrationGraceSeconds = 10 * 60;
// After the last confirmed movement a GNSS board stays awake for at least
// this long (or the configured timeout, if longer) before it may sleep, so a
// phone-off ride survives a stop at a light or a café but a parked board
// still powers down (docs/firmware-power-management.md).
constexpr uint32_t motionHoldSeconds = 5 * 60;

enum class Action : uint8_t {
  None,
  CountdownStarted,
  ShutdownDue,
  ShutdownRetry,
};

struct UpdateResult {
  Action action = Action::None;
  uint32_t timeoutSeconds = 0;
  bool waitingForRegistration = false;
  // The countdown has run out, but recent standalone movement holds the
  // board awake.
  bool heldByMotion = false;
};

// Standalone movement confirmed by the board's own receiver
// (gnss_motion_policy.hpp). Boards without one pass the default, which never
// holds, so their behaviour is unchanged.
struct MotionHold {
  bool moving = false;
  // Movement was confirmed at least once, so lastMovementMs is meaningful.
  bool moved = false;
  uint32_t lastMovementMs = 0;
};

inline bool motionHolds(const MotionHold &motion, uint32_t nowMs,
                        uint32_t timeoutSeconds) {
  if (motion.moving)
    return true;
  if (!motion.moved)
    return false;
  const uint32_t holdSeconds =
      timeoutSeconds > motionHoldSeconds ? timeoutSeconds : motionHoldSeconds;
  // A movement time up to a second after nowMs (same loop pass) is zero
  // elapsed rather than a wrapped age; anything older is plain elapsed time,
  // so a movement weeks ago never holds the board awake.
  const uint32_t raw = nowMs - motion.lastMovementMs;
  const uint32_t elapsed = raw > UINT32_MAX - 1'000U ? 0U : raw;
  return static_cast<uint64_t>(elapsed) <
         static_cast<uint64_t>(holdSeconds) * 1000ULL;
}

inline uint32_t effectiveTimeoutSeconds(uint32_t configuredTimeoutSeconds,
                                        bool ownershipClaimed) {
  if (configuredTimeoutSeconds == 0 || ownershipClaimed ||
      configuredTimeoutSeconds >= registrationGraceSeconds) {
    return configuredTimeoutSeconds;
  }
  return registrationGraceSeconds;
}

class Tracker {
public:
  // "Never" (a zero timeout) and a connection always win. Otherwise a
  // shutdown is due once the board has been disconnected for the timeout
  // and, if it moved, at least max(timeout, motionHoldSeconds) has passed
  // since its last movement. An announced shutdown is never withdrawn.
  UpdateResult update(uint32_t nowMs, bool connected,
                      uint32_t configuredTimeoutSeconds,
                      bool ownershipClaimed,
                      const MotionHold &motion = {}) {
    const uint32_t timeoutSeconds = effectiveTimeoutSeconds(
        configuredTimeoutSeconds, ownershipClaimed);
    const bool waitingForRegistration = !ownershipClaimed;

    if (connected || timeoutSeconds == 0) {
      reset();
      return {Action::None, timeoutSeconds, waitingForRegistration};
    }

    if (!counting_ || timeoutSeconds != activeTimeoutSeconds_ ||
        ownershipClaimed != activeOwnershipClaimed_) {
      counting_ = true;
      countdownStartedMs_ = nowMs;
      activeTimeoutSeconds_ = timeoutSeconds;
      activeOwnershipClaimed_ = ownershipClaimed;
      shutdownAnnounced_ = false;
      return {Action::CountdownStarted, timeoutSeconds,
              waitingForRegistration};
    }

    const uint32_t elapsedMs = nowMs - countdownStartedMs_;
    const uint64_t deadlineMs =
        static_cast<uint64_t>(timeoutSeconds) * 1000ULL;
    if (static_cast<uint64_t>(elapsedMs) < deadlineMs) {
      return {Action::None, timeoutSeconds, waitingForRegistration};
    }

    if (!shutdownAnnounced_ && motionHolds(motion, nowMs, timeoutSeconds)) {
      UpdateResult held{Action::None, timeoutSeconds, waitingForRegistration};
      held.heldByMotion = true;
      return held;
    }

    if (!shutdownAnnounced_) {
      shutdownAnnounced_ = true;
      return {Action::ShutdownDue, timeoutSeconds, waitingForRegistration};
    }
    return {Action::ShutdownRetry, timeoutSeconds, waitingForRegistration};
  }

private:
  void reset() {
    counting_ = false;
    countdownStartedMs_ = 0;
    activeTimeoutSeconds_ = 0;
    activeOwnershipClaimed_ = false;
    shutdownAnnounced_ = false;
  }

  bool counting_ = false;
  uint32_t countdownStartedMs_ = 0;
  uint32_t activeTimeoutSeconds_ = 0;
  bool activeOwnershipClaimed_ = false;
  bool shutdownAnnounced_ = false;
};

} // namespace disconnected_shutdown_policy
