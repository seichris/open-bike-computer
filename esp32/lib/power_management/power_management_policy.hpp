#pragma once

#include <cstdint>

#ifndef AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
#define AUTOMATIC_LIGHT_SLEEP_EXPERIMENT 0
#endif

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

constexpr Configuration kAutomaticLightSleepConfiguration{
    240,
    80,
    true,
};

constexpr Configuration kSelectedConfiguration =
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
    kAutomaticLightSleepConfiguration;
#else
    kDfsConfiguration;
#endif

constexpr bool isValid(const Configuration &configuration) {
  return configuration.minimumCpuMhz > 0 &&
         configuration.minimumCpuMhz <= configuration.maximumCpuMhz;
}

static_assert(isValid(kDfsConfiguration));
static_assert(isValid(kAutomaticLightSleepConfiguration));
static_assert(!kDfsConfiguration.automaticLightSleep,
              "Phase 7A must not enable automatic light sleep");
static_assert(kAutomaticLightSleepConfiguration.automaticLightSleep,
              "Phase 7B must explicitly request automatic light sleep");

} // namespace power_management
