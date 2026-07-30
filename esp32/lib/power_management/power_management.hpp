#pragma once

#include "power_management_policy.hpp"

#include <cstdint>

namespace power_management {

enum class LockDomain : uint8_t {
  Startup = 0,
  Display,
  Map,
  Storage,
  Transfer,
  Audio,
  I2c,
  Count,
};

struct RuntimeStatus {
  bool enabled = false;
  Configuration requested = kSelectedConfiguration;
  Configuration effective{};
  int errorCode = 0;
  uint32_t activeLockCount = 0;
  uint32_t peakLockCount = 0;
  uint32_t lockFailureCount = 0;
  uint64_t gpioWakeMask = 0;
  uint32_t wakeSourceFailureCount = 0;
  bool startupComplete = false;
};

class ScopedLock {
public:
  explicit ScopedLock(LockDomain domain);
  ~ScopedLock();

  ScopedLock(const ScopedLock &) = delete;
  ScopedLock &operator=(const ScopedLock &) = delete;

  bool held() const { return held_; }

private:
  LockDomain domain_;
  bool held_ = false;
};

// Configure ESP-IDF dynamic frequency scaling once framework initialization is
// complete. A rejected request leaves the prior configuration intact. Any
// configuration or readback failure is exposed through status().
bool begin();
// Release the startup guard only after display, storage, BLE, touch, transfer,
// and audio initialization have completed. It is a no-op in DFS-only builds.
void completeStartup();
// Configure one digital GPIO as an active-low light-sleep wake source. The
// caller must install a level-safe ISR before calling this function.
bool configureActiveLowGpioWakeup(uint8_t gpioNumber);
bool acquire(LockDomain domain);
bool release(LockDomain domain);
RuntimeStatus status();

} // namespace power_management
