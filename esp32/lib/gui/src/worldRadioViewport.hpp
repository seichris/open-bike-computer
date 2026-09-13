#pragma once

#include <algorithm>
#include <cstdint>

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

  void pan(int dx, int dy) {
    x_ += dx;
    y_ += dy;
    constrain();
  }

  // Reverse both input axes for the device's observed drag orientation.
  // Keep the camera movement at one pixel per input pixel.
  void drag(int dx, int dy) { pan(-dx, -dy); }

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

// Ordinary playback/status updates must never steer the user's camera.
inline bool mayFocusStation(bool dragging, uint32_t pendingRequest,
                            uint32_t pendingRevision, uint32_t request,
                            uint32_t revision) {
  return !dragging && pendingRequest != 0 && pendingRequest == request &&
         pendingRevision != revision;
}

} // namespace world_radio_viewport
