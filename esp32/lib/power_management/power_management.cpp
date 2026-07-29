#include "power_management.hpp"

#include <Arduino.h>
#include <esp_err.h>
#include <esp_pm.h>

#if !CONFIG_PM_ENABLE
#error "Waveshare DFS requires CONFIG_PM_ENABLE=y"
#endif

#if CONFIG_FREERTOS_USE_TICKLESS_IDLE
#error "Automatic light sleep must remain disabled during Phase 7A"
#endif

namespace power_management {
namespace {

RuntimeStatus runtimeStatus;
bool attempted = false;

Configuration fromEspIdf(const esp_pm_config_t &configuration) {
  return {
      static_cast<uint16_t>(configuration.max_freq_mhz),
      static_cast<uint16_t>(configuration.min_freq_mhz),
      configuration.light_sleep_enable,
  };
}

} // namespace

bool begin() {
  if (attempted) {
    return runtimeStatus.enabled;
  }
  attempted = true;
  runtimeStatus.requested = kDfsConfiguration;

  const esp_pm_config_t requested{
      kDfsConfiguration.maximumCpuMhz,
      kDfsConfiguration.minimumCpuMhz,
      kDfsConfiguration.automaticLightSleep,
  };
  const esp_err_t configureResult = esp_pm_configure(&requested);
  runtimeStatus.errorCode = configureResult;
  if (configureResult != ESP_OK) {
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: DFS configuration failed: %s (%d)\n",
                  esp_err_to_name(configureResult), configureResult);
#endif
    return false;
  }

  esp_pm_config_t effective{};
  const esp_err_t readResult = esp_pm_get_configuration(&effective);
  if (readResult != ESP_OK) {
    runtimeStatus.errorCode = readResult;
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: DFS readback failed: %s (%d)\n",
                  esp_err_to_name(readResult), readResult);
#endif
    return false;
  }

  runtimeStatus.effective = fromEspIdf(effective);
  runtimeStatus.enabled =
      runtimeStatus.effective.maximumCpuMhz ==
          runtimeStatus.requested.maximumCpuMhz &&
      runtimeStatus.effective.minimumCpuMhz ==
          runtimeStatus.requested.minimumCpuMhz &&
      runtimeStatus.effective.automaticLightSleep ==
          runtimeStatus.requested.automaticLightSleep;
  if (!runtimeStatus.enabled) {
    runtimeStatus.errorCode = ESP_ERR_INVALID_STATE;
  }

#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
  Serial.printf(
      "Power management: DFS enabled=%d min=%uMHz max=%uMHz lightSleep=%d\n",
      runtimeStatus.enabled, runtimeStatus.effective.minimumCpuMhz,
      runtimeStatus.effective.maximumCpuMhz,
      runtimeStatus.effective.automaticLightSleep);
#endif
  return runtimeStatus.enabled;
}

RuntimeStatus status() { return runtimeStatus; }

} // namespace power_management
