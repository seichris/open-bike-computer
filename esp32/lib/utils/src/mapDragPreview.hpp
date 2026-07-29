/**
 * @file mapDragPreview.hpp
 * @brief Pure drag-preview accumulation and deferred-settlement state.
 */

#pragma once

#include <cstdint>

namespace map_drag_preview {

constexpr int16_t kDragStartThresholdPx = 14;
constexpr int16_t kSampleThresholdPx = 2;
constexpr uint32_t kSettlementDelayMs = 180;

struct CanvasExtent {
  uint16_t width;
  uint16_t height;
};

struct Offset {
  int32_t x = 0;
  int32_t y = 0;
};

class Controller {
public:
  bool begin() {
    if (active_)
      return false;
    active_ = true;
    sessionBase_ = committed_;
    return true;
  }

  Offset preview(int16_t sessionDx, int16_t sessionDy) const {
    if (!active_)
      return committed_;
    return {sessionBase_.x + sessionDx, sessionBase_.y + sessionDy};
  }

  Offset commit(int16_t sessionDx, int16_t sessionDy, uint32_t nowMs) {
    if (!active_)
      return committed_;
    committed_ = preview(sessionDx, sessionDy);
    active_ = false;
    settlementPending_ = true;
    committedAtMs_ = nowMs;
    return committed_;
  }

  // Keep the accumulated controller state aligned with a bounded visual
  // presentation. This is used when the rolling raster window clamps a drag at
  // its prepared edge so a following drag can reverse immediately instead of
  // first paying back an invisible overshoot.
  void replaceCommittedOffset(Offset offset) {
    committed_ = offset;
    sessionBase_ = offset;
  }

  bool blocksRender(uint32_t nowMs,
                    uint32_t settlementDelayMs = kSettlementDelayMs) const {
    return active_ ||
           (settlementPending_ &&
            static_cast<uint32_t>(nowMs - committedAtMs_) <
                settlementDelayMs);
  }

  void reset() {
    active_ = false;
    settlementPending_ = false;
    sessionBase_ = {};
    committed_ = {};
    committedAtMs_ = 0;
  }

  bool active() const { return active_; }
  bool settlementPending() const { return settlementPending_; }
  Offset committedOffset() const { return committed_; }

private:
  bool active_ = false;
  bool settlementPending_ = false;
  Offset sessionBase_ = {};
  Offset committed_ = {};
  uint32_t committedAtMs_ = 0;
};

} // namespace map_drag_preview
