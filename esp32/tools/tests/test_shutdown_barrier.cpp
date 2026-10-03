#include "../../lib/power/shutdown_barrier_policy.hpp"
#include <cassert>
#include <cstdint>
#include <iostream>
using shutdown_barrier::Barrier;
using shutdown_barrier::Stage;

int main() {
  // Every nonterminal participant delays independently, including late ACKs
  // after the watchdog. A timeout can never turn into permission later.
  for (int failed = 0; failed != 4; ++failed) {
    Barrier barrier;
    assert(!barrier.permit());
    barrier.request(100);
    barrier.poll(101, failed != 0, false, false, false, false);
    if (failed != 0) barrier.poll(102, true, failed != 1, false, false, false);
    if (failed > 1) barrier.poll(103, true, true, failed != 2, false, false);
    assert(!barrier.permit());
    barrier.poll(6000, true, true, true, true, false);
    assert(barrier.stage() == Stage::Deferred);
    for (uint32_t now : {7000U, 30000U, 700000U}) {
      barrier.request(now); // Retrying may not reopen admission or reset poison.
      barrier.poll(now, true, true, true, true, false);
      assert(!barrier.permit());
    }
  }
  Barrier accepted;
  accepted.request(0);
  accepted.poll(5001, false, false, false, false, true);
  assert(accepted.stage() == Stage::Drain);
  accepted.poll(30000, true, true, true, true, true);
  assert(accepted.stage() == Stage::Deferred);

  Barrier released;
  released.request(0);
  released.poll(1, false, false, false, false, true);
  released.poll(20000, true, false, false, false, false);
  assert(released.stage() == Stage::Renderer);

  Barrier progressing;
  progressing.request(0);
  for (uint32_t now = 20000; now < 600000; now += 20000) {
    progressing.noteProgress(now);
    progressing.poll(now, false, false, false, false, true);
    assert(progressing.stage() == Stage::Drain);
  }
  progressing.noteProgress(600000);
  progressing.poll(600000, true, true, true, true, true);
  assert(progressing.stage() == Stage::Deferred); // Absolute cap cannot slide.

  Barrier ordered;
  ordered.request(0);
  ordered.poll(1, false, true, true, true, false);
  assert(ordered.stage() == Stage::Drain);
  ordered.poll(2, true, true, true, true, false);
  assert(ordered.stage() == Stage::Renderer && !ordered.permit());
  ordered.poll(3, true, true, true, true, false);
  assert(ordered.stage() == Stage::Diagnostics && !ordered.permit());
  ordered.poll(4, true, true, true, true, false);
  assert(ordered.stage() == Stage::Storage && !ordered.permit());
  ordered.poll(5, true, true, true, true, false);
  assert(ordered.permit());

  // Millis wrap must not disable the bound or accidentally grant a permit.
  Barrier wrapped;
  wrapped.request(UINT32_MAX - 20U);
  wrapped.poll(4980U, false, false, false, false, false);
  assert(wrapped.stage() == Stage::Deferred && !wrapped.permit());
  std::cout << "shutdown barrier sequencing/fault tests passed\n";
}
