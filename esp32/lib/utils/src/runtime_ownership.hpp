#pragma once

#include <mutex>
#include <utility>

namespace runtime_ownership {

// Mutex is supplied by the platform. All callbacks must be allocation-free
// and bounded; formatting and IO belong outside the protected snapshot.
template <typename T, typename Mutex> class Snapshot {
public:
  T read() const {
    std::lock_guard<Mutex> lock(mutex_);
    return value_;
  }
  template <typename Update> void update(Update update) {
    std::lock_guard<Mutex> lock(mutex_);
    update(value_);
  }
  void publish(const T &value) {
    update([&](T &current) { current = value; });
  }
private:
  mutable Mutex mutex_;
  T value_{};
};

// A cancellation capability, distinct from the worker's owning descriptor.
// withdraw() fences every interrupt before the owner closes/reuses the fd.
template <typename Mutex> class SocketInterruptLease {
public:
  void publish(int fd) {
    std::lock_guard<Mutex> lock(mutex_);
    fd_ = fd;
  }
  void withdraw() {
    std::lock_guard<Mutex> lock(mutex_);
    fd_ = -1;
  }
  template <typename Interrupt> void interrupt(Interrupt interrupt) const {
    std::lock_guard<Mutex> lock(mutex_);
    if (fd_ >= 0)
      interrupt(fd_);
  }
private:
  mutable Mutex mutex_;
  int fd_ = -1;
};

} // namespace runtime_ownership
