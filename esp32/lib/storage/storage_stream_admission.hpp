#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdio>

namespace storage_shutdown {
// Bounded stream lifetime registry. The packed count/closed CAS is the shared
// linearization point for fopen admission and shutdown; no filesystem call is
// made while holding a mutex or interrupt-disabled critical section.
class StreamAdmission {
public:
  static constexpr size_t kCapacity = 64;
  static constexpr size_t kInvalid = kCapacity;

  size_t reserveOpen() {
    uint32_t state = admission_.load(std::memory_order_acquire);
    do {
      if ((state & kClosed) != 0 || (state & kCountMask) >= kCapacity)
        return kInvalid;
    } while (!admission_.compare_exchange_weak(
        state, state + 1, std::memory_order_acq_rel, std::memory_order_acquire));
    for (size_t index = 0; index < kCapacity; ++index) {
      uint8_t empty = Empty;
      if (slots_[index].state.compare_exchange_strong(
              empty, Opening, std::memory_order_acq_rel))
        return index;
    }
    admission_.fetch_sub(1, std::memory_order_release);
    return kInvalid;
  }

  void finishOpen(size_t index, FILE *file) {
    if (file == nullptr) {
      slots_[index].state.store(Empty, std::memory_order_release);
      admission_.fetch_sub(1, std::memory_order_release);
      return;
    }
    slots_[index].file.store(file, std::memory_order_release);
    slots_[index].state.store(Open, std::memory_order_release);
  }

  size_t beginClose(FILE *file) {
    if (file == nullptr) return kInvalid;
    for (size_t index = 0; index < kCapacity; ++index) {
      if (slots_[index].file.load(std::memory_order_acquire) != file)
        continue;
      uint8_t open = Open;
      if (slots_[index].state.compare_exchange_strong(
              open, Closing, std::memory_order_acq_rel))
        return index;
    }
    return kInvalid;
  }

  void finishClose(size_t index, bool succeeded) {
    if (!succeeded) failed_.store(true, std::memory_order_release);
    slots_[index].file.store(nullptr, std::memory_order_release);
    slots_[index].state.store(Empty, std::memory_order_release);
    admission_.fetch_sub(1, std::memory_order_release);
  }

  void closeAdmission() { admission_.fetch_or(kClosed, std::memory_order_acq_rel); }
  bool quiescent() const {
    return admission_.load(std::memory_order_acquire) == kClosed &&
           !failed_.load(std::memory_order_acquire);
  }

private:
  enum : uint8_t { Empty, Opening, Open, Closing };
  static constexpr uint32_t kClosed = uint32_t{1} << 31;
  static constexpr uint32_t kCountMask = kClosed - 1;
  struct Slot {
    std::atomic<uint8_t> state{Empty};
    std::atomic<FILE *> file{nullptr};
  };
  Slot slots_[kCapacity]{};
  std::atomic<uint32_t> admission_{0};
  std::atomic<bool> failed_{false};
};
// Transient metadata/mount calls participate in the same admission fence.
class OperationLease {
public:
  explicit OperationLease(StreamAdmission &owner)
      : owner_(owner), slot_(owner.reserveOpen()) {}
  ~OperationLease() {
    if (held()) owner_.finishOpen(slot_, nullptr);
  }
  OperationLease(const OperationLease &) = delete;
  OperationLease &operator=(const OperationLease &) = delete;
  bool held() const { return slot_ != StreamAdmission::kInvalid; }
private:
  StreamAdmission &owner_;
  size_t slot_;
};
} // namespace storage_shutdown
