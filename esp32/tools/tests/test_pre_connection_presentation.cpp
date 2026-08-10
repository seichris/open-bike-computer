#include "../../lib/bicino_style/bicino_visual_style.hpp"
#include "../../lib/ble_navigation/ownership_button_policy.hpp"
#include "../../lib/gui/src/preConnectionPresentation.hpp"

#include <cassert>
#include <cstring>
#include <initializer_list>

using pre_connection_presentation::Phase;
using pre_connection_presentation::Snapshot;

int main() {
  static_assert(bicino_visual_style::NAVIGATION_BLUE_RGB888 == 0x0088FF);
  static_assert(bicino_visual_style::NAVIGATION_BLUE_RGB565 == 0x045F);

  static_assert(pre_connection_presentation::resolve({}) == Phase::Welcome);
  static_assert(pre_connection_presentation::resolve(
                    {false, true, false, false, false, 0}) ==
                Phase::Connecting);
  static_assert(pre_connection_presentation::resolve(
                    {false, true, false, true, false, 123456}) ==
                Phase::PairingComparison);
  static_assert(pre_connection_presentation::resolve(
                    {false, true, false, true, true, 123456}) ==
                Phase::PairingConfirmed);
  static_assert(pre_connection_presentation::resolve(
                    {true, false, false, false, false, 0}) ==
                Phase::WaitingForIPhone);
  static_assert(pre_connection_presentation::resolve(
                    {true, true, false, false, false, 0}) ==
                Phase::Connecting);
  static_assert(pre_connection_presentation::resolve(
                    {true, true, true, false, false, 0}) ==
                Phase::GettingLocation);
  static_assert(pre_connection_presentation::resolve(
                    {true, true, true, true, false, 123456}) ==
                Phase::PairingComparison);
  static_assert(pre_connection_presentation::resolve(
                    {true, false, true, false, false, 0}) ==
                Phase::WaitingForIPhone);
  static_assert(pre_connection_presentation::resolve(
                    {false, false, false, true, false, 123456}) ==
                Phase::Welcome);
  // Ownership-storage failure is represented fail-closed as claimed and
  // disconnected, so adding a new device is never offered while auth is locked.
  static_assert(pre_connection_presentation::resolve(
                    {true, false, false, false, false, 0}) ==
                Phase::WaitingForIPhone);

  struct ContentCase {
    Phase phase;
    pre_connection_presentation::Group group;
    pre_connection_presentation::Artwork artwork;
    const char *headline;
    const char *copy;
  };
  for (const ContentCase test : {
           ContentCase{Phase::Welcome,
                       pre_connection_presentation::Group::Welcome,
                       pre_connection_presentation::Artwork::None, "Welcome",
                       "Download the Bicino app\nand add your new device!"},
           ContentCase{Phase::PairingComparison,
                       pre_connection_presentation::Group::Pairing,
                       pre_connection_presentation::Artwork::None,
                       "Confirm this code",
                       "If it matches your iPhone,\npress either device button."},
           ContentCase{Phase::PairingConfirmed,
                       pre_connection_presentation::Group::Status,
                       pre_connection_presentation::Artwork::PairingConfirmed,
                       "Confirmed here",
                       "Tap Codes Match\non your iPhone."},
           ContentCase{Phase::WaitingForIPhone,
                       pre_connection_presentation::Group::Status,
                       pre_connection_presentation::Artwork::WaitingForIPhone,
                       "Waiting for iPhone", "Open Bicino on your iPhone."},
           ContentCase{Phase::Connecting,
                       pre_connection_presentation::Group::Status,
                       pre_connection_presentation::Artwork::Connecting,
                       "Connecting...", "Creating a secure connection."},
           ContentCase{Phase::GettingLocation,
                       pre_connection_presentation::Group::Status,
                       pre_connection_presentation::Artwork::GettingLocation,
                       "iPhone connected", "Getting your location..."},
       }) {
    const auto content = pre_connection_presentation::content(test.phase);
    assert(content.group == test.group);
    assert(content.artwork == test.artwork);
    assert(std::strcmp(content.headline, test.headline) == 0);
    assert(std::strcmp(content.copy, test.copy) == 0);
    assert(std::strcmp(content.headline, "ADD") != 0);
    assert(std::strcmp(content.headline, "PAIR") != 0);
    assert(std::strcmp(content.headline, "AUTH") != 0);
    assert(std::strcmp(content.headline, "LINK") != 0);
  }

  static_assert(pre_connection_presentation::needsUpdate(
      false, Phase::Welcome, 0, Phase::Welcome, 0));
  static_assert(!pre_connection_presentation::needsUpdate(
      true, Phase::Welcome, 0, Phase::Welcome, 0));
  static_assert(pre_connection_presentation::needsUpdate(
      true, Phase::Welcome, 0, Phase::Connecting, 0));
  static_assert(!pre_connection_presentation::needsUpdate(
      true, Phase::PairingComparison, 123456, Phase::PairingComparison,
      123456));
  static_assert(pre_connection_presentation::needsUpdate(
      true, Phase::PairingComparison, 123456, Phase::PairingComparison,
      654321));

  ownership_button_policy::ComparisonRenderGate renderGate;
  int order[2] = {0, 0};
  int orderCount = 0;
  const Snapshot pairingSnapshot{false, true, false, true, false, 123456};
  pre_connection_presentation::presentThenUpdateComparisonGate(
      pairingSnapshot, 7,
      [&](const Snapshot &, Phase phase) {
        order[orderCount++] = 1;
        assert(phase == Phase::PairingComparison);
        assert(renderGate.renderedGeneration() == 0);
      },
      [&](uint32_t generation) {
        order[orderCount++] = 2;
        renderGate.request(generation);
      },
      [&] { assert(false); });
  assert(orderCount == 2 && order[0] == 1 && order[1] == 2);
  assert(renderGate.renderedGeneration() == 0);
  renderGate.displayFlushed();
  assert(renderGate.renderedGeneration() == 7);

  // Replaying the same snapshot must not revoke a comparison that has already
  // reached the panel, while a confirmed or disconnected snapshot cancels it.
  pre_connection_presentation::presentThenUpdateComparisonGate(
      pairingSnapshot, 7, [](const Snapshot &, Phase) {},
      [&](uint32_t generation) { renderGate.request(generation); },
      [&] { assert(false); });
  assert(renderGate.renderedGeneration() == 7);
  const Snapshot confirmedSnapshot{false, true, false, true, true, 123456};
  pre_connection_presentation::presentThenUpdateComparisonGate(
      confirmedSnapshot, 7,
      [](const Snapshot &, Phase phase) {
        assert(phase == Phase::PairingConfirmed);
      },
      [&](uint32_t) { assert(false); }, [&] { renderGate.cancel(); });
  assert(renderGate.renderedGeneration() == 0);

  struct CodeCase {
    uint32_t code;
    const char *expected;
  };
  for (const CodeCase test : {
           CodeCase{0, "000 000"},
           CodeCase{42, "000 042"},
           CodeCase{123456, "123 456"},
           CodeCase{999999, "999 999"},
       }) {
    char text[8];
    pre_connection_presentation::formatPairingCode(test.code, text);
    assert(std::strcmp(text, test.expected) == 0);
  }
  return 0;
}
