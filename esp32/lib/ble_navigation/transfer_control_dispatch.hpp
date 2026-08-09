#pragma once

#include <atomic>
#include <cstdint>

namespace ble_transfer {

enum class Action : uint8_t {
  None = 0,
  EnableMap = 1,
  EnableFirmware = 2,
  DisableMap = 3,
  DisableAll = 4,
  EnableDebug = 5,
};

enum Notification : uint8_t {
  NotifyNone = 0,
  NotifyMap = 1 << 0,
  NotifyGeneric = 1 << 1,
};

struct Request {
  Action action = Action::None;
  uint8_t notifications = NotifyNone;

  bool empty() const {
    return action == Action::None && notifications == NotifyNone;
  }
};

// BLE writes can arrive on NimBLE's host task while process() runs on the main
// Arduino task. Keep only the latest requested mode transition, while
// preserving every status response type that callers are waiting for.
class PendingRequest {
public:
  void merge(Action action, uint8_t notifications) {
    uint32_t current = state_.load(std::memory_order_relaxed);
    uint32_t desired;
    do {
      const Action mergedAction =
          action == Action::None ? decodeAction(current) : action;
      const uint8_t mergedNotifications =
          decodeNotifications(current) | notifications;
      desired = encode(mergedAction, mergedNotifications);
    } while (!state_.compare_exchange_weak(current, desired,
                                            std::memory_order_release,
                                            std::memory_order_relaxed));
  }

  Request take() {
    const uint32_t state = state_.exchange(0, std::memory_order_acquire);
    return {decodeAction(state), decodeNotifications(state)};
  }

private:
  static constexpr uint32_t kActionMask = 0xff;
  static constexpr uint32_t kNotificationShift = 8;

  static uint32_t encode(Action action, uint8_t notifications) {
    return static_cast<uint32_t>(action) |
           (static_cast<uint32_t>(notifications) << kNotificationShift);
  }

  static Action decodeAction(uint32_t state) {
    return static_cast<Action>(state & kActionMask);
  }

  static uint8_t decodeNotifications(uint32_t state) {
    return static_cast<uint8_t>(state >> kNotificationShift);
  }

  std::atomic<uint32_t> state_{0};
};

} // namespace ble_transfer
