#include "../../lib/device_transfer/commit_boundary_policy.hpp"
#include "../../lib/firmware_update/firmware_update_policy.hpp"

#include <cassert>

int main() {
  using firmware_update::policy::Eligibility;
  using firmware_update::policy::otaEligibility;

  assert(otaEligibility(false, true, true, true, 1) ==
         Eligibility::RunningPartitionMissing);
  assert(otaEligibility(true, false, false, false, 0) ==
         Eligibility::InactivePartitionMissing);
  assert(otaEligibility(true, true, false, true, 1) ==
         Eligibility::InactivePartitionMissing);
  assert(otaEligibility(true, true, true, false, 1) ==
         Eligibility::InactivePartitionInvalid);
  assert(otaEligibility(true, true, true, true, 0) ==
         Eligibility::InactivePartitionInvalid);
  assert(otaEligibility(true, true, true, true, 3U * 1024U * 1024U) ==
         Eligibility::Eligible);

  bool commitInProgress = false;
  assert(!device_transfer::commit_boundary_policy::begin(
      false, commitInProgress));
  assert(device_transfer::commit_boundary_policy::cancellationAllowed(
      commitInProgress));
  assert(device_transfer::commit_boundary_policy::begin(
      true, commitInProgress));
  assert(!device_transfer::commit_boundary_policy::cancellationAllowed(
      commitInProgress));
  device_transfer::commit_boundary_policy::end(commitInProgress);
  assert(device_transfer::commit_boundary_policy::cancellationAllowed(
      commitInProgress));
  return 0;
}
