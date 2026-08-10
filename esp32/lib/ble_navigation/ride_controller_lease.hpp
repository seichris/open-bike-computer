#pragma once

#include <cstdint>

namespace ride_controller_lease {

enum class ControllerRole : uint8_t {
  Owner = 1,
  ScopedWatch = 2,
};

enum class ClaimResult : uint8_t {
  Granted,
  Renewed,
  Busy,
  InvalidController,
};

struct ControllerId {
  uint64_t high = 0;
  uint64_t low = 0;

  bool isValid() const { return high != 0 || low != 0; }
  bool operator==(const ControllerId &other) const {
    return high == other.high && low == other.low;
  }
};

// The durable 128-bit controller ID is paired with a connection-authentication
// session ID. A reconnect using the same credential is still a different lease
// claimant, so the old and new sessions can never write concurrently.
struct ControllerIdentity {
  ControllerId controllerId{};
  uint64_t sessionId = 0;
  ControllerRole role = ControllerRole::Owner;

  bool isValid() const {
    const bool validRole = role == ControllerRole::Owner ||
                           role == ControllerRole::ScopedWatch;
    return controllerId.isValid() && sessionId != 0 && validRole;
  }
};

// This small state machine is intentionally allocation-free. The BLE owner
// must call it under the same serialization primitive used for authenticated
// session state; it does not provide its own cross-task synchronization.
class RideControllerLease {
public:
  explicit RideControllerLease(uint32_t timeoutMs = 15000)
      : timeoutMs_(timeoutMs == 0 ? 15000 : timeoutMs) {}

  ClaimResult claim(const ControllerIdentity &controller, uint32_t nowMs) {
    expireIfNeeded(nowMs);
    if (!controller.isValid())
      return ClaimResult::InvalidController;

    if (!active_) {
      holder_ = controller;
      active_ = true;
      lastActivityMs_ = nowMs;
      advanceGeneration();
      return ClaimResult::Granted;
    }

    if (!matches(controller))
      return ClaimResult::Busy;

    lastActivityMs_ = nowMs;
    return ClaimResult::Renewed;
  }

  bool allows(const ControllerIdentity &controller, uint32_t nowMs) {
    expireIfNeeded(nowMs);
    return active_ && matches(controller);
  }

  bool recordActivity(const ControllerIdentity &controller, uint32_t nowMs) {
    if (!allows(controller, nowMs))
      return false;
    lastActivityMs_ = nowMs;
    return true;
  }

  bool release(const ControllerIdentity &controller) {
    if (!active_ || !matches(controller))
      return false;
    clear();
    return true;
  }

  void disconnect(const ControllerIdentity &controller) {
    if (active_ && matches(controller))
      clear();
  }

  void revoke(const ControllerId &controllerId) {
    if (active_ && holder_.controllerId == controllerId)
      clear();
  }

  void reset() { clear(); }

  bool isActive(uint32_t nowMs) {
    expireIfNeeded(nowMs);
    return active_;
  }

  ControllerIdentity holder(uint32_t nowMs) {
    expireIfNeeded(nowMs);
    return active_ ? holder_ : ControllerIdentity{};
  }

  uint32_t generation() const { return generation_; }

private:
  bool matches(const ControllerIdentity &controller) const {
    return holder_.controllerId == controller.controllerId &&
           holder_.sessionId == controller.sessionId &&
           holder_.role == controller.role;
  }

  void expireIfNeeded(uint32_t nowMs) {
    if (!active_)
      return;
    // Unsigned subtraction intentionally handles millis() wrap.
    if (static_cast<uint32_t>(nowMs - lastActivityMs_) >= timeoutMs_)
      clear();
  }

  void clear() {
    active_ = false;
    holder_ = ControllerIdentity{};
    lastActivityMs_ = 0;
  }

  void advanceGeneration() {
    ++generation_;
    if (generation_ == 0)
      ++generation_;
  }

  uint32_t timeoutMs_ = 0;
  ControllerIdentity holder_{};
  uint32_t lastActivityMs_ = 0;
  uint32_t generation_ = 0;
  bool active_ = false;
};

} // namespace ride_controller_lease
