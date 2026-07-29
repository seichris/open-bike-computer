#pragma once

#include <cstdint>

namespace power_management {

struct Configuration {
  uint16_t maximumCpuMhz;
  uint16_t minimumCpuMhz;
  bool automaticLightSleep;
};

constexpr Configuration kDfsConfiguration{
    240,
    80,
    false,
};

constexpr bool isValid(const Configuration &configuration) {
  return configuration.minimumCpuMhz > 0 &&
         configuration.minimumCpuMhz <= configuration.maximumCpuMhz;
}

static_assert(isValid(kDfsConfiguration));
static_assert(!kDfsConfiguration.automaticLightSleep,
              "Phase 7A must not enable automatic light sleep");

} // namespace power_management
