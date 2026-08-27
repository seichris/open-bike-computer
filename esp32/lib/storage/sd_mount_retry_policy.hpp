#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace storage_mount_retry_policy {

constexpr std::size_t kMountAttemptCount = 3;
constexpr std::array<uint32_t, kMountAttemptCount> kDelayBeforeAttemptMs{
    0U, 50U, 150U};

struct MountAttemptResult {
  bool mounted;
  bool rootHealthy;
};

struct MountSequenceResult {
  bool ok;
  std::size_t attempts;
};

// Keep the retry transitions hardware-independent so host tests can prove the
// sequence remains bounded. The caller owns the concrete SDMMC teardown and
// mount operations.
template <typename Teardown, typename Delay, typename Attempt>
MountSequenceResult runMountSequence(Teardown teardown, Delay delay,
                                     Attempt attempt) {
  for (std::size_t index = 0; index < kMountAttemptCount; ++index) {
    teardown();
    if (kDelayBeforeAttemptMs[index] != 0U)
      delay(kDelayBeforeAttemptMs[index]);

    const MountAttemptResult result = attempt(index + 1U);
    if (result.mounted && result.rootHealthy)
      return {true, index + 1U};
  }
  return {false, kMountAttemptCount};
}

} // namespace storage_mount_retry_policy
