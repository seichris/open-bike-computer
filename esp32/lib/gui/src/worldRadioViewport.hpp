#pragma once

#include <algorithm>
#include <cstdint>
#include "../../utils/src/mapDragPreview.hpp"

namespace world_radio_viewport {

// A modest 2x view keeps useful geographic detail on the small screen. Scaling
// is display-only: the three wrapped images still share the same 1 MiB buffer.
inline constexpr int SCALE = 2;

class Camera {
public:
  void configure(int width, int height, int mapWidth, int mapHeight) {
    width_ = width;
    height_ = height;
    mapWidth_ = mapWidth;
    mapHeight_ = mapHeight;
    centerOn(200000000, 0);
  }

  void centerOn(int32_t latitude, int32_t longitude) {
    const int64_t x = (static_cast<int64_t>(longitude) + 1800000000LL) * mapWidth_ / 3600000000LL;
    const int64_t y = (900000000LL - latitude) * mapHeight_ / 1800000000LL;
    x_ = anchorX() - static_cast<int>(x);
    y_ = anchorY() - static_cast<int>(y);
    constrain();
  }

  bool pan(int dx, int dy) {
    const int previousX = x_;
    const int previousY = y_;
    x_ += dx;
    y_ += dy;
    constrain();
    return x_ != previousX || y_ != previousY;
  }

  // Touch coordinates now use the actual inverse of the panel flush rotation.
  // Content follows the corrected pointer one pixel per input pixel.
  bool drag(int dx, int dy) { return pan(dx, dy); }

  int x() const { return x_; }
  int y() const { return y_; }
  int anchorX() const { return width_ / 2; }
  int anchorY() const { return height_ / 2; }

  int32_t longitude() const {
    const int pixel = (anchorX() - x_) % mapWidth_;
    return static_cast<int32_t>(static_cast<int64_t>(pixel) * 3600000000LL / mapWidth_ - 1800000000LL);
  }
  int32_t latitude() const {
    return static_cast<int32_t>(900000000LL - static_cast<int64_t>(anchorY() - y_) * 1800000000LL / mapHeight_);
  }

private:
  void constrain() {
    x_ %= mapWidth_;
    if (x_ > 0) x_ -= mapWidth_;
    y_ = std::max(height_ - mapHeight_, std::min(0, y_));
  }
  int width_ = 466;
  int height_ = 276;
  int mapWidth_ = 2048;
  int mapHeight_ = 1024;
  int x_ = 0;
  int y_ = 0;
};

// Reuse projection-independent accumulation/settlement, not navigation's
// renderer or camera. The radio continues to draw immediately during a drag;
// only the directory lookup waits for the shared settlement interval.
class DragSession {
public:
  void begin(int16_t x, int16_t y) {
    pressX_ = x;
    pressY_ = y;
    dx_ = dy_ = 0;
    moved_ = false;
    applied_ = preview_.committedOffset();
    preview_.begin();
  }

  bool sample(int16_t x, int16_t y, Camera &camera) {
    if (!preview_.active()) return false;
    dx_ = x - pressX_;
    dy_ = y - pressY_;
    // Keep radio's existing 10px Manhattan tap threshold as UI policy.
    if (!moved_ && std::abs(dx_) + std::abs(dy_) < 10) return false;
    moved_ = true;
    const auto offset = preview_.preview(dx_, dy_);
    const bool changed = camera.drag(offset.x - applied_.x, offset.y - applied_.y);
    // Track raw input, not clamped/wrapped camera coordinates: reversal must
    // respond immediately at a pole or across the antimeridian.
    applied_ = offset;
    return changed;
  }

  bool finish(uint32_t nowMs) {
    if (!preview_.active()) return false;
    if (!moved_) { cancel(); return false; }
    preview_.commit(dx_, dy_, nowMs);
    return true;
  }

  bool active() const { return preview_.active(); }
  bool selectionReady(uint32_t nowMs) const {
    return preview_.settlementPending() && !preview_.blocksRender(nowMs);
  }
  void cancel() {
    preview_.reset();
    applied_ = {};
    moved_ = false;
  }

private:
  map_drag_preview::Controller preview_;
  map_drag_preview::Offset applied_{};
  int16_t pressX_ = 0, pressY_ = 0, dx_ = 0, dy_ = 0;
  bool moved_ = false;
};

// Ordinary playback/status updates must never steer the user's camera.
inline bool mayFocusStation(bool dragging, uint32_t pendingRequest,
                            uint32_t pendingRevision, uint32_t request,
                            uint32_t revision) {
  return !dragging && pendingRequest != 0 && pendingRequest == request &&
         pendingRevision != revision;
}

} // namespace world_radio_viewport
