#pragma once

#include "device_debug_protocol.hpp"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include <atomic>
#include <cstddef>
#include <cstdint>

#ifndef DEVICE_REMOTE_DEBUG
#define DEVICE_REMOTE_DEBUG 0
#endif

namespace device_debug {

enum class FrameStoreStartResult : uint8_t {
  Started,
  UnsupportedBuild,
  InvalidGeometry,
  FullFrameUnavailable,
  MutexAllocationFailed,
  InsufficientPsram,
};

struct FrameStoreCounters {
  uint32_t captured = 0;
  uint32_t skippedCadence = 0;
  uint32_t skippedLocked = 0;
  uint32_t rejectedFrame = 0;
  uint32_t captureErrors = 0;
  uint32_t lastCopyDurationUs = 0;
  uint32_t maxCopyDurationUs = 0;
};

struct FrameStoreMemory {
  uint32_t freeBefore = 0;
  uint32_t largestBefore = 0;
  uint32_t freeAfterAllocate = 0;
  uint32_t largestAfterAllocate = 0;
  uint32_t freeAfterRelease = 0;
  uint32_t largestAfterRelease = 0;
};

struct FrameSnapshot {
  const uint8_t *pixels = nullptr;
  uint32_t sequence = 0;
  uint32_t capturedAtMs = 0;
  uint16_t width = 0;
  uint16_t height = 0;
  uint16_t strideBytes = 0;
  uint32_t payloadBytes = 0;
};

class FrameStore {
public:
  bool prepare();
  FrameStoreStartResult begin(TargetGeometry geometry,
                              bool fullFrameRgb565Available);
  void end();
  bool active() const { return active_.load(std::memory_order_acquire); }
  void requestNextFrame();
  bool uiRefreshDue(uint32_t nowMs) const;
  void offerPanelFrame(const uint16_t *pixels, uint16_t width, uint16_t height,
                       uint16_t strideBytes, uint32_t capturedAtMs);
  bool acquireSnapshot(uint32_t afterSequence, FrameSnapshot &snapshot);
  void releaseSnapshot();
  uint32_t currentSequence() const {
    return sequence_.load(std::memory_order_acquire);
  }
  TargetGeometry geometry() const { return geometry_; }
  FrameStoreCounters counters() const;
  FrameStoreMemory memory() const { return memory_; }
  FrameStoreStartResult lastStartResult() const { return lastStartResult_; }

private:
  bool ensureMutex();
  void resetCounters();

  SemaphoreHandle_t mutex_ = nullptr;
  uint8_t *buffer_ = nullptr;
  TargetGeometry geometry_{};
  uint32_t payloadBytes_ = 0;
  uint32_t capturedAtMs_ = 0;
  uint32_t lastCaptureMs_ = 0;
  bool consumerLocked_ = false;
  std::atomic<bool> active_{false};
  std::atomic<bool> captureRequested_{false};
  std::atomic<uint32_t> sequence_{0};
  std::atomic<uint32_t> captured_{0};
  std::atomic<uint32_t> skippedCadence_{0};
  std::atomic<uint32_t> skippedLocked_{0};
  std::atomic<uint32_t> rejectedFrame_{0};
  std::atomic<uint32_t> captureErrors_{0};
  std::atomic<uint32_t> lastCopyDurationUs_{0};
  std::atomic<uint32_t> maxCopyDurationUs_{0};
  FrameStoreMemory memory_{};
  FrameStoreStartResult lastStartResult_ =
      FrameStoreStartResult::UnsupportedBuild;
};

FrameStore &frameStore();

} // namespace device_debug
