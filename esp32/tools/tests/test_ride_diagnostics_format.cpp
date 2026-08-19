#include "../../lib/ride_diagnostics/ride_diagnostics_format.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  using ride_diagnostics::detail::FaultCapsuleState;
  using ride_diagnostics::detail::formatFaultCapsuleFields;
  using ride_diagnostics::detail::kFaultCapsuleMagic;

  FaultCapsuleState capsule{};
  capsule.magic = kFaultCapsuleMagic;
  capsule.bootSequence = 42;
  capsule.firstMissingUptimeMs = 100;
  capsule.lastMissingUptimeMs = 130;
  capsule.eventCount = 3;
  capsule.droppedCount = 2;
  capsule.storageErrorCount = 1;
  capsule.resetReason = 7;
  capsule.activeStage = 11;
  capsule.completedStage = 9;
  std::strcpy(capsule.lastCriticalCategory, "storage");
  std::strcpy(capsule.lastCriticalEvent, "write_failed");

  char output[512] = {};
  assert(formatFaultCapsuleFields(capsule, output, sizeof(output)));
  assert(std::strcmp(
             output,
             "{\"bootSequence\":42,\"firstMissingUptimeMs\":100,"
             "\"lastMissingUptimeMs\":130,\"eventCount\":3,"
             "\"droppedCount\":2,\"storageErrorCount\":1,"
             "\"resetReason\":7,\"activeStage\":11,"
             "\"completedStage\":9,\"lastCriticalCategory\":\"storage\","
             "\"lastCriticalEvent\":\"write_failed\"}") == 0);

  capsule.lastCriticalCategory[0] = '\0';
  capsule.lastCriticalEvent[0] = '\0';
  assert(formatFaultCapsuleFields(capsule, output, sizeof(output)));
  assert(std::strstr(output, "\"lastCriticalCategory\":\"unknown\"") !=
         nullptr);
  assert(std::strstr(
             output, "\"lastCriticalEvent\":\"storage_unavailable\"") !=
         nullptr);

  capsule.magic = 0;
  assert(!formatFaultCapsuleFields(capsule, output, sizeof(output)));
  capsule.magic = kFaultCapsuleMagic;
  assert(!formatFaultCapsuleFields(capsule, output, 16));

  std::cout << "ride diagnostics format tests passed\n";
  return 0;
}
