#include "../../lib/storage/sd_mount_retry_policy.hpp"
#include "../../lib/storage/waveshare_storage_migration_policy.hpp"

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <vector>

using storage_mount_retry_policy::MountAttemptResult;
using storage_mount_retry_policy::runMountSequence;

int main() {
  {
    std::size_t teardowns = 0;
    std::vector<uint32_t> delays;
    const auto result = runMountSequence(
        [&]() { ++teardowns; },
        [&](uint32_t delayMs) { delays.push_back(delayMs); },
        [](std::size_t attempt) {
          assert(attempt == 1U);
          return MountAttemptResult{true, true};
        });
    assert(result.ok);
    assert(result.attempts == 1U);
    assert(teardowns == 1U);
    assert(delays.empty());
  }

  {
    std::size_t teardowns = 0;
    std::vector<uint32_t> delays;
    const auto result = runMountSequence(
        [&]() { ++teardowns; },
        [&](uint32_t delayMs) { delays.push_back(delayMs); },
        [](std::size_t attempt) {
          // A filesystem mount without a healthy root must be retried.
          return MountAttemptResult{true, attempt >= 2U};
        });
    assert(result.ok);
    assert(result.attempts == 2U);
    assert(teardowns == 2U);
    assert((delays == std::vector<uint32_t>{50U}));
  }

  {
    std::size_t teardowns = 0;
    std::vector<uint32_t> delays;
    const auto result = runMountSequence(
        [&]() { ++teardowns; },
        [&](uint32_t delayMs) { delays.push_back(delayMs); },
        [](std::size_t attempt) {
          return MountAttemptResult{attempt == 3U, attempt == 3U};
        });
    assert(result.ok);
    assert(result.attempts == 3U);
    assert(teardowns == 3U);
    assert((delays == std::vector<uint32_t>{50U, 150U}));
  }

  {
    std::size_t teardowns = 0;
    std::size_t attempts = 0;
    std::vector<uint32_t> delays;
    const auto result = runMountSequence(
        [&]() { ++teardowns; },
        [&](uint32_t delayMs) { delays.push_back(delayMs); },
        [&](std::size_t) {
          ++attempts;
          return MountAttemptResult{false, false};
        });
    assert(!result.ok);
    assert(result.attempts == 3U);
    assert(attempts == 3U);
    assert(teardowns == 3U);
    assert((delays == std::vector<uint32_t>{50U, 150U}));
  }

  {
    std::vector<int> calls;
    const auto result =
        waveshare_storage_migration_policy::mountNativeFirst(
            [&]() {
              calls.push_back(1);
              return true;
            },
            [&]() {
              calls.push_back(2);
              return true;
            });
    assert(result.backend ==
           waveshare_storage_migration_policy::Backend::NativeSdmmc);
    assert(result.nativeAttempted);
    assert(!result.legacyAttempted);
    assert((calls == std::vector<int>{1}));
    assert(!waveshare_storage_migration_policy::requiresCardPowerCycle(
        result.backend));
  }

  {
    std::vector<int> calls;
    const auto result =
        waveshare_storage_migration_policy::mountNativeFirst(
            [&]() {
              calls.push_back(1);
              return false;
            },
            [&]() {
              calls.push_back(2);
              return true;
            });
    assert(result.backend == waveshare_storage_migration_policy::Backend::
                                 LegacySpiMigration);
    assert(result.nativeAttempted);
    assert(result.legacyAttempted);
    assert((calls == std::vector<int>{1, 2}));
    assert(waveshare_storage_migration_policy::requiresCardPowerCycle(
        result.backend));
  }

  {
    std::vector<int> calls;
    const auto result =
        waveshare_storage_migration_policy::mountNativeFirst(
            [&]() {
              calls.push_back(1);
              return false;
            },
            [&]() {
              calls.push_back(2);
              return false;
            });
    assert(result.backend ==
           waveshare_storage_migration_policy::Backend::Unavailable);
    assert(result.nativeAttempted);
    assert(result.legacyAttempted);
    assert((calls == std::vector<int>{1, 2}));
    assert(!waveshare_storage_migration_policy::requiresCardPowerCycle(
        result.backend));
  }

  std::cout << "SD mount retry policy tests passed\n";
  return 0;
}
