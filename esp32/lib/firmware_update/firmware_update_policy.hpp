#pragma once

#include <cstdint>

namespace firmware_update::policy {

enum class Eligibility : uint8_t {
  Eligible = 0,
  RunningPartitionMissing,
  InactivePartitionMissing,
  InactivePartitionInvalid,
};

constexpr Eligibility otaEligibility(bool runningPresent,
                                     bool inactivePresent,
                                     bool distinctPartitions,
                                     bool inactiveIsOtaApplication,
                                     uint32_t inactiveSize) {
  if (!runningPresent)
    return Eligibility::RunningPartitionMissing;
  if (!inactivePresent || !distinctPartitions)
    return Eligibility::InactivePartitionMissing;
  if (!inactiveIsOtaApplication || inactiveSize == 0)
    return Eligibility::InactivePartitionInvalid;
  return Eligibility::Eligible;
}

constexpr const char *eligibilityCode(Eligibility eligibility) {
  switch (eligibility) {
  case Eligibility::Eligible:
    return "eligible";
  case Eligibility::RunningPartitionMissing:
    return "running_partition_missing";
  case Eligibility::InactivePartitionMissing:
    return "inactive_ota_partition_missing";
  case Eligibility::InactivePartitionInvalid:
    return "inactive_partition_invalid";
  }
  return "inactive_partition_invalid";
}

} // namespace firmware_update::policy
