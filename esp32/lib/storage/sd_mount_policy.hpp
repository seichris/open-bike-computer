#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace storage_policy {

constexpr std::size_t kMountAttemptCount = 3;
constexpr std::array<uint32_t, kMountAttemptCount> kDelayBeforeAttemptMs{
    0U, 50U, 150U};
constexpr uint32_t kFailedSequenceCooldownMs = 2000U;

struct MountAttemptResult {
  bool mounted;
  bool rootHealthy;
};

struct MountSequenceResult {
  bool ok;
  std::size_t attempts;
};

struct LifecycleState {
  bool busBegun = false;
  bool sdTouched = false;
};

template <typename EndSd, typename EndBus, typename Deselect>
void teardownLifecycle(LifecycleState &state, EndSd endSd, EndBus endBus,
                       Deselect deselect) {
  if (state.sdTouched) {
    endSd();
    state.sdTouched = false;
  }
  if (state.busBegun) {
    endBus();
    state.busBegun = false;
  }
  deselect();
}

inline bool cooldownActive(uint32_t nowMs, uint32_t retryAfterMs) {
  return static_cast<int32_t>(retryAfterMs - nowMs) > 0;
}

template <typename Teardown, typename Delay, typename Attempt>
MountSequenceResult runMountSequence(Teardown teardown, Delay delay,
                                     Attempt attempt) {
  for (std::size_t index = 0; index < kMountAttemptCount; ++index) {
    teardown();
    if (kDelayBeforeAttemptMs[index] != 0U) {
      delay(kDelayBeforeAttemptMs[index]);
    }
    const MountAttemptResult result = attempt(index + 1U);
    if (result.mounted && result.rootHealthy) {
      return {true, index + 1U};
    }
  }
  return {false, kMountAttemptCount};
}

} // namespace storage_policy
