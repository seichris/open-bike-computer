#include "device_debug_input.hpp"

#ifdef ARDUINO

namespace device_debug {
namespace {

PointerInputRuntime sharedPointerInput;

} // namespace

bool PointerInputRuntime::ensureMutex() {
  if (mutex_ == nullptr)
    mutex_ = xSemaphoreCreateMutex();
  return mutex_ != nullptr;
}

bool PointerInputRuntime::begin() {
  if (!ensureMutex())
    return false;
  xSemaphoreTake(mutex_, portMAX_DELAY);
  controller_.resetSession();
  lastSample_ = {};
  physicalOverridePending_.store(false, std::memory_order_release);
  active_.store(true, std::memory_order_release);
  xSemaphoreGive(mutex_);
  return true;
}

void PointerInputRuntime::cancelSession() {
  const bool wasActive = active_.exchange(false, std::memory_order_acq_rel);
  physicalOverridePending_.store(false, std::memory_order_release);
  if (!wasActive || mutex_ == nullptr)
    return;
  xSemaphoreTake(mutex_, portMAX_DELAY);
  lastSample_ = controller_.cancelSession();
  xSemaphoreGive(mutex_);
}

PointerQueueResult PointerInputRuntime::enqueue(const PointerEvent &event) {
  if (!active() || mutex_ == nullptr ||
      physicalOverridePending_.load(std::memory_order_acquire))
    return PointerQueueResult::InvalidTransition;
  if (xSemaphoreTake(mutex_, pdMS_TO_TICKS(25)) != pdTRUE)
    return PointerQueueResult::QueueFull;
  const PointerQueueResult result = controller_.enqueue(event);
  xSemaphoreGive(mutex_);
  return result;
}

PointerSample PointerInputRuntime::sample(bool physicalPressed, uint32_t nowMs) {
  if (!active() || mutex_ == nullptr)
    return {};
  if (physicalPressed)
    physicalOverridePending_.store(true, std::memory_order_release);
  if (xSemaphoreTake(mutex_, 0) != pdTRUE) {
    if (physicalPressed)
      return {};
    PointerSample stable = lastSample_;
    stable.changed = false;
    stable.timedOut = false;
    return stable;
  }
  const bool overridePending =
      physicalOverridePending_.exchange(false, std::memory_order_acq_rel);
  if (overridePending && !physicalPressed) {
    // A short physical contact may have been observed while the HTTP task held
    // the mutex. Replay its press/release into the pure controller before any
    // synthetic pointer can resume.
    controller_.sample(true, nowMs);
    lastSample_ = controller_.sample(false, nowMs);
  } else {
    lastSample_ = controller_.sample(physicalPressed || overridePending, nowMs);
  }
  xSemaphoreGive(mutex_);
  return lastSample_;
}

PointerCounters PointerInputRuntime::counters() {
  if (mutex_ == nullptr || xSemaphoreTake(mutex_, pdMS_TO_TICKS(25)) != pdTRUE)
    return {};
  const PointerCounters result = controller_.counters();
  xSemaphoreGive(mutex_);
  return result;
}

PointerInputRuntime &pointerInput() { return sharedPointerInput; }

} // namespace device_debug

#endif
