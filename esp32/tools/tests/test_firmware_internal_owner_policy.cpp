#include "../../lib/firmware_update/firmware_internal_owner_policy.hpp"

#include <cassert>

int main() {
  using namespace firmware_update::internal_owner_policy;

  DispatchState state = DispatchState::Ready;
  assert(canIssue(state));
  state = commandIssued(state);
  assert(state == DispatchState::InFlight);
  assert(!canIssue(state));
  state = commandCompleted(state, true);
  assert(state == DispatchState::Ready);

  state = commandIssued(state);
  state = commandTimedOut(state);
  assert(state == DispatchState::Poisoned);
  assert(!canIssue(state));
  // A delayed result cannot revive the owner or become the next caller's
  // result after the original caller timed out.
  state = commandCompleted(state, true);
  assert(state == DispatchState::Poisoned);
  assert(commandIssued(state) == DispatchState::Poisoned);

  state = DispatchState::Ready;
  state = commandIssued(state);
  state = commandCompleted(state, false);
  assert(state == DispatchState::Poisoned);

  return 0;
}
