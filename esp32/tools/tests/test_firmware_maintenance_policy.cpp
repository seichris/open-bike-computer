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

  return 0;
}
