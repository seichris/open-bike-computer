#include "power_management.hpp"

#include <Arduino.h>
#include <array>
#include <atomic>
#include <esp_err.h>
#include <esp_pm.h>
#include <esp_sleep.h>
#include <driver/gpio.h>

#if !CONFIG_PM_ENABLE
#error "Waveshare DFS requires CONFIG_PM_ENABLE=y"
#endif

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT && !CONFIG_FREERTOS_USE_TICKLESS_IDLE
#error "Phase 7B requires FreeRTOS tickless idle"
#endif

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT && !CONFIG_PM_LIGHT_SLEEP_CALLBACKS
#error "Phase 7B GPIO wake handoff requires light-sleep callbacks"
#endif

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT && defined(WAVESHARE_AMOLED_206) &&      \
    !CONFIG_GPIO_CTRL_FUNC_IN_IRAM
#error "Active-low wake ISR masking requires IRAM-safe GPIO control"
#endif

#if !AUTOMATIC_LIGHT_SLEEP_EXPERIMENT && CONFIG_FREERTOS_USE_TICKLESS_IDLE
#error "Tickless idle is reserved for the opt-in automatic-light-sleep build"
#endif

namespace power_management {
namespace {

RuntimeStatus runtimeStatus;
bool attempted = false;
using LockHandle = esp_pm_lock_handle_t;
constexpr size_t kLockDomainCount = static_cast<size_t>(LockDomain::Count);
std::array<LockHandle, kLockDomainCount> lockHandles{};
std::atomic<uint32_t> activeLockCount{0};
std::atomic<uint32_t> peakLockCount{0};
std::atomic<uint32_t> lockFailureCount{0};
std::atomic<uint32_t> wakeSourceFailureCount{0};
std::atomic<uint32_t> gpioWakeEventCount{0};
std::atomic<uint32_t> lastGpioWakeMaskLow{0};
std::atomic<uint32_t> lastGpioWakeMaskHigh{0};
std::atomic<int> lastErrorCode{0};
bool startupLockHeld = false;
bool wakeSourcesReady = false;
bool wakeSourceConfigurationFailed = false;
bool wakeCaptureRegistered = false;
std::atomic<GpioWakeNotifier> gpioWakeNotifier{nullptr};

void setError(int errorCode) { lastErrorCode.store(errorCode); }

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
esp_err_t captureLightSleepGpioWake(int64_t, void *) {
  const esp_sleep_wakeup_cause_t wakeCause = esp_sleep_get_wakeup_cause();
  uint64_t gpioMask = 0;
  if (wakeCause == ESP_SLEEP_WAKEUP_EXT1) {
    gpioMask =
        esp_sleep_get_ext1_wakeup_status() & runtimeStatus.ext1WakeMask;
  } else if (wakeCause == ESP_SLEEP_WAKEUP_GPIO) {
    uint64_t remainingConfiguredPins = runtimeStatus.gpioWakeMask;
    while (remainingConfiguredPins != 0) {
      const uint8_t gpioNumber =
          static_cast<uint8_t>(__builtin_ctzll(remainingConfiguredPins));
      const uint64_t gpioBit = 1ULL << gpioNumber;
      if (gpio_get_level(static_cast<gpio_num_t>(gpioNumber)) == 0) {
        gpioMask |= gpioBit;
      }
      remainingConfiguredPins &= ~gpioBit;
    }
  } else {
    return ESP_OK;
  }
  if (gpioMask == 0) {
    return ESP_OK;
  }

  lastGpioWakeMaskLow.store(static_cast<uint32_t>(gpioMask),
                            std::memory_order_relaxed);
  lastGpioWakeMaskHigh.store(static_cast<uint32_t>(gpioMask >> 32),
                             std::memory_order_relaxed);
  gpioWakeEventCount.fetch_add(1, std::memory_order_relaxed);

  const GpioWakeNotifier notifier =
      gpioWakeNotifier.load(std::memory_order_acquire);
  if (notifier != nullptr) {
    notifier(gpioMask);
  }
  return ESP_OK;
}

esp_pm_sleep_cbs_register_config_t gpioWakeCaptureConfiguration() {
  esp_pm_sleep_cbs_register_config_t configuration{};
  configuration.exit_cb = captureLightSleepGpioWake;
  return configuration;
}

bool registerGpioWakeCapture() {
  esp_pm_sleep_cbs_register_config_t configuration =
      gpioWakeCaptureConfiguration();
  const esp_err_t result = esp_pm_light_sleep_register_cbs(&configuration);
  if (result != ESP_OK) {
    setError(result);
    wakeSourceFailureCount.fetch_add(1);
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: light-sleep wake capture failed: %s "
                  "(%d)\n",
                  esp_err_to_name(result), result);
#endif
    return false;
  }
  wakeCaptureRegistered = true;
  return true;
}

void unregisterGpioWakeCapture() {
  if (!wakeCaptureRegistered) {
    return;
  }
  esp_pm_sleep_cbs_register_config_t configuration =
      gpioWakeCaptureConfiguration();
  esp_pm_light_sleep_unregister_cbs(&configuration);
  wakeCaptureRegistered = false;
}
#endif

constexpr const char *lockName(LockDomain domain) {
  switch (domain) {
  case LockDomain::Startup:
    return "app_startup";
  case LockDomain::Display:
    return "app_display";
  case LockDomain::Map:
    return "app_map";
  case LockDomain::Storage:
    return "app_storage";
  case LockDomain::Transfer:
    return "app_transfer";
  case LockDomain::Audio:
    return "app_audio";
  case LockDomain::I2c:
    return "app_i2c";
  case LockDomain::Count:
    break;
  }
  return "app_unknown";
}

bool validDomain(LockDomain domain) {
  return static_cast<size_t>(domain) < kLockDomainCount;
}

void noteAcquired() {
  const uint32_t active = activeLockCount.fetch_add(1) + 1;
  uint32_t peak = peakLockCount.load();
  while (active > peak && !peakLockCount.compare_exchange_weak(peak, active)) {
  }
}

void deleteLocks() {
  for (LockHandle &handle : lockHandles) {
    if (handle != nullptr) {
      esp_pm_lock_delete(handle);
      handle = nullptr;
    }
  }
}

bool createLocks() {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  for (size_t index = 0; index < kLockDomainCount; ++index) {
    const LockDomain domain = static_cast<LockDomain>(index);
    const esp_err_t result = esp_pm_lock_create(
        ESP_PM_NO_LIGHT_SLEEP, 0, lockName(domain), &lockHandles[index]);
    if (result != ESP_OK) {
      setError(result);
      lockFailureCount.fetch_add(1);
      deleteLocks();
      return false;
    }
  }
#endif
  return true;
}

Configuration fromEspIdf(const esp_pm_config_t &configuration) {
  return {
      static_cast<uint16_t>(configuration.max_freq_mhz),
      static_cast<uint16_t>(configuration.min_freq_mhz),
      configuration.light_sleep_enable,
  };
}

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
bool containConfigurationFailure(int originalError) {
  const esp_pm_config_t fallback{
      kDfsConfiguration.maximumCpuMhz,
      kDfsConfiguration.minimumCpuMhz,
      false,
  };
  const esp_err_t fallbackResult = esp_pm_configure(&fallback);
  if (fallbackResult != ESP_OK) {
    setError(fallbackResult);
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: light-sleep rollback failed: %s (%d); "
                  "startup lock retained\n",
                  esp_err_to_name(fallbackResult), fallbackResult);
#endif
    return false;
  }

  esp_pm_config_t effective{};
  const esp_err_t readResult = esp_pm_get_configuration(&effective);
  if (readResult != ESP_OK) {
    setError(readResult);
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: rollback readback failed: %s (%d); "
                  "startup lock retained\n",
                  esp_err_to_name(readResult), readResult);
#endif
    return false;
  }

  runtimeStatus.effective = fromEspIdf(effective);
  const bool automaticSleepDisabled =
      runtimeStatus.effective.maximumCpuMhz ==
          kDfsConfiguration.maximumCpuMhz &&
      runtimeStatus.effective.minimumCpuMhz ==
          kDfsConfiguration.minimumCpuMhz &&
      !runtimeStatus.effective.automaticLightSleep;
  if (!automaticSleepDisabled) {
    setError(ESP_ERR_INVALID_STATE);
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.println("Power management: rollback mismatch; startup lock retained");
#endif
    return false;
  }

  setError(originalError);
  if (!release(LockDomain::Startup)) {
    return false;
  }
  startupLockHeld = false;
  unregisterGpioWakeCapture();
  deleteLocks();
  return true;
}
#endif

} // namespace

bool begin() {
  if (attempted) {
    return runtimeStatus.enabled;
  }
  attempted = true;
  runtimeStatus.requested = kSelectedConfiguration;

  if (!createLocks()) {
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: lock creation failed: %s (%d)\n",
                  esp_err_to_name(lastErrorCode.load()),
                  lastErrorCode.load());
#endif
    return false;
  }

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  if (!acquire(LockDomain::Startup)) {
    deleteLocks();
    return false;
  }
  startupLockHeld = true;
  if (!registerGpioWakeCapture()) {
    if (release(LockDomain::Startup)) {
      startupLockHeld = false;
      deleteLocks();
    }
    return false;
  }
#endif

  const esp_pm_config_t requested{
      kSelectedConfiguration.maximumCpuMhz,
      kSelectedConfiguration.minimumCpuMhz,
      kSelectedConfiguration.automaticLightSleep,
  };
  const esp_err_t configureResult = esp_pm_configure(&requested);
  setError(configureResult);
  if (configureResult != ESP_OK) {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
    if (release(LockDomain::Startup)) {
      startupLockHeld = false;
      unregisterGpioWakeCapture();
      deleteLocks();
    }
#else
    deleteLocks();
#endif
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: DFS configuration failed: %s (%d)\n",
                  esp_err_to_name(configureResult), configureResult);
#endif
    return false;
  }

  esp_pm_config_t effective{};
  const esp_err_t readResult = esp_pm_get_configuration(&effective);
  if (readResult != ESP_OK) {
    setError(readResult);
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: DFS readback failed: %s (%d)\n",
                  esp_err_to_name(readResult), readResult);
#endif
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
    containConfigurationFailure(readResult);
#else
    deleteLocks();
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
    setError(ESP_ERR_INVALID_STATE);
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
    containConfigurationFailure(ESP_ERR_INVALID_STATE);
#else
    deleteLocks();
#endif
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

void completeStartup() {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  const bool wakePipelineReady =
      wakeSourcesReady && wakeCaptureRegistered &&
      gpioWakeNotifier.load(std::memory_order_acquire) != nullptr;
  if (!runtimeStatus.enabled || !startupLockHeld || !wakePipelineReady) {
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    if (runtimeStatus.enabled && startupLockHeld && !wakePipelineReady) {
      Serial.printf("Power management: wake pipeline not ready; startup lock "
                    "retained sources=%d capture=%d notifier=%d\n",
                    wakeSourcesReady, wakeCaptureRegistered,
                    gpioWakeNotifier.load(std::memory_order_relaxed) != nullptr);
    }
#endif
    return;
  }
  if (release(LockDomain::Startup)) {
    startupLockHeld = false;
    runtimeStatus.startupComplete = true;
  }
#else
  runtimeStatus.startupComplete = runtimeStatus.enabled;
#endif
}

bool configureExt1Wakeup(uint64_t gpioMask) {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  wakeSourcesReady = false;
  if (gpioMask == 0) {
    setError(ESP_ERR_INVALID_ARG);
    wakeSourceFailureCount.fetch_add(1);
    wakeSourceConfigurationFailed = true;
    return false;
  }

  const esp_err_t result =
      esp_sleep_enable_ext1_wakeup(gpioMask, ESP_EXT1_WAKEUP_ANY_LOW);
  if (result != ESP_OK) {
    setError(result);
    wakeSourceFailureCount.fetch_add(1);
    wakeSourceConfigurationFailed = true;
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: EXT1 wake configuration failed: %s "
                  "(%d) mask=0x%llX\n",
                  esp_err_to_name(result), result,
                  static_cast<unsigned long long>(gpioMask));
#endif
    return false;
  }

  runtimeStatus.ext1WakeMask = gpioMask;
  wakeSourcesReady = !wakeSourceConfigurationFailed;
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
  Serial.printf("Power management: EXT1 active-low wake mask=0x%llX\n",
                static_cast<unsigned long long>(gpioMask));
#endif
#else
  (void)gpioMask;
#endif
  return true;
}

bool configureActiveLowGpioWakeup(uint8_t gpioNumber) {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  wakeSourcesReady = false;
  if (gpioNumber >= 64 || !GPIO_IS_VALID_GPIO(gpioNumber)) {
    setError(ESP_ERR_INVALID_ARG);
    wakeSourceFailureCount.fetch_add(1);
    wakeSourceConfigurationFailed = true;
    return false;
  }

  const gpio_num_t gpio = static_cast<gpio_num_t>(gpioNumber);
  const esp_err_t pinResult = gpio_wakeup_enable(gpio, GPIO_INTR_LOW_LEVEL);
  if (pinResult != ESP_OK) {
    setError(pinResult);
    wakeSourceFailureCount.fetch_add(1);
    wakeSourceConfigurationFailed = true;
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: GPIO%u wake configuration failed: %s "
                  "(%d)\n",
                  static_cast<unsigned>(gpioNumber),
                  esp_err_to_name(pinResult), pinResult);
#endif
    return false;
  }

  const esp_err_t sourceResult = esp_sleep_enable_gpio_wakeup();
  if (sourceResult != ESP_OK) {
    gpio_wakeup_disable(gpio);
    setError(sourceResult);
    wakeSourceFailureCount.fetch_add(1);
    wakeSourceConfigurationFailed = true;
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
    Serial.printf("Power management: GPIO wake source enable failed: %s "
                  "(%d) pin=%u\n",
                  esp_err_to_name(sourceResult), sourceResult,
                  static_cast<unsigned>(gpioNumber));
#endif
    return false;
  }

  runtimeStatus.gpioWakeMask |= 1ULL << gpioNumber;
  wakeSourcesReady = !wakeSourceConfigurationFailed;
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
  Serial.printf("Power management: GPIO active-low wake pin=%u mask=0x%llX\n",
                static_cast<unsigned>(gpioNumber),
                static_cast<unsigned long long>(runtimeStatus.gpioWakeMask));
#endif
#else
  (void)gpioNumber;
#endif
  return true;
}

bool setGpioWakeNotifier(GpioWakeNotifier notifier) {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  if (notifier == nullptr) {
    setError(ESP_ERR_INVALID_ARG);
    wakeSourceFailureCount.fetch_add(1);
    wakeSourceConfigurationFailed = true;
    return false;
  }
  gpioWakeNotifier.store(notifier, std::memory_order_release);
#else
  (void)notifier;
#endif
  return true;
}

bool acquire(LockDomain domain) {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  if (!validDomain(domain)) {
    lockFailureCount.fetch_add(1);
    return false;
  }
  LockHandle handle = lockHandles[static_cast<size_t>(domain)];
  if (handle == nullptr) {
    lockFailureCount.fetch_add(1);
    return false;
  }
  const esp_err_t result = esp_pm_lock_acquire(handle);
  if (result != ESP_OK) {
    setError(result);
    lockFailureCount.fetch_add(1);
    return false;
  }
  noteAcquired();
  return true;
#else
  (void)domain;
  return true;
#endif
}

bool release(LockDomain domain) {
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  if (!validDomain(domain)) {
    lockFailureCount.fetch_add(1);
    return false;
  }
  LockHandle handle = lockHandles[static_cast<size_t>(domain)];
  if (handle == nullptr) {
    lockFailureCount.fetch_add(1);
    return false;
  }
  const esp_err_t result = esp_pm_lock_release(handle);
  if (result != ESP_OK) {
    setError(result);
    lockFailureCount.fetch_add(1);
    return false;
  }
  activeLockCount.fetch_sub(1);
  return true;
#else
  (void)domain;
  return true;
#endif
}

ScopedLock::ScopedLock(LockDomain domain)
    : domain_(domain), held_(acquire(domain)) {}

ScopedLock::~ScopedLock() {
  if (held_) {
    release(domain_);
  }
}

RuntimeStatus status() {
  RuntimeStatus snapshot = runtimeStatus;
  snapshot.errorCode = lastErrorCode.load();
  snapshot.activeLockCount = activeLockCount.load();
  snapshot.peakLockCount = peakLockCount.load();
  snapshot.lockFailureCount = lockFailureCount.load();
  snapshot.lastGpioWakeMask =
      (static_cast<uint64_t>(
           lastGpioWakeMaskHigh.load(std::memory_order_relaxed))
       << 32) |
      lastGpioWakeMaskLow.load(std::memory_order_relaxed);
  snapshot.gpioWakeEventCount =
      gpioWakeEventCount.load(std::memory_order_relaxed);
  snapshot.wakeSourceFailureCount = wakeSourceFailureCount.load();
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT
  snapshot.wakeCaptureReady = wakeCaptureRegistered;
  snapshot.wakeNotifierReady =
      gpioWakeNotifier.load(std::memory_order_relaxed) != nullptr;
#endif
  return snapshot;
}

} // namespace power_management
