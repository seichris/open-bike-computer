#pragma once

namespace map_tile_transition {

struct State {
  bool pending = false;
  bool replacementFramePublished = false;

  constexpr void begin() {
    pending = true;
    replacementFramePublished = false;
  }

  constexpr void noteFramePublished() {
    if (pending)
      replacementFramePublished = true;
  }

  constexpr void cancel() {
    pending = false;
    replacementFramePublished = false;
  }

  constexpr bool canReveal(bool positionMoved, bool redrawPending) const {
    return pending && replacementFramePublished && !positionMoved &&
           !redrawPending;
  }

  constexpr void complete() { cancel(); }
};

} // namespace map_tile_transition
