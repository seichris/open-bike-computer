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

  // Touch targets fill the bottom left/right halves; circular icon faces are
  // inset to remain fully visible on the round 1.75 display.
  for (int width : {466, 410}) {
    const int height = width == 466 ? 466 : 502;
    assert(CONTROL_HIT_HEIGHT > 2 * CONTROL_ICON_SIZE);
    for (int center : {width / 4, width * 3 / 4}) {
      const int buttonWidth = CONTROL_ICON_SIZE;
      const int left = center - buttonWidth / 2;
      const int bottom = height - CONTROL_ICON_BOTTOM;
      const int top = bottom - CONTROL_ICON_SIZE;
      assert(left >= 0 && left + buttonWidth <= width);
      assert(top >= height - CONTROL_HIT_HEIGHT);
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
