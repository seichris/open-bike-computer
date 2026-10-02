#pragma once

#include <cstdint>

namespace firmware_update::internal_owner_policy {

enum class DispatchState : uint8_t {
  Ready = 0,
  InFlight,
  Poisoned,
};

constexpr bool canIssue(DispatchState state) {
  return state == DispatchState::Ready;
}

constexpr DispatchState commandIssued(DispatchState state) {
  return canIssue(state) ? DispatchState::InFlight : DispatchState::Poisoned;
}

constexpr DispatchState commandCompleted(DispatchState state,
                                         bool matchingResult) {
  return state == DispatchState::InFlight && matchingResult
             ? DispatchState::Ready
             : DispatchState::Poisoned;
}

constexpr DispatchState commandTimedOut(DispatchState) {
  return DispatchState::Poisoned;
}

} // namespace firmware_update::internal_owner_policy
