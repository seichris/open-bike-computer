#include "../../lib/storage/sd_mount_policy.hpp"

#include <cassert>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

int main() {
  using storage_policy::LifecycleState;
  using storage_policy::MountAttemptResult;

  // Teardown uses the exact production policy and is safe before or after
  // every partial initialization state, including repeated calls.
  for (int mask = 0; mask < 4; ++mask) {
    LifecycleState lifecycle{
        static_cast<bool>(mask & 1), static_cast<bool>(mask & 2)};
    int sdEnds = 0;
    int busEnds = 0;
    int deselects = 0;
    storage_policy::teardownLifecycle(
        lifecycle, [&]() { ++sdEnds; }, [&]() { ++busEnds; },
        [&]() { ++deselects; });
    assert(sdEnds == ((mask & 2) != 0 ? 1 : 0));
    assert(busEnds == ((mask & 1) != 0 ? 1 : 0));
    assert(deselects == 1);
    assert(!lifecycle.sdTouched);
    assert(!lifecycle.busBegun);

    storage_policy::teardownLifecycle(
        lifecycle, [&]() { ++sdEnds; }, [&]() { ++busEnds; },
        [&]() { ++deselects; });
    assert(sdEnds == ((mask & 2) != 0 ? 1 : 0));
    assert(busEnds == ((mask & 1) != 0 ? 1 : 0));
    assert(deselects == 2);
  }

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

  // Callers serialized by Storage's mount mutex must not start another mount
  // sequence or remount FFat while the failed-sequence cooldown is active.
  std::size_t sequences = 0;
  std::size_t fallbacks = 0;
  bool cooldownArmed = false;
  uint32_t retryAfterMs = 0;
  auto serializedEnsure = [&](uint32_t nowMs) {
    if (cooldownArmed &&
        storage_policy::cooldownActive(nowMs, retryAfterMs)) {
      return false;
    }
    ++sequences;
    const auto sequence = storage_policy::runMountSequence(
        []() {}, [](uint32_t) {},
        [](std::size_t) { return MountAttemptResult{false, false}; });
    if (!sequence.ok) {
      ++fallbacks;
      cooldownArmed = true;
      retryAfterMs = nowMs + storage_policy::kFailedSequenceCooldownMs;
    }
    return sequence.ok;
  };
  assert(!serializedEnsure(1000U));
  assert(!serializedEnsure(1001U));
  assert(sequences == 1U);
  assert(fallbacks == 1U);
  assert(!serializedEnsure(3000U));
  assert(sequences == 2U);
  assert(fallbacks == 2U);

  // Two concurrent callers share one single-flight lock. Whichever caller
  // enters first performs the failed attempt sequence and arms the cooldown;
  // the other observes that cooldown without starting a second sequence.
  sequences = 0;
  fallbacks = 0;
  cooldownArmed = false;
  retryAfterMs = 0;
  std::mutex mountMutex;
  std::atomic<bool> start{false};
  auto concurrentEnsure = [&]() {
    while (!start.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
    std::lock_guard<std::mutex> guard(mountMutex);
    return serializedEnsure(5000U);
  };
  bool firstResult = true;
  bool secondResult = true;
  std::thread first([&]() { firstResult = concurrentEnsure(); });
  std::thread second([&]() { secondResult = concurrentEnsure(); });
  start.store(true, std::memory_order_release);
  first.join();
  second.join();
  assert(!firstResult);
  assert(!secondResult);
  assert(sequences == 1U);
  assert(fallbacks == 1U);

  return 0;
}
