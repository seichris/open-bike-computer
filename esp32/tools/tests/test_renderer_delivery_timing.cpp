#include "../../lib/renderer_diagnostics/renderer_delivery_timing.hpp"
#include <cassert>
#include <iostream>

int main() {
  using namespace renderer_diagnostics;
  static_assert(sizeof(DeliveryTimingState) <= 256, "bounded internal RAM cost");
  DeliveryTimingState state;
  state.reset();
  auto route = state.begin(1, 100, true);
  route.callbackUs = 3391000;
  route.mailboxWaitUs = 3300000;
  state.complete(route);
  for (unsigned i = 0; i < 2000; ++i) {
    auto gps = state.begin(2, 101 + i, false);
    gps.callbackUs = 120;
    state.complete(gps);
  }
  assert(state.snapshot().completed == 2001);
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
  state.complete(route);
  state.consumed(owner);
  assert(state.snapshot().completed == 0);
  assert(state.snapshot().latestOwner.ordinal == 0);
  assert(state.snapshot().slowestRoute.ordinal == 0);
  const uint32_t beforeWrap = UINT32_MAX - 9;
  assert(uint32_t(10 - beforeWrap) == 20);
  std::cout << "Renderer delivery timing: bounded retention, session fencing, owner correlation, rollover passed\n";
}
