#include "../../lib/storage/sd_mount_policy.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <vector>

int main() {
  using storage_policy::MountAttemptResult;

  for (std::size_t successAttempt = 1; successAttempt <= 3; ++successAttempt) {
    std::size_t teardowns = 0;
    std::vector<uint32_t> delays;
    auto result = storage_policy::runMountSequence(
        [&]() { ++teardowns; },
        [&](uint32_t value) { delays.push_back(value); },
        [&](std::size_t attempt) {
          return MountAttemptResult{attempt == successAttempt,
                                    attempt == successAttempt};
        });
    assert(result.ok);
    assert(result.attempts == successAttempt);
    assert(teardowns == successAttempt);
    assert(delays.size() == successAttempt - 1U);
    if (successAttempt >= 2U)
      assert(delays[0] == 50U);
    if (successAttempt >= 3U)
      assert(delays[1] == 150U);
  }

  std::size_t teardowns = 0;
  auto failed = storage_policy::runMountSequence(
      [&]() { ++teardowns; }, [](uint32_t) {},
      [](std::size_t) { return MountAttemptResult{false, false}; });
  assert(!failed.ok);
  assert(failed.attempts == 3U);
  assert(teardowns == 3U);

  auto unhealthyRoot = storage_policy::runMountSequence(
      []() {}, [](uint32_t) {},
      [](std::size_t attempt) {
        return MountAttemptResult{true, attempt == 2U};
      });
  assert(unhealthyRoot.ok);
  assert(unhealthyRoot.attempts == 2U);

  assert(!storage_policy::cooldownActive(100U, 0U));
  assert(storage_policy::cooldownActive(100U, 200U));
  assert(!storage_policy::cooldownActive(200U, 200U));
  assert(!storage_policy::cooldownActive(201U, 200U));
  assert(storage_policy::cooldownActive(0xfffffff0U, 0x20U));
  assert(storage_policy::cooldownActive(0xfffff830U, 0U));

  return 0;
}
