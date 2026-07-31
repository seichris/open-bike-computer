#include "../../lib/power_management/power_management_policy.hpp"

#include <cassert>

int main() {
  using namespace power_management;

  static_assert(kDfsConfiguration.maximumCpuMhz == 240);
  static_assert(kDfsConfiguration.minimumCpuMhz == 80);
  static_assert(!kDfsConfiguration.automaticLightSleep);

  assert(isValid(kDfsConfiguration));
  assert(isValid(Configuration{80, 80, false}));
  assert(!isValid(Configuration{80, 240, false}));
  assert(!isValid(Configuration{240, 0, false}));
  return 0;
}
