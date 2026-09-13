#include "../../lib/gui/src/worldRadioPresentation.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  using namespace world_radio_presentation;
  using State = world_radio_protocol::PlaybackState;
  world_radio_protocol::Status status{};
  status.state = State::Playing;
  assert(showPauseIcon(status.state));
  assert(std::strcmp(statusText(status), "") == 0);
  std::strcpy(status.message, "Playing on iPhone");
  assert(std::strcmp(statusText(status), "") == 0);
  status.state = State::Error;
  std::strcpy(status.message, "Stream unavailable");
  assert(std::strcmp(statusText(status), "") == 0);
  status.message[0] = '\0';
  for (State state : {State::Idle, State::Searching, State::Connecting,
                      State::Buffering, State::Paused, State::NoStations,
                      State::Error}) {
    status.state = state;
    assert(!showPauseIcon(state));
    assert(statusText(status)[0] == '\0');
    std::strcpy(status.message, "No station could be played");
    assert(statusText(status)[0] == '\0');
    status.message[0] = '\0';
    assert(reticleState(state, false) == Reticle::Gray);
    const bool busy = state == State::Searching || state == State::Connecting ||
                      state == State::Buffering;
    assert(reticleState(state, true) ==
           (busy ? Reticle::PulsingGreen : Reticle::Gray));
  }
  assert(reticleState(State::Playing, true) == Reticle::Green);
  assert(reticleState(State::Playing, false) == Reticle::Gray);

  // Every corner of every touch target stays inside the 1.75 circular panel,
  // with eight pixels of clearance. Check the rectangular 2.06 viewport too.
  for (int width : {466, 410}) {
    const int height = width == 466 ? 466 : 502;
    for (int offset : {-SIDE_CONTROL_OFFSET, 0, SIDE_CONTROL_OFFSET}) {
      const int buttonWidth = offset == 0 ? PLAY_CONTROL_WIDTH : SIDE_CONTROL_WIDTH;
      const int left = width / 2 + offset - buttonWidth / 2;
      const int bottom = height - CONTROL_BOTTOM_INSET;
      const int top = bottom - CONTROL_HEIGHT;
      assert(left >= 0 && left + buttonWidth <= width);
      // Status label is 17px high, below the station and place labels.
      assert(top >= height - PANEL_HEIGHT + 10 + 59 + 17 + 8);
      for (int x : {left, left + buttonWidth}) {
        for (int y : {top, bottom}) {
          if (width == height) {
            const int dx = x - width / 2;
            const int dy = y - height / 2;
            const int radius = width / 2 - 8;
            assert(dx * dx + dy * dy <= radius * radius);
          }
        }
      }
    }
  }
  std::cout << "World Radio presentation tests passed\n";
}
