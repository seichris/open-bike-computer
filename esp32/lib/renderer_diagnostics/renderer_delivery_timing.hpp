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

struct DeliveryTimingSnapshot {
  uint32_t session = 0;
  uint32_t completed = 0;
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
    value.session = value_.session;
    value.ordinal = ++ordinal_;
    value.channel = channel;
    value.startedAtMs = nowMs;
    value.frameActiveAtEntry = frame;
    return value;
  }
  void complete(const DeliveryCallbackTiming &value) {
    if (value.session == 0 || value.session != value_.session ||
        (value.channel != 1 && value.channel != 2)) return;
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
