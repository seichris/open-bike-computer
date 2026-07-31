#include "../../lib/power_management/active_low_wake_interrupt_gate.hpp"

#include <cassert>

int main() {
  power_management::ActiveLowWakeInterruptGate gate;
  assert(!gate.masked());

  assert(gate.latch());
  assert(gate.masked());
  assert(!gate.latch());

  assert(!gate.rearmIfInactive(true));
  assert(gate.masked());
  assert(gate.rearmIfInactive(false));
  assert(!gate.masked());
  assert(!gate.rearmIfInactive(false));

  assert(gate.latch());
  return 0;
}
