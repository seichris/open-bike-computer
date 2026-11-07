#pragma once
#include <cstdint>

namespace board_input {
enum class Event : uint8_t { None, Press, Hold, Repeat };

class Button {
public:
  // Discard queued/held input at ownership boundaries. A stable release is
  // required before a subsequent press can reach the application.
  void requireRelease() { blocked_ = true; releasedAt_ = 0; }
  Event sample(bool pressed, uint32_t now, bool repeat = false) {
    if (pressed != raw_) { raw_ = pressed; changedAt_ = now; }
    if (blocked_) {
      if (pressed) releasedAt_ = 0;
      else if (!releasedAt_) releasedAt_ = now;
      else if (uint32_t(now - releasedAt_) >= 40) {
        blocked_ = false; stable_ = false; held_ = false;
      }
      return Event::None;
    }
    if (uint32_t(now - changedAt_) < 40) return Event::None;
    if (stable_ != raw_) {
      stable_ = raw_;
      if (stable_) { pressedAt_ = now; repeatedAt_ = now; held_ = false; }
      // Short actions occur on release, so a hold never also activates an item.
      else if (!held_) return Event::Press;
    }
    if (!stable_) return Event::None;
    if (!held_ && uint32_t(now - pressedAt_) >= 700) {
      held_ = true; repeatedAt_ = now;
      return Event::Hold;
    }
    if (held_ && repeat && uint32_t(now - repeatedAt_) >= 250) {
      repeatedAt_ = now;
      return Event::Repeat;
    }
    return Event::None;
  }
private:
  bool raw_ = false, stable_ = false, held_ = false, blocked_ = true;
  uint32_t changedAt_ = 0, pressedAt_ = 0, repeatedAt_ = 0, releasedAt_ = 0;
};
} // namespace board_input
