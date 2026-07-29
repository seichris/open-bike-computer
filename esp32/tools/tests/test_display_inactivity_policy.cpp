#include "../../lib/display_power/display_inactivity_policy.hpp"

#include <array>
#include <cassert>
#include <cstdint>
#include <limits>

int main() {
  using display_inactivity::Context;
  using display_inactivity::Mode;
  using display_inactivity::Policy;

  Policy idle;
  idle.begin(1'000);
  assert(idle.update(15'999, {}).current == Mode::Active);
  assert(idle.update(16'000, {}).current == Mode::Dimmed);
  assert(idle.update(45'999, {}).current == Mode::Dimmed);
  assert(idle.update(46'000, {}).current == Mode::DisplayOff);

  // Connection state and replaceable GPS/workout samples are intentionally not
  // policy inputs, so repeated updates alone cannot postpone idle states.
  Policy gpsOnly;
  gpsOnly.begin(0);
  for (uint32_t now = 1'000; now <= 50'000; now += 1'000) {
    gpsOnly.update(now, {});
  }
  assert(gpsOnly.mode() == Mode::DisplayOff);

  gpsOnly.noteMeaningfulActivity(50'001);
  auto wake = gpsOnly.update(50'001, {});
  assert(wake.current == Mode::Active);
  assert(wake.displayWakeRequired);
  assert(!gpsOnly.update(50'002, {}).displayWakeRequired);

  Policy routeWake;
  routeWake.begin(0);
  assert(routeWake.update(45'000, {}).current == Mode::DisplayOff);
  Context routeContext;
  routeContext.navigating = true;
  wake = routeWake.update(45'001, routeContext);
  assert(wake.current == Mode::Active);
  assert(wake.displayWakeRequired);

  Policy transferWake;
  transferWake.begin(0);
  assert(transferWake.update(45'000, {}).current == Mode::DisplayOff);
  Context transferContext;
  transferContext.transferActive = true;
  wake = transferWake.update(45'001, transferContext);
  assert(wake.current == Mode::Transfer);
  assert(wake.displayWakeRequired);

  Policy attentionWake;
  attentionWake.begin(0);
  assert(attentionWake.update(45'000, {}).current == Mode::DisplayOff);
  Context attentionContext;
  attentionContext.attentionActive = true;
  wake = attentionWake.update(45'001, attentionContext);
  assert(wake.current == Mode::Active);
  assert(wake.displayWakeRequired);

  Policy eventWake;
  eventWake.begin(0);
  assert(eventWake.update(45'000, {}).current == Mode::DisplayOff);
  eventWake.noteMeaningfulActivity(45'001);
  wake = eventWake.update(45'001, {});
  assert(wake.current == Mode::Active);
  assert(wake.displayWakeRequired);

  Policy navigation;
  navigation.begin(0);
  Context navigating;
  navigating.navigating = true;
  assert(navigation.update(100'000, navigating).current == Mode::Active);
  assert(navigation.update(200'000, {}).current == Mode::Active);
  assert(navigation.update(215'000, {}).current == Mode::Dimmed);

  Policy transfer;
  transfer.begin(0);
  Context transferring;
  transferring.transferActive = true;
  assert(transfer.update(100'000, transferring).current == Mode::Transfer);
  assert(transfer.update(200'000, {}).current == Mode::Active);
  assert(transfer.update(245'000, {}).current == Mode::DisplayOff);

  Policy attention;
  attention.begin(0);
  Context pairingOrAudio;
  pairingOrAudio.attentionActive = true;
  assert(attention.update(100'000, pairingOrAudio).current == Mode::Active);
  assert(attention.update(145'000, pairingOrAudio).current == Mode::Active);
  assert(attention.update(145'001, {}).current == Mode::Active);

  const auto policyAtMode = [](Mode mode) {
    Policy policy;
    policy.begin(0);
    if (mode == Mode::Dimmed) {
      policy.update(display_inactivity::kDimAfterMs, {});
    } else if (mode == Mode::DisplayOff) {
      policy.update(display_inactivity::kDisplayOffAfterMs, {});
    } else if (mode == Mode::Transfer) {
      Context context;
      context.transferActive = true;
      policy.update(1, context);
    }
    assert(policy.mode() == mode);
    return policy;
  };
  constexpr std::array<Mode, 4> allModes = {
      Mode::Active, Mode::Dimmed, Mode::DisplayOff, Mode::Transfer};
  for (const Mode previous : allModes) {
    // BOOT/touch/screen/error events all enter through the meaningful-activity
    // path and therefore recover Active from every display state.
    Policy event = policyAtMode(previous);
    event.noteMeaningfulActivity(100'000);
    const auto eventUpdate = event.update(100'000, {});
    assert(eventUpdate.current == Mode::Active);
    assert(eventUpdate.displayWakeRequired ==
           (previous == Mode::DisplayOff));

    // Route/navigation start, pairing/ownership, audio, and transfer entry are
    // policy holds and must work from every prior state as well.
    Policy route = policyAtMode(previous);
    Context routeStarted;
    routeStarted.navigating = true;
    assert(route.update(100'000, routeStarted).current == Mode::Active);

    Policy pairing = policyAtMode(previous);
    Context pairingStarted;
    pairingStarted.attentionActive = true;
    assert(pairing.update(100'000, pairingStarted).current == Mode::Active);

    Policy audio = policyAtMode(previous);
    Context audioStarted;
    audioStarted.attentionActive = true;
    assert(audio.update(100'000, audioStarted).current == Mode::Active);

    Policy transferEntry = policyAtMode(previous);
    Context transferStarted;
    transferStarted.transferActive = true;
    assert(transferEntry.update(100'000, transferStarted).current ==
           Mode::Transfer);
  }

  Policy wrapped;
  constexpr uint32_t nearWrap = std::numeric_limits<uint32_t>::max() - 10'000;
  wrapped.begin(nearWrap);
  assert(wrapped.update(nearWrap + 14'999, {}).current == Mode::Active);
  assert(wrapped.update(nearWrap + 15'000, {}).current == Mode::Dimmed);
  assert(wrapped.update(nearWrap + 45'000, {}).current == Mode::DisplayOff);

  assert(!display_inactivity::transferInactivityElapsed(
      299'999, 0, display_inactivity::kTransferInactivityTimeoutMs, false));
  assert(display_inactivity::transferInactivityElapsed(
      300'000, 0, display_inactivity::kTransferInactivityTimeoutMs, false));
  assert(!display_inactivity::transferInactivityElapsed(
      600'000, 0, display_inactivity::kTransferInactivityTimeoutMs, true));
  assert(!display_inactivity::transferInactivityElapsed(600'000, 0, 0,
                                                        false));

  assert(display_inactivity::maneuverDataBecameActive(0, false, 100, false));
  assert(display_inactivity::maneuverDataBecameActive(0, false, 0, true));
  assert(!display_inactivity::maneuverDataBecameActive(25, true, 20, true));
  assert(!display_inactivity::maneuverDataBecameActive(0, true, 100, true));
  assert(!display_inactivity::maneuverDataBecameActive(0, false, 0, false));

  static_assert(display_inactivity::maneuverDistanceBucket(1'001) == 7);
  static_assert(display_inactivity::maneuverDistanceBucket(1'000) == 6);
  static_assert(display_inactivity::maneuverDistanceBucket(500) == 5);
  static_assert(display_inactivity::maneuverDistanceBucket(200) == 4);
  static_assert(display_inactivity::maneuverDistanceBucket(100) == 3);
  static_assert(display_inactivity::maneuverDistanceBucket(50) == 2);
  static_assert(display_inactivity::maneuverDistanceBucket(25) == 1);
  static_assert(display_inactivity::maneuverDistanceBucket(0) == 0);
  assert(display_inactivity::crossedCloserManeuverDistanceThreshold(1'001,
                                                                    1'000));
  assert(display_inactivity::crossedCloserManeuverDistanceThreshold(26, 25));
  assert(display_inactivity::crossedCloserManeuverDistanceThreshold(1, 0));
  assert(!display_inactivity::crossedCloserManeuverDistanceThreshold(1'000,
                                                                     999));
  assert(!display_inactivity::crossedCloserManeuverDistanceThreshold(0, 25));
  assert(!display_inactivity::crossedCloserManeuverDistanceThreshold(25, 26));

  // Long-run transition stability: each off-to-active transition requests one
  // wake, and the immediately following update requests none.
  Policy cycles;
  cycles.begin(0);
  uint32_t now = 0;
  for (int i = 0; i < 10'000; ++i) {
    now += display_inactivity::kDisplayOffAfterMs;
    assert(cycles.update(now, {}).current == Mode::DisplayOff);
    cycles.noteMeaningfulActivity(++now);
    assert(cycles.update(now, {}).displayWakeRequired);
    assert(!cycles.update(now, {}).displayWakeRequired);
  }

  return 0;
}
