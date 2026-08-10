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
  static_assert(!pre_connection_presentation::isVisibleComparisonFrame(
      false, Phase::PairingComparison));
  static_assert(!pre_connection_presentation::isVisibleComparisonFrame(
      true, Phase::PairingConfirmed));
  static_assert(pre_connection_presentation::isVisibleComparisonFrame(
      true, Phase::PairingComparison));

  // A pairing presentation can interrupt an existing Map/Ride Stats session.
  // Navigation received before or during the comparison cannot hide it. Once
  // pairing ends, the next fresh GPS fix must be able to restore Map even
  // though the legacy "GPS received" latch is already true.
  pre_connection_presentation::MapReentryPolicy gpsReentry;
  assert(!gpsReentry.updatePhase(Phase::GettingLocation));
  assert(!gpsReentry.noteNavigationInput(true));
  assert(gpsReentry.updatePhase(Phase::PairingComparison));
  assert(!gpsReentry.allowsPendingMapEntry());
  assert(gpsReentry.needsFreshNavigationInput());
  assert(!gpsReentry.noteNavigationInput(true));
  assert(gpsReentry.needsFreshNavigationInput());
  assert(!gpsReentry.updatePhase(Phase::PairingConfirmed));
  assert(!gpsReentry.allowsPendingMapEntry());
  assert(!gpsReentry.updatePhase(Phase::GettingLocation));
  assert(gpsReentry.allowsPendingMapEntry());
  assert(gpsReentry.noteNavigationInput(true));
  assert(!gpsReentry.needsFreshNavigationInput());
  assert(!gpsReentry.noteNavigationInput(true));

  // Route-only input follows the same re-entry contract after a later pairing
  // attempt is cancelled or times out to the waiting screen.
  pre_connection_presentation::MapReentryPolicy routeReentry;
  assert(routeReentry.updatePhase(Phase::PairingComparison));
  assert(!routeReentry.noteNavigationInput(true));
  assert(!routeReentry.updatePhase(Phase::WaitingForIPhone));
  assert(routeReentry.noteNavigationInput(true));
  assert(!routeReentry.noteNavigationInput(true));

  // The physical render gate and map policy jointly guarantee that GPS cannot
  // replace PairingComparison either before or after its first panel flush.
  pre_connection_presentation::MapReentryPolicy comparisonReentry;
  ownership_button_policy::ComparisonRenderGate comparisonRenderGate;
  assert(comparisonReentry.updatePhase(Phase::PairingComparison));
  comparisonRenderGate.request(19);
  assert(!comparisonReentry.noteNavigationInput(true));
  assert(!comparisonReentry.allowsPendingMapEntry());
  assert(comparisonRenderGate.renderedGeneration() == 0);
  comparisonRenderGate.displayFlushed();
  assert(comparisonRenderGate.renderedGeneration() == 19);
  assert(!comparisonReentry.noteNavigationInput(true));
  assert(!comparisonReentry.allowsPendingMapEntry());
  assert(!comparisonReentry.updatePhase(Phase::Connecting));
  assert(comparisonReentry.noteNavigationInput(true));
  assert(comparisonReentry.allowsPendingMapEntry());

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

  ownership_button_policy::ComparisonRenderGate hiddenScreenGate;
  hiddenScreenGate.request(11);
  if (pre_connection_presentation::isVisibleComparisonFrame(
          false, Phase::PairingComparison)) {
    hiddenScreenGate.displayFlushed();
  }
  assert(hiddenScreenGate.renderedGeneration() == 0);
  assert(!hiddenScreenGate.consumeRendered(11));
  if (pre_connection_presentation::isVisibleComparisonFrame(
          true, Phase::PairingComparison)) {
    hiddenScreenGate.displayFlushed();
  }
  assert(hiddenScreenGate.renderedGeneration() == 11);
  assert(hiddenScreenGate.consumeRendered(11));

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
