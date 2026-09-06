#include "../../lib/renderer_diagnostics/renderer_delivery_timing.hpp"
#include <cassert>
#include <iostream>

int main() {
  using namespace renderer_diagnostics;
  static_assert(sizeof(DeliveryTimingState) <= 256, "bounded internal RAM cost");
  DeliveryTimingState state;
  assert(state.begin(2, 10, false).session == 0);
  state.reset();
  assert(state.begin(0, 10, false).session == 0);
  assert(state.snapshot().started == 0);
  auto route = state.begin(1, 100, true);
  assert(state.snapshot().started == 1);
  assert(state.snapshot().completed == 0);
  assert(state.snapshot().latestStarted.phase == DeliveryCallbackPhase::Entered);
  state.progress(route, DeliveryCallbackPhase::WaitingForMailbox, 110);
  assert(state.snapshot().latestStarted.updatedAtMs == 110);
  assert(state.snapshot().latestStarted.phase == DeliveryCallbackPhase::WaitingForMailbox);
  route.callbackUs = 3391000;
  route.mailboxWaitUs = 3300000;
  state.complete(route, 3491);
  assert(state.snapshot().latestStarted.phase == DeliveryCallbackPhase::Completed);
  state.progress(route, DeliveryCallbackPhase::Entered, 3492);
  assert(state.snapshot().latestStarted.updatedAtMs == 3491);
  for (unsigned i = 0; i < 2000; ++i) {
    auto gps = state.begin(2, 101 + i, false);
    gps.callbackUs = 120;
    state.complete(gps, 102 + i);
  }
  assert(state.snapshot().completed == 2001);
  assert(state.snapshot().started == 2001);
  assert(state.snapshot().slowestRoute.ordinal == route.ordinal);
  assert(state.snapshot().slowestRoute.mailboxWaitUs == 3300000);
  assert(state.snapshot().slowestGps.callbackUs == 120);
  DeliveryOwnerTiming owner{};
  owner.session = route.session;
  owner.ordinal = route.ordinal;
  owner.processingUs = 450;
  state.consumed(owner);
  owner.processingUs = 10;
  state.consumed(owner);
  assert(state.snapshot().slowestOwner.processingUs == 450);
  assert(state.snapshot().latestOwner.processingUs == 10);
  state.reset();
  auto stalled = state.begin(2, 4000, true);
  state.progress(stalled, DeliveryCallbackPhase::Authenticating, 4001);
  state.progress(route, DeliveryCallbackPhase::HoldingMailbox, 5000);
  state.complete(route, 5001);
  state.consumed(owner);
  assert(state.snapshot().completed == 0);
  assert(state.snapshot().latestOwner.ordinal == 0);
  assert(state.snapshot().slowestRoute.ordinal == 0);
  assert(state.snapshot().latestStarted.ordinal == stalled.ordinal);
  assert(state.snapshot().latestStarted.phase == DeliveryCallbackPhase::Authenticating);
  assert(state.snapshot().latestStarted.updatedAtMs == 4001);
  // An older same-session callback cannot overwrite a newer callback's entry.
  auto newer = state.begin(1, 5002, false);
  state.complete(stalled, 5003);
  assert(state.snapshot().latestStarted.ordinal == newer.ordinal);
  assert(state.snapshot().latestStarted.phase == DeliveryCallbackPhase::Entered);
  state.reset();
  assert(state.snapshot().latestStarted.ordinal == 0);
  assert(state.snapshot().started == 0);
  const uint32_t beforeWrap = UINT32_MAX - 9;
  assert(uint32_t(10 - beforeWrap) == 20);
  auto wraps = state.begin(2, beforeWrap, false);
  state.progress(wraps, DeliveryCallbackPhase::Dispatching, 10);
  assert(uint32_t(state.snapshot().latestStarted.updatedAtMs -
                  state.snapshot().latestStarted.startedAtMs) == 20);
  std::cout << "Renderer delivery timing: bounded retention, session fencing, owner correlation, rollover passed\n";
}
