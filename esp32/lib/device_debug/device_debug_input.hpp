#pragma once

#include "device_debug_protocol.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

#ifdef ARDUINO
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#endif

namespace device_debug {

enum class PointerPhase : uint8_t { Down, Move, Up, Cancel };

struct PointerEvent {
  uint8_t schema = 1;
  uint32_t eventSequence = 0;
  uint8_t pointerId = 0;
  PointerPhase phase = PointerPhase::Cancel;
  Point point{};
  uint32_t receivedAtMs = 0;
};

enum class PointerQueueResult : uint8_t {
  Accepted,
  InvalidSchema,
  InvalidPointerId,
  InvalidCoordinate,
  DuplicateOrOutOfOrder,
  InvalidTransition,
  RateLimited,
  QueueFull,
};

enum class PointerState : uint8_t {
  Idle,
  RemotePressed,
  PhysicalOverrideUntilRelease,
  CancelPending,
};

struct PointerSample {
  bool pressed = false;
  Point point{};
  bool changed = false;
  bool timedOut = false;
};

struct PointerCounters {
  uint32_t accepted = 0;
  uint32_t rejected = 0;
  uint32_t physicalOverrides = 0;
  uint32_t timeouts = 0;
  uint32_t sessionCancels = 0;
};

template <size_t Capacity = 16> class PointerController {
public:
  static_assert(Capacity >= 2,
                "pointer queues reserve one slot for a release transition");

  explicit PointerController(TargetGeometry geometry) : geometry_(geometry) {}

  PointerQueueResult enqueue(const PointerEvent &event) {
    if (event.schema != 1)
      return reject(PointerQueueResult::InvalidSchema);
    if (event.pointerId != 0)
      return reject(PointerQueueResult::InvalidPointerId);
    if (!contains(geometry_, event.point.x, event.point.y))
      return reject(PointerQueueResult::InvalidCoordinate);
    if (hasAcceptedSequence_ &&
        !sequenceIsNewer(event.eventSequence, lastAcceptedSequence_))
      return reject(PointerQueueResult::DuplicateOrOutOfOrder);
    if (state_ == PointerState::PhysicalOverrideUntilRelease)
      return reject(PointerQueueResult::InvalidTransition);
    // A throttled move is harmless; throttling an up/cancel can leave LVGL
    // pressed until the fail-safe fires, so release transitions always win.
    if (event.phase != PointerPhase::Up &&
        event.phase != PointerPhase::Cancel && hasAcceptedAtMs_ &&
        !intervalElapsed(event.receivedAtMs, lastAcceptedAtMs_,
                         kPointerMinimumIntervalMs))
      return reject(PointerQueueResult::RateLimited);

    const bool presses = event.phase == PointerPhase::Down;
    const bool continues = event.phase == PointerPhase::Move;
    const bool releases = event.phase == PointerPhase::Up ||
                          event.phase == PointerPhase::Cancel;
    if ((presses && enqueuePressed_) ||
        ((continues || releases) && !enqueuePressed_))
      return reject(PointerQueueResult::InvalidTransition);
    // Non-release events may not consume the final slot. This makes overflow
    // explicit to HTTP clients while guaranteeing that an up/cancel following
    // any accepted down still has room and no older release is discarded.
    if (size_ == Capacity || (!releases && size_ == Capacity - 1))
      return reject(PointerQueueResult::QueueFull);

    queue_[(head_ + size_) % Capacity] = event;
    ++size_;
    enqueuePressed_ = presses || continues;
    lastAcceptedSequence_ = event.eventSequence;
    hasAcceptedSequence_ = true;
    lastAcceptedAtMs_ = event.receivedAtMs;
    hasAcceptedAtMs_ = true;
    ++counters_.accepted;
    return PointerQueueResult::Accepted;
  }

  PointerSample sample(bool physicalPressed, uint32_t nowMs) {
    if (physicalPressed) {
      if (state_ != PointerState::PhysicalOverrideUntilRelease) {
        clearPending();
        remotePressed_ = false;
        state_ = PointerState::PhysicalOverrideUntilRelease;
        ++counters_.physicalOverrides;
      }
      return {};
    }
    if (state_ == PointerState::PhysicalOverrideUntilRelease) {
      state_ = PointerState::Idle;
      return {};
    }

    if (remotePressed_ &&
        intervalElapsed(nowMs, lastRemoteUpdateMs_, kPointerFailSafeMs)) {
      clearPending();
      remotePressed_ = false;
      enqueuePressed_ = false;
      state_ = PointerState::Idle;
      ++counters_.timeouts;
      return {false, remotePoint_, true, true};
    }

    if (size_ == 0)
      return {remotePressed_, remotePoint_, false, false};

    const PointerEvent event = queue_[head_];
    head_ = (head_ + 1) % Capacity;
    --size_;
    remotePoint_ = panelToLvgl(geometry_, event.point);
    lastRemoteUpdateMs_ = event.receivedAtMs;
    switch (event.phase) {
    case PointerPhase::Down:
    case PointerPhase::Move:
      remotePressed_ = true;
      state_ = PointerState::RemotePressed;
      break;
    case PointerPhase::Up:
    case PointerPhase::Cancel:
      remotePressed_ = false;
      state_ = PointerState::Idle;
      break;
    }
    return {remotePressed_, remotePoint_, true, false};
  }

  PointerSample cancelSession() {
    const bool wasPressed = remotePressed_;
    clearPending();
    remotePressed_ = false;
    enqueuePressed_ = false;
    state_ = PointerState::Idle;
    hasAcceptedSequence_ = false;
    hasAcceptedAtMs_ = false;
    ++counters_.sessionCancels;
    return {false, remotePoint_, wasPressed, false};
  }

  void resetSession() {
    clearPending();
    state_ = PointerState::Idle;
    remotePressed_ = false;
    remotePoint_ = {};
    lastRemoteUpdateMs_ = 0;
    lastAcceptedSequence_ = 0;
    lastAcceptedAtMs_ = 0;
    hasAcceptedSequence_ = false;
    hasAcceptedAtMs_ = false;
    counters_ = {};
  }

  PointerState state() const { return state_; }
  size_t pendingCount() const { return size_; }
  PointerCounters counters() const { return counters_; }

private:
  PointerQueueResult reject(PointerQueueResult result) {
    ++counters_.rejected;
    return result;
  }

  void clearPending() {
    head_ = 0;
    size_ = 0;
    enqueuePressed_ = false;
  }

  TargetGeometry geometry_{};
  std::array<PointerEvent, Capacity> queue_{};
  size_t head_ = 0;
  size_t size_ = 0;
  PointerState state_ = PointerState::Idle;
  bool remotePressed_ = false;
  bool enqueuePressed_ = false;
  Point remotePoint_{};
  uint32_t lastRemoteUpdateMs_ = 0;
  uint32_t lastAcceptedSequence_ = 0;
  uint32_t lastAcceptedAtMs_ = 0;
  bool hasAcceptedSequence_ = false;
  bool hasAcceptedAtMs_ = false;
  PointerCounters counters_{};
};

#ifdef ARDUINO
class PointerInputRuntime {
public:
  bool begin();
  void cancelSession();
  PointerQueueResult enqueue(const PointerEvent &event);
  PointerSample sample(bool physicalPressed, uint32_t nowMs);
  PointerCounters counters();
  bool active() const { return active_.load(std::memory_order_acquire); }

private:
  bool ensureMutex();

#ifdef WAVESHARE_AMOLED_206
  PointerController<> controller_{kWaveshareAmoled206Geometry};
#else
  PointerController<> controller_{kWaveshareAmoled175Geometry};
#endif
  SemaphoreHandle_t mutex_ = nullptr;
  std::atomic<bool> active_{false};
  std::atomic<bool> physicalOverridePending_{false};
  PointerSample lastSample_{};
};

PointerInputRuntime &pointerInput();
#endif

} // namespace device_debug
