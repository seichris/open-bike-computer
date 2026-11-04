#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>

// Fields of the `ble disconnected` diagnostics event.
//
// `disconnectReason` is NimBLE's host status for the GAP disconnect event:
// `BLE_HS_HCI_ERR(x)` = 0x200 + the HCI reason `x` (520 = 0x208 connection
// supervision timeout, 531 = 0x213 remote user terminated, 534 = 0x216 local
// host terminated, 546 = 0x222 LL response timeout, 571 = 0x23B unacceptable
// connection parameters, 574 = 0x23E connection failed to be established); 0
// when no GAP event was observed for the active link. `reason` names the
// firmware's own cause when the device requested the disconnect and "remote"
// when the peer, the link or the controller ended it. Every key is part of the
// closed diagnostics vocabulary (`ride_diagnostics_format.hpp`).
namespace ble_disconnect_diagnostics {

enum class LocalCause : uint8_t {
  None = 0,
  UnauthenticatedDeadline = 1,
  OwnershipLost = 2,
  OwnershipInvalidated = 3,
};

inline const char *localCauseName(LocalCause cause) {
  switch (cause) {
  case LocalCause::UnauthenticatedDeadline:
    return "unauthenticated_deadline";
  case LocalCause::OwnershipLost:
    return "ownership_lost";
  case LocalCause::OwnershipInvalidated:
    return "ownership_invalidated";
  case LocalCause::None:
    break;
  }
  return "remote";
}

inline LocalCause localCauseFromValue(uint8_t value) {
  switch (value) {
  case 1:
    return LocalCause::UnauthenticatedDeadline;
  case 2:
    return LocalCause::OwnershipLost;
  case 3:
    return LocalCause::OwnershipInvalidated;
  default:
    return LocalCause::None;
  }
}

// Longest payload: a negative 32-bit reason, a 32-bit duration and the
// longest cause name, 118 characters plus the terminator.
constexpr size_t FIELDS_CAPACITY = 128;

// snprintf semantics: returns the character count that the complete payload
// needs; callers must treat a value >= size as truncated.
inline int formatFields(char *out, size_t size, int32_t gapReason,
                        uint32_t durationMs, bool authenticated,
                        LocalCause cause) {
  return std::snprintf(
      out, size,
      "{\"disconnectReason\":%ld,\"durationMs\":%lu,\"state\":\"%s\","
      "\"reason\":\"%s\"}",
      static_cast<long>(gapReason), static_cast<unsigned long>(durationMs),
      authenticated ? "authenticated" : "unauthenticated",
      localCauseName(cause));
}

} // namespace ble_disconnect_diagnostics
