#include "../../lib/utils/src/runtime_ownership.hpp"
#include "../../lib/panel/full_frame_allocation.hpp"

#include <atomic>
#include <cassert>
#include <condition_variable>
#include <cstring>
#include <thread>

struct Maneuver {
  unsigned icon = 0;
  unsigned distance = 0;
  char text[128]{};
};

int main() {
  runtime_ownership::Snapshot<Maneuver, std::mutex> snapshot;
  std::atomic<bool> finished{false};
  std::thread writer([&] {
    for (unsigned i = 1; i <= 100000; ++i) {
      Maneuver value;
      value.icon = i;
      value.distance = i * 10;
      std::memset(value.text, static_cast<char>(i % 127), sizeof(value.text));
      snapshot.publish(value);
    }
    finished = true;
  });
  do {
    const auto value = snapshot.read();
    assert(value.distance == value.icon * 10);
    for (char c : value.text)
      assert(c == static_cast<char>(value.icon % 127));
  } while (!finished.load());
  writer.join();
  snapshot.publish({}); // Disconnect/reset uses the same boundary.
  assert(snapshot.read().icon == 0);

  runtime_ownership::SocketInterruptLease<std::mutex> lease;
  lease.publish(42);
  std::mutex barrier;
  std::condition_variable condition;
  bool entered = false, release = false;
  std::atomic<bool> withdrawn{false};
  std::thread revoke([&] {
    lease.interrupt([&](int fd) {
      assert(fd == 42);
      std::unique_lock<std::mutex> lock(barrier);
      entered = true;
      condition.notify_all();
      condition.wait(lock, [&] { return release; });
    });
  });
  {
    std::unique_lock<std::mutex> lock(barrier);
    condition.wait(lock, [&] { return entered; });
  }
  std::thread close([&] { lease.withdraw(); withdrawn = true; });
  assert(!withdrawn.load()); // In-flight interrupt still owns the capability.
  {
    std::lock_guard<std::mutex> lock(barrier);
    release = true;
    condition.notify_all();
  }
  revoke.join();
  close.join();
  assert(withdrawn.load());
  // Simulate fd 42 reused elsewhere after close. Revocation must not touch it.
  lease.interrupt([](int) { assert(false); });
  lease.publish(43);
  lease.interrupt([](int fd) { assert(fd == 43); });
  lease.withdraw();

  for (const size_t pixels : {466U * 466U, 410U * 502U}) {
    for (bool rotated : {false, true}) {
      for (unsigned failAt : {1U, 2U, 3U}) {
        unsigned allocations = 0, releases = 0;
        const auto buffers = full_frame_allocation::reserve(
            pixels, rotated,
            [&](size_t bytes) -> void * {
              assert(bytes == pixels * 2);
              if (++allocations == failAt) return nullptr;
              return reinterpret_cast<void *>(static_cast<uintptr_t>(allocations));
            },
            [&](void *p) { assert(p != nullptr); ++releases; });
        const bool expected = failAt > (rotated ? 2U : 1U);
        assert(buffers.ready() == expected);
        assert(releases == (rotated && failAt == 2 ? 1U : 0U));
        if (expected) assert(buffers.bytes == pixels * 2);
        else assert(buffers.draw == nullptr && buffers.rotation == nullptr);
      }
    }
  }
}
