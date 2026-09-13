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

inline const char *statusText(const world_radio_protocol::Status &status) {
  using State = world_radio_protocol::PlaybackState;
  // Older phone builds send "Playing on iPhone" in the message field too.
  // Playback is already represented by the pause icon, so suppress both paths.
  if (status.state == State::Playing) {
    return "";
  }
  if (status.message[0] != '\0') {
    return status.message;
  }
  switch (status.state) {
  case State::Idle: return "Drag the map to tune in";
  case State::Searching: return "Finding stations...";
  case State::Connecting: return "Connecting...";
  case State::Buffering: return "Buffering...";
  case State::Paused: return "Paused";
  case State::NoStations: return "No stations nearby";
  case State::Error: return "Station unavailable";
  case State::Playing: return "";
  }
  return "";
}

} // namespace world_radio_presentation
