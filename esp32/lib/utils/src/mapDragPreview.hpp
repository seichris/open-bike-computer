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

  bool blocksRender(uint32_t nowMs) const {
    return active_ ||
           (settlementPending_ &&
            static_cast<uint32_t>(nowMs - committedAtMs_) <
                kSettlementDelayMs);
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
