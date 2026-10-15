#pragma once

#include <cstdint>
#include <string>

namespace device_transfer::commit_boundary_policy {

using Grant = uint64_t;

// All calls are serialized by the transfer server state mutex, the same lock
// used to revoke BLE/generation authority and close shutdown admission.
class Boundary {
public:
  Grant begin(bool authorized, bool modeMatches, bool writeAllowed,
              const std::string &operation, const std::string &artifact) {
    if (!authorized || !modeMatches || !writeAllowed || admissionClosed_ ||
        active() || operation.empty() || artifact.empty() || next_ == UINT64_MAX)
      return 0;
    // Reserve identity before publishing the grant (allocation can fail).
    operation_ = operation;
    artifact_ = artifact;
    owner_ = ++next_;
    return owner_;
  }
  bool end(Grant owner) {
    if (owner == 0 || owner != owner_)
      return false;
    owner_ = 0;
    operation_.clear();
    artifact_.clear();
    return true;
  }
  bool active() const { return owner_ != 0; }
  bool owns(Grant owner) const { return owner != 0 && owner == owner_; }
  void closeAdmission(bool closed) { admissionClosed_ = closed; }
  bool admissionClosed() const { return admissionClosed_; }

private:
  Grant next_ = 0;
  Grant owner_ = 0;
  bool admissionClosed_ = false;
  std::string operation_;
  std::string artifact_;
};

constexpr bool cancellationAllowed(bool commitInProgress) {
  return !commitInProgress;
}

} // namespace device_transfer::commit_boundary_policy
