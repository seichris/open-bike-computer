#include "../../lib/waveshare_board/i2c_retry_log.hpp"
#include <cassert>
#include <cstdint>

int main() {
  using waveshare_board::i2c::RetryLogLimiter;
  RetryLogLimiter limiter;
  uint32_t suppressed = 99;
  assert(limiter.admit(0x6B, true, 0, suppressed));
  assert(suppressed == 0); // First early-boot failure must be attributable.
  for (uint32_t t = 1; t < 5000; ++t)
    assert(!limiter.admit(0x6B, true, t, suppressed));
  assert(limiter.admit(0x6B, false, 4999, suppressed));
  assert(suppressed == 0); // Exhaustion isn't hidden by recovered traffic.
  assert(limiter.admit(0x34, true, 4999, suppressed));
  assert(suppressed == 0); // A noisy IMU cannot hide a PMIC failure.
  assert(limiter.admit(0x6B, true, 5000, suppressed));
  assert(suppressed == 4999);
  assert(limiter.admit(0x6B, true, 10000, suppressed));
  assert(suppressed == 0);
  assert(!limiter.admit(128, true, 10000, suppressed));

  RetryLogLimiter rollover;
  assert(rollover.admit(0x15, true, UINT32_MAX - 1000, suppressed));
  assert(!rollover.admit(0x15, true, 500, suppressed));
  assert(rollover.admit(0x15, true, 4000, suppressed));
  assert(suppressed == 1); // The millis wrap cannot create a log flood.
}
