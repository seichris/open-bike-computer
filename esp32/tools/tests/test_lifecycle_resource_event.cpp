#include "../../lib/device_transfer/lifecycle_resource_event.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics_format.hpp"
#include "../../lib/renderer_diagnostics/renderer_stack_metrics.hpp"
#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  using namespace device_transfer::lifecycle_resources;
  Snapshot s;
  s.cycle = s.sample = s.generation = UINT32_MAX;
  s.tlsStack = s.ownerStack = s.rendererStack = UINT32_MAX;
  std::strcpy(s.mode, "diagnostics");
  std::strcpy(s.operation, "12345678-1234-abcd-ABCD-123456789abc");
  assert(uuid(s.operation));
  assert(uuid("123456781234abcdABCD123456789abc"));
  assert(!uuid("password"));
  assert(!uuid("12345678-1234-abcd-ABCD-123456789ab\""));
  char bound[37] = {};
  const char *ota = "123456781234abcdABCD123456789abc";
  assert(bindOperation(bound, ota));
  assert(!bindOperation(bound, "")); // generic grant without map header
  assert(!bindOperation(bound, "token-secret"));
  assert(std::strcmp(bound, ota) == 0);
  char fields[320];
  auto valid = [&] { assert(ride_diagnostics::detail::validateFieldsJson(fields, std::strlen(fields))); };
  assert(metadata(fields, s, "shutdown_requested")); valid();
  assert(std::strstr(fields, s.operation));
  for (unsigned i = 0; i < 3; ++i) {
    s.free[i] = s.largest[i] = s.minimumFree[i] = s.minimumLargest[i] = UINT32_MAX;
    assert(pool(fields, s, i)); valid();
  }
  assert(!pool(fields, s, 3));
  assert(stacks(fields, s)); valid();
  std::strcpy(s.operation, bound);
  std::strcpy(s.mode, "firmware");
  for (const char *phase : {"operation_selected", "ota_begin", "commit_granted", "grant_released"}) {
    assert(metadata(fields, s, phase)); valid();
    assert(std::strstr(fields, ota));
  }
  assert(!metadata(fields, s, "token-secret"));
  assert(!checkpoint("ota_write")); // per-block hot path never floods recorder
  assert(!checkpoint(nullptr));
  std::strcpy(s.operation, "token-secret");
  std::strcpy(s.mode, "pin-secret");
  assert(metadata(fields, s, "commit_granted")); valid();
  assert(!std::strstr(fields, "secret"));
  assert(std::strstr(fields, "\"operationId\":\"\""));
  for (const char *secret : {"sessionToken", "apPassphrase", "password", "tlsCertificateSha256"})
    assert(!ride_diagnostics::detail::allowedFieldKey(secret, std::strlen(secret)));
  assert(!renderer_diagnostics::rendererStackSampleAvailable());
  assert(renderer_diagnostics::rendererStackHighWaterBytes() == 0);
  renderer_diagnostics::sampleRendererStackBytes(1234);
  renderer_diagnostics::sampleRendererStackBytes(2048);
  assert(renderer_diagnostics::rendererStackHighWaterBytes() == 1234);
  renderer_diagnostics::sampleRendererStackBytes(1000);
  assert(renderer_diagnostics::rendererStackHighWaterBytes() == 1000);
  renderer_diagnostics::sampleRendererStackBytes(0);
  renderer_diagnostics::sampleRendererStackBytes(1234);
  assert(renderer_diagnostics::rendererStackSampleAvailable());
  assert(renderer_diagnostics::rendererStackHighWaterBytes() == 0);
  std::cout << "lifecycle resource format tests passed\n";
}
