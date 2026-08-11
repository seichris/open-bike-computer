#include "device_debug_frame_store.hpp"

#include <esp_heap_caps.h>

#include <cstring>

namespace device_debug {
namespace {

FrameStore sharedFrameStore;

uint32_t freePsram() {
  return heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
}

uint32_t largestPsramBlock() {
  return heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
}

} // namespace

bool FrameStore::ensureMutex() {
  if (mutex_ == nullptr)
    mutex_ = xSemaphoreCreateMutex();
  return mutex_ != nullptr;
}

bool FrameStore::prepare() {
#if !DEVICE_REMOTE_DEBUG
  return false;
#else
  return ensureMutex();
#endif
}

FrameStoreStartResult FrameStore::begin(TargetGeometry geometry,
                                        bool fullFrameRgb565Available) {
#if !DEVICE_REMOTE_DEBUG
  (void)geometry;
  (void)fullFrameRgb565Available;
  lastStartResult_ = FrameStoreStartResult::UnsupportedBuild;
  return lastStartResult_;
#else
  if (active())
    return FrameStoreStartResult::Started;
  if (geometry.width == 0 || geometry.height == 0 ||
      static_cast<uint32_t>(geometry.width) * 2U > UINT16_MAX) {
    lastStartResult_ = FrameStoreStartResult::InvalidGeometry;
    return lastStartResult_;
  }
  if (!fullFrameRgb565Available) {
    lastStartResult_ = FrameStoreStartResult::FullFrameUnavailable;
    return lastStartResult_;
  }
  if (!ensureMutex()) {
    lastStartResult_ = FrameStoreStartResult::MutexAllocationFailed;
    return lastStartResult_;
  }

  geometry_ = geometry;
  payloadBytes_ = static_cast<uint32_t>(geometry.width) * geometry.height * 2U;
  memory_ = {};
  memory_.freeBefore = freePsram();
  memory_.largestBefore = largestPsramBlock();
  buffer_ = static_cast<uint8_t *>(heap_caps_aligned_alloc(
      16, payloadBytes_, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (buffer_ == nullptr) {
    Serial.printf(
        "REMOTE_DEBUG_FRAME: allocation_failed requested=%lu free=%lu "
        "largest=%lu\n",
        static_cast<unsigned long>(payloadBytes_),
        static_cast<unsigned long>(memory_.freeBefore),
        static_cast<unsigned long>(memory_.largestBefore));
    payloadBytes_ = 0;
    geometry_ = {};
    ++captureErrors_;
    lastStartResult_ = FrameStoreStartResult::InsufficientPsram;
    return lastStartResult_;
  }
  memory_.freeAfterAllocate = freePsram();
  memory_.largestAfterAllocate = largestPsramBlock();
  resetCounters();
  sequence_.store(0, std::memory_order_release);
  capturedAtMs_ = 0;
  lastCaptureMs_ = 0;
  consumerLocked_ = false;
  captureRequested_.store(true, std::memory_order_release);
  active_.store(true, std::memory_order_release);
  lastStartResult_ = FrameStoreStartResult::Started;
  Serial.printf(
      "REMOTE_DEBUG_FRAME: allocated=%lu free_before=%lu largest_before=%lu "
      "free_after=%lu largest_after=%lu\n",
      static_cast<unsigned long>(payloadBytes_),
      static_cast<unsigned long>(memory_.freeBefore),
      static_cast<unsigned long>(memory_.largestBefore),
      static_cast<unsigned long>(memory_.freeAfterAllocate),
      static_cast<unsigned long>(memory_.largestAfterAllocate));
  return lastStartResult_;
#endif
}

void FrameStore::end() {
  active_.store(false, std::memory_order_release);
  captureRequested_.store(false, std::memory_order_release);
  if (mutex_ == nullptr)
    return;
  xSemaphoreTake(mutex_, portMAX_DELAY);
  uint8_t *released = buffer_;
  buffer_ = nullptr;
  payloadBytes_ = 0;
  geometry_ = {};
  consumerLocked_ = false;
  xSemaphoreGive(mutex_);
  if (released != nullptr)
    heap_caps_free(released);
  memory_.freeAfterRelease = freePsram();
  memory_.largestAfterRelease = largestPsramBlock();
#if DEVICE_REMOTE_DEBUG
  Serial.printf("REMOTE_DEBUG_FRAME: released free=%lu largest=%lu\n",
                static_cast<unsigned long>(memory_.freeAfterRelease),
                static_cast<unsigned long>(memory_.largestAfterRelease));
#endif
}

void FrameStore::requestNextFrame() {
  if (active())
    captureRequested_.store(true, std::memory_order_release);
}

bool FrameStore::uiRefreshDue(uint32_t nowMs) const {
  return captureRequestDue(
      active(), captureRequested_.load(std::memory_order_acquire),
      lastCaptureMs_, nowMs);
}

void FrameStore::offerPanelFrame(const uint16_t *pixels, uint16_t width,
                                 uint16_t height, uint16_t strideBytes,
                                 uint32_t capturedAtMs) {
  if (!active())
    return;
  const bool requested =
      captureRequested_.exchange(false, std::memory_order_acq_rel);
  if (!requested)
    return;
  if (!captureRequestDue(true, true, lastCaptureMs_, capturedAtMs)) {
    ++skippedCadence_;
    captureRequested_.store(true, std::memory_order_release);
    return;
  }
  if (pixels == nullptr || width != geometry_.width ||
      height != geometry_.height ||
      strideBytes != static_cast<uint32_t>(geometry_.width) * 2U) {
    ++rejectedFrame_;
    captureRequested_.store(true, std::memory_order_release);
    return;
  }
  if (mutex_ == nullptr || xSemaphoreTake(mutex_, 0) != pdTRUE) {
    ++skippedLocked_;
    captureRequested_.store(true, std::memory_order_release);
    return;
  }
  if (!active() || buffer_ == nullptr) {
    xSemaphoreGive(mutex_);
    return;
  }
  const uint32_t startedUs = micros();
  std::memcpy(buffer_, pixels, payloadBytes_);
  const uint32_t durationUs = micros() - startedUs;
  capturedAtMs_ = capturedAtMs;
  lastCaptureMs_ = capturedAtMs;
  uint32_t sequence = sequence_.load(std::memory_order_relaxed) + 1U;
  if (sequence == 0)
    sequence = 1;
  sequence_.store(sequence, std::memory_order_release);
  ++captured_;
  lastCopyDurationUs_.store(durationUs, std::memory_order_relaxed);
  uint32_t observedMaximum = maxCopyDurationUs_.load(std::memory_order_relaxed);
  while (durationUs > observedMaximum &&
         !maxCopyDurationUs_.compare_exchange_weak(
             observedMaximum, durationUs, std::memory_order_relaxed)) {
  }
  xSemaphoreGive(mutex_);
}

bool FrameStore::acquireSnapshot(uint32_t afterSequence,
                                 FrameSnapshot &snapshot) {
  snapshot = {};
  if (!active() || mutex_ == nullptr ||
      xSemaphoreTake(mutex_, pdMS_TO_TICKS(50)) != pdTRUE)
    return false;
  const uint32_t sequence = sequence_.load(std::memory_order_acquire);
  if (!active() || buffer_ == nullptr || sequence == 0 ||
      sequence == afterSequence) {
    xSemaphoreGive(mutex_);
    return false;
  }
  consumerLocked_ = true;
  snapshot = {buffer_, sequence, capturedAtMs_, geometry_.width,
              geometry_.height, static_cast<uint16_t>(geometry_.width * 2U),
              payloadBytes_};
  return true;
}

void FrameStore::releaseSnapshot() {
  if (mutex_ != nullptr && consumerLocked_) {
    consumerLocked_ = false;
    xSemaphoreGive(mutex_);
  }
}

FrameStoreCounters FrameStore::counters() const {
  return {captured_.load(std::memory_order_relaxed),
          skippedCadence_.load(std::memory_order_relaxed),
          skippedLocked_.load(std::memory_order_relaxed),
          rejectedFrame_.load(std::memory_order_relaxed),
          captureErrors_.load(std::memory_order_relaxed),
          lastCopyDurationUs_.load(std::memory_order_relaxed),
          maxCopyDurationUs_.load(std::memory_order_relaxed)};
}

void FrameStore::resetCounters() {
  captured_.store(0, std::memory_order_relaxed);
  skippedCadence_.store(0, std::memory_order_relaxed);
  skippedLocked_.store(0, std::memory_order_relaxed);
  rejectedFrame_.store(0, std::memory_order_relaxed);
  captureErrors_.store(0, std::memory_order_relaxed);
  lastCopyDurationUs_.store(0, std::memory_order_relaxed);
  maxCopyDurationUs_.store(0, std::memory_order_relaxed);
}

FrameStore &frameStore() { return sharedFrameStore; }

} // namespace device_debug
