#include "../../lib/speaker/speaker_resource_state.hpp"

#include <cassert>
#include <vector>

using waveshare_board::speaker::CleanupAction;
using waveshare_board::speaker::SpeakerResourceState;
using waveshare_board::speaker::nextCleanupAction;

static void complete(CleanupAction action, SpeakerResourceState &state) {
  switch (action) {
  case CleanupAction::LowerPowerAmplifier:
    state.powerAmplifierEnabled = false;
    break;
  case CleanupAction::CloseCodecDevice:
    state.codecDeviceOpened = false;
    break;
  case CleanupAction::DeleteCodecDevice:
    state.codecDeviceCreated = false;
    break;
  case CleanupAction::DeleteCodecInterface:
    state.codecInterfaceCreated = false;
    break;
  case CleanupAction::DeleteDataInterface:
    state.dataInterfaceCreated = false;
    break;
  case CleanupAction::DeleteGpioInterface:
    state.gpioInterfaceCreated = false;
    break;
  case CleanupAction::DisableI2sChannel:
    state.channelEnabled = false;
    break;
  case CleanupAction::DeleteI2sChannel:
    state.channelAllocated = false;
    state.standardModeInitialized = false;
    break;
  case CleanupAction::None:
    break;
  }
}

int main() {
  SpeakerResourceState empty{};
  assert(!empty.any());
  assert(nextCleanupAction(empty) == CleanupAction::None);

  SpeakerResourceState full{true, true, true, true, true,
                            true, true, true, true};
  const std::vector<CleanupAction> expected{
      CleanupAction::LowerPowerAmplifier,
      CleanupAction::CloseCodecDevice,
      CleanupAction::DeleteCodecDevice,
      CleanupAction::DeleteCodecInterface,
      CleanupAction::DeleteDataInterface,
      CleanupAction::DeleteGpioInterface,
      CleanupAction::DisableI2sChannel,
      CleanupAction::DeleteI2sChannel,
  };
  for (CleanupAction action : expected) {
    assert(nextCleanupAction(full) == action);
    complete(action, full);
  }
  assert(!full.any());
  assert(nextCleanupAction(full) == CleanupAction::None);

  // Allocation without enable must delete directly and never request disable.
  SpeakerResourceState partial{};
  partial.channelAllocated = true;
  partial.standardModeInitialized = true;
  assert(nextCleanupAction(partial) == CleanupAction::DeleteI2sChannel);
  complete(nextCleanupAction(partial), partial);
  assert(nextCleanupAction(partial) == CleanupAction::None);

  // A failed action retains state so one controlled retry selects it again.
  SpeakerResourceState retry{};
  retry.channelAllocated = true;
  retry.channelEnabled = true;
  assert(nextCleanupAction(retry) == CleanupAction::DisableI2sChannel);
  assert(nextCleanupAction(retry) == CleanupAction::DisableI2sChannel);
  complete(CleanupAction::DisableI2sChannel, retry);
  assert(nextCleanupAction(retry) == CleanupAction::DeleteI2sChannel);

  // Every partial initialization prefix has a bounded reverse cleanup.
  for (int prefix = 1; prefix <= 9; ++prefix) {
    SpeakerResourceState state{};
    if (prefix >= 1) state.channelAllocated = true;
    if (prefix >= 2) state.standardModeInitialized = true;
    if (prefix >= 3) state.channelEnabled = true;
    if (prefix >= 4) state.dataInterfaceCreated = true;
    if (prefix >= 5) state.gpioInterfaceCreated = true;
    if (prefix >= 6) state.codecInterfaceCreated = true;
    if (prefix >= 7) state.codecDeviceCreated = true;
    if (prefix >= 8) state.codecDeviceOpened = true;
    if (prefix >= 9) state.powerAmplifierEnabled = true;
    int actions = 0;
    while (nextCleanupAction(state) != CleanupAction::None) {
      complete(nextCleanupAction(state), state);
      assert(++actions <= 8);
    }
    assert(!state.any());
  }
  return 0;
}
