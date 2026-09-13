#pragma once

#include "../../world_radio/world_radio_protocol.hpp"

namespace world_radio_presentation {

constexpr int PANEL_HEIGHT = 190;
constexpr int CONTROL_BOTTOM_INSET = 46;
constexpr int CONTROL_HEIGHT = 48;
constexpr int SIDE_CONTROL_WIDTH = 56;
constexpr int PLAY_CONTROL_WIDTH = 64;
constexpr int SIDE_CONTROL_OFFSET = 88;

constexpr bool showPauseIcon(world_radio_protocol::PlaybackState state) {
  return state == world_radio_protocol::PlaybackState::Playing;
}

enum class Reticle { Gray, Green, PulsingGreen };

constexpr Reticle reticleState(world_radio_protocol::PlaybackState state,
                               bool phoneReady) {
  using State = world_radio_protocol::PlaybackState;
  if (!phoneReady) return Reticle::Gray;
  switch (state) {
  case State::Searching:
  case State::Connecting:
  case State::Buffering: return Reticle::PulsingGreen;
  case State::Playing: return Reticle::Green;
  default: return Reticle::Gray;
  }
}

inline const char *statusText(const world_radio_protocol::Status &) {
  // The reticle represents playback state, including messages from older phones.
  return "";
}

} // namespace world_radio_presentation
