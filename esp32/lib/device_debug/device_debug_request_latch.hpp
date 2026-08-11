#pragma once

#include <atomic>

namespace device_debug {

// A bounded cross-task request: concurrent callers can queue at most one
// action, and the main-task consumer observes that action exactly once.
class OneShotRequestLatch {
public:
  bool request() {
    bool expected = false;
    return pending_.compare_exchange_strong(
        expected, true, std::memory_order_acq_rel,
        std::memory_order_acquire);
  }

  bool pending() const {
    return pending_.load(std::memory_order_acquire);
  }

  bool take() {
    return pending_.exchange(false, std::memory_order_acq_rel);
  }

  void clear() {
    pending_.store(false, std::memory_order_release);
  }

private:
  std::atomic<bool> pending_{false};
};

} // namespace device_debug
