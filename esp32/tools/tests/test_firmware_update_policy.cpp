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

  device_transfer::commit_boundary_policy::Boundary boundary;
  assert(boundary.begin(false, true, true, "operation", "artifact") == 0);
  assert(boundary.begin(true, false, true, "operation", "artifact") == 0);
  assert(boundary.begin(true, true, false, "operation", "artifact") == 0);
  assert(boundary.begin(true, true, true, "", "artifact") == 0);
  assert(boundary.begin(true, true, true, "operation", "") == 0);
  boundary.closeAdmission(true);
  assert(boundary.begin(true, true, true, "operation", "artifact") == 0);
  boundary.closeAdmission(false);
  const auto first = boundary.begin(true, true, true, "operation", "artifact");
  assert(first != 0);
  assert(!device_transfer::commit_boundary_policy::cancellationAllowed(boundary.active()));
  assert(boundary.begin(true, true, true, "other", "other") == 0);
  assert(!boundary.end(0));
  assert(!boundary.end(first + 1));
  assert(boundary.owns(first));
  boundary.closeAdmission(true);
  assert(boundary.owns(first)); // shutdown cannot revoke a granted owner
  assert(boundary.end(first));
  assert(!boundary.end(first)); // duplicate completion is harmless
  boundary.closeAdmission(false);
  const auto second = boundary.begin(true, true, true, "operation", "artifact");
  assert(second != 0 && second != first);
  assert(!boundary.end(first)); // late old completion cannot end a new grant
  assert(boundary.owns(second));
  assert(boundary.end(second));

  // Deterministic OTA barriers exercise both possible race orderings. A cancel
  // that linearizes before commit wins; after commit begins it is too late.
  firmware_update::policy::Transaction cancelFirst;
  assert(cancelFirst.begin());
  assert(cancelFirst.verify());
  assert(cancelFirst.cancel());
  assert(cancelFirst.stage() ==
         firmware_update::policy::TransactionStage::Cancelled);
  assert(!cancelFirst.beginCommit());

  firmware_update::policy::Transaction commitFirst;
  assert(commitFirst.begin());
  assert(commitFirst.verify());
  assert(commitFirst.beginCommit());
  assert(!commitFirst.cancel());
  assert(commitFirst.selectReboot());
  assert(commitFirst.stage() ==
         firmware_update::policy::TransactionStage::RebootSelected);

  firmware_update::policy::Transaction disconnectDuringWrite;
  assert(disconnectDuringWrite.begin());
  assert(disconnectDuringWrite.cancel());
  assert(!disconnectDuringWrite.verify());

  firmware_update::policy::Transaction failed;
  assert(failed.begin());
  failed.fail();
  assert(failed.begin());
  return 0;
}
