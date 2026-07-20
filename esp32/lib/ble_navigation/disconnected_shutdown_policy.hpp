#pragma once

#include <cstdint>

namespace disconnected_shutdown_policy {

constexpr uint32_t registrationGraceSeconds = 10 * 60;

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
};

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
  UpdateResult update(uint32_t nowMs, bool connected,
                      uint32_t configuredTimeoutSeconds,
                      bool ownershipClaimed) {
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
