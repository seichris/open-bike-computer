#pragma once

#include <cstdint>

namespace renderer_diagnostics {

// Fixed-size, payload-free records. All durations use the same device micros()
// clock (unsigned subtraction handles rollover). No on-air timestamps implied.
struct DeliveryCallbackTiming {
  uint32_t session = 0;
  uint32_t ordinal = 0;
  uint32_t startedAtMs = 0;
  uint32_t callbackUs = 0;
  uint32_t setupUs = 0;
  uint32_t authenticationUs = 0;
  uint32_t allocationUs = 0;
  uint32_t mailboxWaitUs = 0;
  uint32_t mailboxHoldUs = 0;
  uint8_t channel = 0; // 1 = route, 2 = GPS; never a UUID or payload.
  bool authenticated = false;
  bool mailboxAccepted = false;
  bool frameActiveAtEntry = false;
  bool frameActiveAtExit = false;
};

struct DeliveryOwnerTiming {
  uint32_t session = 0;
  uint32_t ordinal = 0;
  uint32_t startedAtMs = 0;
  uint32_t mailboxAgeUs = 0;
  uint32_t processingUs = 0;
  uint8_t channel = 0;
};

enum class DeliveryCallbackPhase : uint8_t {
  None, Entered, Authenticating, AuthenticationFinished, Allocating,
  WaitingForMailbox, HoldingMailbox, Dispatching, Completed
};

inline const char *deliveryCallbackPhaseName(DeliveryCallbackPhase phase) {
  switch (phase) {
  case DeliveryCallbackPhase::Entered: return "entered";
  case DeliveryCallbackPhase::Authenticating: return "authenticating";
  case DeliveryCallbackPhase::AuthenticationFinished: return "authentication_finished";
  case DeliveryCallbackPhase::Allocating: return "allocating";
  case DeliveryCallbackPhase::WaitingForMailbox: return "waiting_for_mailbox";
  case DeliveryCallbackPhase::HoldingMailbox: return "holding_mailbox";
  case DeliveryCallbackPhase::Dispatching: return "dispatching";
  case DeliveryCallbackPhase::Completed: return "completed";
  default: return "none";
  }
}

// Latest native callback entry survives until the next entry, even when no
// completion arrives. Device timestamps, not an ATT/radio delivery receipt.
struct DeliveryCallbackProgress {
  uint32_t session = 0;
  uint32_t ordinal = 0;
  uint32_t startedAtMs = 0;
  uint32_t updatedAtMs = 0;
  uint8_t channel = 0;
  DeliveryCallbackPhase phase = DeliveryCallbackPhase::None;
};

struct DeliveryTimingSnapshot {
  uint32_t session = 0;
  uint32_t completed = 0;
  uint32_t started = 0;
  DeliveryCallbackProgress latestStarted{};
  DeliveryCallbackTiming latest{};
  DeliveryCallbackTiming slowestRoute{};
  DeliveryCallbackTiming slowestGps{};
  DeliveryOwnerTiming latestOwner{};
  DeliveryOwnerTiming slowestOwner{};
};

// Caller serializes access. Slowest records survive comparison-window resets,
// but not a new debug session. Old in-flight callbacks cannot contaminate it.
class DeliveryTimingState {
public:
  void reset() {
    uint32_t next = value_.session + 1;
    value_ = {};
    value_.session = next == 0 ? 1 : next;
    ordinal_ = 0;
  }
  DeliveryCallbackTiming begin(uint8_t channel, uint32_t nowMs, bool frame) {
    DeliveryCallbackTiming value{};
    if (value_.session == 0 || (channel != 1 && channel != 2)) return value;
    value.session = value_.session;
    if (++ordinal_ == 0) ++ordinal_;
    value.ordinal = ordinal_;
    value.channel = channel;
    value.startedAtMs = nowMs;
    value.frameActiveAtEntry = frame;
    ++value_.started;
    value_.latestStarted = {value.session, value.ordinal, nowMs, nowMs,
                            channel, DeliveryCallbackPhase::Entered};
    return value;
  }
  void progress(const DeliveryCallbackTiming &value,
                DeliveryCallbackPhase phase, uint32_t nowMs) {
    auto &entry = value_.latestStarted;
    if (value.session == 0 || value.session != value_.session ||
        entry.session != value.session || entry.ordinal != value.ordinal ||
        entry.channel != value.channel ||
        entry.phase == DeliveryCallbackPhase::Completed ||
        phase == DeliveryCallbackPhase::None) return;
    entry.phase = phase;
    entry.updatedAtMs = nowMs;
  }
  void complete(const DeliveryCallbackTiming &value, uint32_t nowMs) {
    if (value.session == 0 || value.session != value_.session ||
        (value.channel != 1 && value.channel != 2)) return;
    progress(value, DeliveryCallbackPhase::Completed, nowMs);
    ++value_.completed;
    value_.latest = value;
    auto &slowest = value.channel == 1 ? value_.slowestRoute : value_.slowestGps;
    if (slowest.ordinal == 0 || value.callbackUs > slowest.callbackUs)
      slowest = value;
  }
  DeliveryTimingSnapshot snapshot() const { return value_; }
  void consumed(const DeliveryOwnerTiming &value) {
    if (value.session == 0 || value.session != value_.session) return;
    value_.latestOwner = value;
    if (value_.slowestOwner.ordinal == 0 ||
        value.processingUs > value_.slowestOwner.processingUs)
      value_.slowestOwner = value;
  }
private:
  DeliveryTimingSnapshot value_{};
  uint32_t ordinal_ = 0;
};

} // namespace renderer_diagnostics
