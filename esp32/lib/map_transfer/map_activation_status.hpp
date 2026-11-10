#pragma once

#include <cstdint>

namespace map_transfer {

// What an activation reports. The wire (BLE status and HTTP JSON) carries
// exactly activationStatusName()'s strings, in MapActivationSnapshot::status.
enum class ActivationStatus : uint8_t {
  Idle,
  Activating,
  Installed,
  Failed,
  Recovering,
  // Not running and not installed: lets the same session begin again, so a
  // new operation for the same content cannot finish through an earlier
  // installed result.
  Prepared,
};

// Every name fits a std::string's small-string buffer: assigning one never
// allocates.
constexpr const char *activationStatusName(ActivationStatus status) {
  switch (status) {
  case ActivationStatus::Idle: return "idle";
  case ActivationStatus::Activating: return "activating";
  case ActivationStatus::Installed: return "installed";
  case ActivationStatus::Failed: return "failed";
  case ActivationStatus::Recovering: return "recovering";
  case ActivationStatus::Prepared: return "prepared";
  }
  return "idle";
}

} // namespace map_transfer
