#pragma once

namespace device_transfer::commit_boundary_policy {

inline bool begin(bool authorized, bool &commitInProgress) {
  if (!authorized)
    return false;
  commitInProgress = true;
  return true;
}

constexpr bool cancellationAllowed(bool commitInProgress) {
  return !commitInProgress;
}

inline void end(bool &commitInProgress) { commitInProgress = false; }

} // namespace device_transfer::commit_boundary_policy
