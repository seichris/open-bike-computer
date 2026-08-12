#pragma once

namespace waveshare_board::speaker {

enum class CleanupAction {
  None,
  LowerPowerAmplifier,
  CloseCodecDevice,
  DeleteCodecDevice,
  DeleteCodecInterface,
  DeleteDataInterface,
  DeleteGpioInterface,
  DisableI2sChannel,
  DeleteI2sChannel,
};

struct SpeakerResourceState {
  bool channelAllocated = false;
  bool standardModeInitialized = false;
  bool channelEnabled = false;
  bool codecInterfaceCreated = false;
  bool dataInterfaceCreated = false;
  bool gpioInterfaceCreated = false;
  bool codecDeviceCreated = false;
  bool codecDeviceOpened = false;
  bool powerAmplifierEnabled = false;

  bool any() const {
    return channelAllocated || standardModeInitialized || channelEnabled ||
           codecInterfaceCreated || dataInterfaceCreated ||
           gpioInterfaceCreated || codecDeviceCreated || codecDeviceOpened ||
           powerAmplifierEnabled;
  }
};

inline CleanupAction nextCleanupAction(const SpeakerResourceState &state) {
  if (state.powerAmplifierEnabled)
    return CleanupAction::LowerPowerAmplifier;
  if (state.codecDeviceOpened)
    return CleanupAction::CloseCodecDevice;
  if (state.codecDeviceCreated)
    return CleanupAction::DeleteCodecDevice;
  if (state.codecInterfaceCreated)
    return CleanupAction::DeleteCodecInterface;
  if (state.gpioInterfaceCreated)
    return CleanupAction::DeleteGpioInterface;
  if (state.dataInterfaceCreated)
    return CleanupAction::DeleteDataInterface;
  if (state.channelEnabled)
    return CleanupAction::DisableI2sChannel;
  if (state.channelAllocated)
    return CleanupAction::DeleteI2sChannel;
  return CleanupAction::None;
}

} // namespace waveshare_board::speaker
