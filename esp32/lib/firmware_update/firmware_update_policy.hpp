#pragma once

#include <cstdint>

namespace firmware_update::policy {

enum class Eligibility : uint8_t {
  Eligible = 0,
  RunningPartitionMissing,
  InactivePartitionMissing,
  InactivePartitionInvalid,
};

enum class TransactionStage : uint8_t {
  Idle = 0,
  Receiving,
  Verified,
  CommitStarted,
  RebootSelected,
  Cancelled,
  Failed,
};

class Transaction {
public:
  constexpr TransactionStage stage() const { return stage_; }

  constexpr bool begin() {
    if (stage_ != TransactionStage::Idle &&
        stage_ != TransactionStage::Cancelled &&
        stage_ != TransactionStage::Failed)
      return false;
    stage_ = TransactionStage::Receiving;
    return true;
  }

  constexpr bool verify() {
    if (stage_ != TransactionStage::Receiving)
      return false;
    stage_ = TransactionStage::Verified;
    return true;
  }

  constexpr bool cancel() {
    if (stage_ == TransactionStage::CommitStarted ||
        stage_ == TransactionStage::RebootSelected)
      return false;
    stage_ = TransactionStage::Cancelled;
    return true;
  }

  constexpr bool beginCommit() {
    if (stage_ != TransactionStage::Verified)
      return false;
    stage_ = TransactionStage::CommitStarted;
    return true;
  }

  constexpr bool selectReboot() {
    if (stage_ != TransactionStage::CommitStarted)
      return false;
    stage_ = TransactionStage::RebootSelected;
    return true;
  }

  constexpr void fail() { stage_ = TransactionStage::Failed; }
  constexpr void reset() { stage_ = TransactionStage::Idle; }

private:
  TransactionStage stage_ = TransactionStage::Idle;
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
