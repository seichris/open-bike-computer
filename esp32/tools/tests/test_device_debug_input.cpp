#include "../../lib/device_debug/device_debug_input.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

using namespace device_debug;

static PointerEvent event(uint32_t sequence, PointerPhase phase, uint16_t x,
                          uint16_t y, uint32_t atMs) {
  return {1, sequence, 0, phase, {x, y}, atMs};
}

int main() {
  PointerController<> input(kWaveshareAmoled175Geometry);
  auto invalidSchema = event(1, PointerPhase::Down, 10, 10, 80);
  invalidSchema.schema = 2;
  assert(input.enqueue(invalidSchema) == PointerQueueResult::InvalidSchema);
  auto invalidPointer = event(1, PointerPhase::Down, 10, 10, 90);
  invalidPointer.pointerId = 1;
  assert(input.enqueue(invalidPointer) ==
         PointerQueueResult::InvalidPointerId);
  assert(input.enqueue(event(1, PointerPhase::Move, 10, 10, 100)) ==
         PointerQueueResult::InvalidTransition);
  assert(input.enqueue(event(1, PointerPhase::Down, 466, 10, 108)) ==
         PointerQueueResult::InvalidCoordinate);
  assert(input.enqueue(event(1, PointerPhase::Down, 10, 20, 116)) ==
         PointerQueueResult::Accepted);
  assert(input.enqueue(event(1, PointerPhase::Move, 11, 21, 124)) ==
         PointerQueueResult::DuplicateOrOutOfOrder);
  assert(input.enqueue(event(2, PointerPhase::Move, 11, 21, 125)) ==
         PointerQueueResult::Accepted);
  assert(input.enqueue(event(3, PointerPhase::Up, 11, 21, 133)) ==
         PointerQueueResult::Accepted);
  assert(input.counters().hasAcceptedSequence);
  assert(input.counters().lastAcceptedSequence == 3);

  PointerController<> quickRelease(kWaveshareAmoled175Geometry);
  assert(quickRelease.enqueue(event(1, PointerPhase::Down, 10, 20, 100)) ==
         PointerQueueResult::Accepted);
  assert(quickRelease.enqueue(event(2, PointerPhase::Move, 11, 21, 101)) ==
         PointerQueueResult::RateLimited);
  assert(quickRelease.enqueue(event(3, PointerPhase::Up, 11, 21, 101)) ==
         PointerQueueResult::Accepted);

  auto sample = input.sample(false, 116);
  assert(sample.pressed && sample.changed);
  assert(sample.point.x == 20 && sample.point.y == 455);
  sample = input.sample(false, 125);
  assert(sample.pressed && sample.changed);
  sample = input.sample(false, 133);
  assert(!sample.pressed && sample.changed);
  assert(input.state() == PointerState::Idle);

  input.cancelSession();
  assert(!input.counters().hasAcceptedSequence);
  assert(input.enqueue(event(UINT32_MAX, PointerPhase::Down, 1, 2, 200)) ==
         PointerQueueResult::Accepted);
  assert(input.enqueue(event(0, PointerPhase::Up, 1, 2, 208)) ==
         PointerQueueResult::Accepted);
  assert(input.sample(false, 200).pressed);
  assert(!input.sample(false, 208).pressed);

  assert(input.enqueue(event(1, PointerPhase::Down, 1, 2, 216)) ==
         PointerQueueResult::Accepted);
  assert(input.sample(false, 216).pressed);
  sample = input.sample(false, 216 + kPointerFailSafeMs);
  assert(!sample.pressed && sample.timedOut);
  assert(input.counters().timeouts == 1);

  assert(input.enqueue(event(2, PointerPhase::Down, 1, 2, 2000)) ==
         PointerQueueResult::Accepted);
  assert(input.sample(false, 2000).pressed);
  sample = input.sample(true, 2001);
  assert(!sample.pressed);
  assert(input.state() == PointerState::PhysicalOverrideUntilRelease);
  assert(input.enqueue(event(3, PointerPhase::Down, 1, 2, 2008)) ==
         PointerQueueResult::InvalidTransition);
  assert(input.enqueue(event(3, PointerPhase::Up, 1, 2, 2008)) ==
         PointerQueueResult::InvalidTransition);
  input.sample(false, 2009);
  assert(input.state() == PointerState::Idle);

  input.cancelSession();
  assert(input.enqueue(event(1, PointerPhase::Down, 1, 2, 3000)) ==
         PointerQueueResult::Accepted);
  assert(input.enqueue(event(2, PointerPhase::Up, 1, 2, 3008)) ==
         PointerQueueResult::Accepted);
  assert(input.cancelSession().changed == false);
  assert(input.pendingCount() == 0);

  PointerController<2> bounded(kWaveshareAmoled206Geometry);
  assert(bounded.enqueue(event(1, PointerPhase::Down, 2, 3, 10)) ==
         PointerQueueResult::Accepted);
  assert(bounded.enqueue(event(2, PointerPhase::Move, 3, 4, 18)) ==
         PointerQueueResult::QueueFull);
  assert(bounded.enqueue(event(3, PointerPhase::Up, 2, 3, 18)) ==
         PointerQueueResult::Accepted);
  assert(bounded.pendingCount() == 2);
  assert(bounded.sample(false, 10).pressed);
  assert(!bounded.sample(false, 18).pressed);

  std::cout << "device debug input tests passed\n";
  return 0;
}
