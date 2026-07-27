#pragma once

namespace map_tile_transition {

struct State {
  bool pending = false;

  constexpr void begin() { pending = true; }
  constexpr void cancel() { pending = false; }

  constexpr bool canReveal(bool positionMoved, bool redrawPending) const {
    return pending && !positionMoved && !redrawPending;
  }

  constexpr void complete() { pending = false; }
};

} // namespace map_tile_transition
