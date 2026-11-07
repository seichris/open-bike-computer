#if defined(WAVESHARE_EPAPER_397)
#include "board_input.hpp"
#include "button_policy.hpp"
#include "board_traits.hpp"
#include "epaper_display.hpp"
#include "epaper_ui.hpp"
#include "ble_navigation.hpp"
#include <Arduino.h>

namespace board_input {
namespace {
Button up, center, down;
bool pairingWasVisible = false;
}
void begin() {
  pinMode(board_traits::up, INPUT_PULLUP);
  pinMode(board_traits::center, INPUT_PULLUP);
  pinMode(board_traits::down, INPUT_PULLUP);
}
void requireFreshPairingInput() {
  up.requireRelease(); center.requireRelease(); down.requireRelease();
}
void process() {
  const uint32_t now = millis();
  const bool pairing = bleNavServer.hasOwnershipPairingCode();
  const bool visible = pairing && epaper::pairingPresented();
  if (pairing && (!visible || !pairingWasVisible)) requireFreshPairingInput();
  pairingWasVisible = visible;
  const bool menu = epaper_ui::contextOpen();
  const Event u = up.sample(digitalRead(board_traits::up) == LOW, now, menu);
  const Event c = center.sample(digitalRead(board_traits::center) == LOW, now);
  const Event d = down.sample(digitalRead(board_traits::down) == LOW, now, menu);
#ifdef EPAPER_DISPLAY_TEST
  if (u == Event::Press) epaper::diagnosticPattern(-1);
  if (d == Event::Press) epaper::diagnosticPattern(1);
  if (u == Event::Hold) epaper::sleep();
  if (d == Event::Hold) { epaper::wake(); epaper::diagnosticPattern(0); }
  if (c == Event::Hold) epaper::diagnosticFault(true);
  if (c == Event::Press) epaper::diagnosticFault(false);
  return;
#endif
  if (pairing) {
    epaper_ui::closeContext();
    if (visible && c == Event::Press) bleNavServer.confirmOwnershipPairing();
    if (visible && (u == Event::Hold || d == Event::Hold))
      bleNavServer.cancelOwnershipPairing();
    return;
  }
  if (u != Event::None) {
    if (menu) epaper_ui::moveFocus(-1);
    else if (u == Event::Press) epaper_ui::previousScreen();
  }
  if (d != Event::None) {
    if (menu) epaper_ui::moveFocus(1);
    else if (d == Event::Press) epaper_ui::nextScreen();
  }
  if (c == Event::Hold) epaper_ui::context();
  else if (c == Event::Press) epaper_ui::activate();
}
}
#endif
