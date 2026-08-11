#include "../../lib/device_debug/device_debug_request_latch.hpp"

#include <cassert>
#include <iostream>

int main() {
  device_debug::OneShotRequestLatch latch;
  assert(!latch.pending());
  assert(!latch.take());

  // Repeated HTTP requests before the main loop consumes the action cannot
  // queue multiple screen advances.
  assert(latch.request());
  assert(!latch.request());
  assert(latch.pending());
  assert(latch.take());
  assert(!latch.take());

  // A later request is accepted only after the prior action was consumed.
  assert(latch.request());
  latch.clear();
  assert(!latch.pending());
  assert(!latch.take());

  std::cout << "device debug request latch tests passed\n";
  return 0;
}
