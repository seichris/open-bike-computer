#include "../../lib/firmware_maintenance/firmware_maintenance_policy.hpp"

#include <cassert>

int main() {
  using namespace firmware_maintenance::policy;

  constexpr uint32_t kFirmwareA = 0x11223344;
  constexpr uint32_t kFirmwareB = 0x55667788;
  Request request = make(kFirmwareA, 7);
  assert(valid(request));

  uint32_t correlation = 0;
  assert(!consume(request, kFirmwareA, 1, correlation));
  assert(correlation == 0);
  assert(!valid(request));

  request = make(kFirmwareA, 8);
  assert(!consume(request, kFirmwareB, kSoftwareResetReason, correlation));
  assert(correlation == 0);
  assert(!valid(request));

  request = make(kFirmwareA, 9);
  request.checksum ^= 1;
  assert(!consume(request, kFirmwareA, kSoftwareResetReason, correlation));
  assert(correlation == 0);

  request = make(kFirmwareA, 10);
  assert(consume(request, kFirmwareA, kSoftwareResetReason, correlation));
  assert(correlation == 10);
  assert(!valid(request));

  const ResourceSnapshot abundant{128U * 1024U, 64U * 1024U,
                                  96U * 1024U, 48U * 1024U};
  assert(admit(ResourcePhase::BeforeWorker, abundant) ==
         ResourceAdmission::Admitted);
  ResourceSnapshot constrained = abundant;
  constrained.internalFree = kBeforeWorkerMinimum.internalFree - 1;
  assert(admit(ResourcePhase::BeforeWorker, constrained) ==
         ResourceAdmission::InternalFreeLow);
  constrained = abundant;
  constrained.internalLargest = kBeforeWorkerMinimum.internalLargest - 1;
  assert(admit(ResourcePhase::BeforeWorker, constrained) ==
         ResourceAdmission::InternalLargestLow);
  constrained = abundant;
  constrained.dmaFree = kBeforeWorkerMinimum.dmaFree - 1;
  assert(admit(ResourcePhase::BeforeWorker, constrained) ==
         ResourceAdmission::DmaFreeLow);
  constrained = abundant;
  constrained.dmaLargest = kBeforeWorkerMinimum.dmaLargest - 1;
  assert(admit(ResourcePhase::BeforeWorker, constrained) ==
         ResourceAdmission::DmaLargestLow);
  assert(!authenticationTimedOut(kAwaitingAuthenticationTimeoutMs - 1,
                                 false));
  assert(authenticationTimedOut(kAwaitingAuthenticationTimeoutMs, false));
  assert(!authenticationTimedOut(kAwaitingAuthenticationTimeoutMs, true));
  assert(!transferTimedOut(kTransferInactivityTimeoutMs - 1, 0, true,
                           false));
  assert(transferTimedOut(kTransferInactivityTimeoutMs, 0, true, false));
  assert(!transferTimedOut(kTransferInactivityTimeoutMs, 0, true, true));
  assert(!transferTimedOut(kTransferInactivityTimeoutMs, 0, false, false));

  BootButtonExitState bootButton;
  assert(!bootButtonExitRequested(bootButton, true, 100));
  assert(!bootButtonExitRequested(bootButton, true, 3000));
  assert(!bootButtonExitRequested(bootButton, false, 3010));
  assert(!bootButtonExitRequested(bootButton, true, 3020));
  assert(!bootButtonExitRequested(bootButton, true,
                                  3020 + kBootButtonExitHoldMs - 1));
  assert(bootButtonExitRequested(bootButton, true,
                                 3020 + kBootButtonExitHoldMs));
  assert(!bootButtonExitRequested(bootButton, false, 6000));
  assert(!bootButtonExitRequested(bootButton, true, 6010));

  return 0;
}
