#include "sleep_audit.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "sleep_audit_policy.hpp"
#include "../boot_diagnostics/boot_diagnostics.hpp"
#include "../ride_diagnostics/ride_diagnostics.hpp"
#include "../waveshare_board/i2c_bus.hpp"
#include <Arduino.h>
#include <esp_attr.h>
#include <esp_sleep.h>
#include <esp_system.h>
#include <sys/time.h>

namespace sleep_audit {
namespace {

RTC_NOINIT_ATTR policy::Capsule retained;
policy::Resume resume{};
policy::PmicSnapshot earlyPmic{};
boot_diagnostics::Snapshot boot{};
bool initialized = false;
bool sampledEarly = false;
bool publishedBoot = false;
uint32_t wakeCause = 0;
uint64_t wakePins = 0;

int64_t epochUs() {
  // Do not manufacture a cross-reset duration from millis()/esp_timer. Only
  // accept IDF system-time configurations backed by the RTC across deep sleep.
#if CONFIG_NEWLIB_TIME_SYSCALL_USE_RTC_HRT || CONFIG_NEWLIB_TIME_SYSCALL_USE_RTC || \
    CONFIG_LIBC_TIME_SYSCALL_USE_RTC_HRT || CONFIG_LIBC_TIME_SYSCALL_USE_RTC
  timeval now{};
  if (gettimeofday(&now, nullptr) == 0 && now.tv_sec >= 1700000000LL &&
      now.tv_sec <= 4102444800LL && now.tv_usec >= 0 && now.tv_usec < 1000000)
    return static_cast<int64_t>(now.tv_sec) * 1000000LL + now.tv_usec;
#endif
  return 0;
}

policy::PmicSnapshot samplePmic() {
  return policy::samplePmic(
      [](uint8_t reg, uint8_t *data, uint8_t count) {
        return waveshare_board::i2c::readRegisterBlock8Once(
            0x34, reg, data, count);
      }, [] { return static_cast<uint32_t>(millis()); });
}

void attemptId(const policy::Capsule &c, char (&out)[18]) {
  std::snprintf(out, sizeof(out), "%08lX%08lX",
                static_cast<unsigned long>(c.attemptHigh),
                static_cast<unsigned long>(c.attemptLow));
}

bool observe(const char *phase, const char *domain, const char *id,
             const char *state, bool available = true) {
  char fields[512] = {};
  if (!policy::formatObservation(phase, domain, id, state, available,
                                 fields, sizeof(fields)))
    return false;
  return ride_diagnostics::record(ride_diagnostics::Level::Info, "power",
                                   "sleep_audit", fields);
}

uint32_t observePmic(const char *phase, const char *id,
                     const policy::PmicSnapshot &pmic) {
  uint32_t accepted = 0;
  char state[256] = {};
  if (policy::formatRegisters(pmic, state, sizeof(state)) &&
      observe(phase, "pmic_registers", id, state, pmic.validMask != 0))
    accepted |= 1;
  if (policy::formatBattery(pmic, state, sizeof(state)) &&
      observe(phase, "battery", id, state,
               policy::batteryPresent(pmic) >= 0))
    accepted |= 2;
  std::snprintf(state, sizeof(state),
      "read_mask=%08lX;read_ms=%lu;complete=%u;rail_load_map=unverified",
      static_cast<unsigned long>(pmic.validMask),
      static_cast<unsigned long>(pmic.elapsedMs),
      pmic.validMask == policy::kAllRead ? 1U : 0U);
  if (observe(phase, "pmic_read", id, state)) accepted |= 4;
  return accepted;
}

bool observeContext(const char *phase, const char *id,
                    const policy::Capsule &c) {
  char state[256] = {};
  std::snprintf(state, sizeof(state),
      "reason=device_shutdown;runtime_boot=%lu;fingerprint=%08lX;uptime_ms=%lu;"
      "timeout_s=%lu;connected=%u;display_policy=%u;audio_playing=%u;"
      "log_storage=%u;external_sleep=unknown",
      static_cast<unsigned long>(c.bootSequence),
      static_cast<unsigned long>(c.fingerprint),
      static_cast<unsigned long>(c.requestUptimeMs),
      static_cast<unsigned long>(c.configuredTimeoutSeconds),
      c.connected, c.displayState, c.audioPlaying, c.diagnosticsStorageAvailable);
  return observe(phase, "context", id, state);
}

void publishBoot() {
  if (publishedBoot) return;
  publishedBoot = true;
  char id[18] = "none";
  if (resume.previousValid) attemptId(resume.previous, id);
  char state[256] = {};
  char interval[24] = "unknown";
  if (resume.intervalValid)
    std::snprintf(interval, sizeof(interval), "%llu",
                  static_cast<unsigned long long>(resume.intervalMs));
  std::snprintf(state, sizeof(state),
      "classification=%s;reset_code=%lu;wake_cause=%lu;wake_pins=%016llX;"
      "interval_kind=entry_to_early_boot;interval_valid=%u;interval_ms=%s",
      resume.code, static_cast<unsigned long>(boot.resetReason),
      static_cast<unsigned long>(wakeCause),
      static_cast<unsigned long long>(wakePins), resume.intervalValid ? 1U : 0U,
      interval);
  (void)observe("wake", "resume", id, state);
  if (resume.previousValid) {
    const auto &c = resume.previous;
    (void)observeContext("retained_request", id, c);
    (void)observePmic("retained_request", id, c.pmic);
    std::snprintf(state, sizeof(state),
        "stage=%u;request_enqueued_mask=%lu;recorder_sealed=%u;"
        "panel_off_requested=%u;panel_update_applied=%u;spi_end_called=%u;"
        "wire_end_called=%u;requested_wake_mask=%016llX;boot_pin_level=%u",
        c.stage, static_cast<unsigned long>(c.acceptedRequestRecords),
        c.recorderSealed, c.panelOffRequested, c.panelChangeApplied,
        c.spiEndCalled, c.wireEndCalled,
        static_cast<unsigned long long>(c.requestedWakeMask), c.bootPinLevel);
    (void)observe("wake", "checkpoint", id, state);
    std::snprintf(state, sizeof(state),
        "wifi_stop=%ld;bt_stop=%ld;bluedroid_stop=%ld;wake_config=%ld;"
        "not_attempted=%ld;physical_power=unknown",
        static_cast<long>(c.wifiStopResult), static_cast<long>(c.bluetoothStopResult),
        static_cast<long>(c.bluedroidStopResult), static_cast<long>(c.wakeConfigResult),
        static_cast<long>(policy::kNotAttempted));
    (void)observe("wake", "api_results", id, state);
  }
  (void)observePmic("early_boot", id, earlyPmic);
}

void stageCompleted(boot_diagnostics::Stage stage) {
  if (!initialized) return;
  // This is before PMIC initialization, RTC restoration, display or sensor
  // initialization in both production board paths. Do not move sampling to
  // Ready: that would silently report the newly initialized state as a wake
  // observation. Standalone probes do not register this observer.
  if (stage == boot_diagnostics::Stage::I2cBus && !sampledEarly) {
    sampledEarly = true;
    earlyPmic = samplePmic();
  } else if (stage == boot_diagnostics::Stage::Ready) {
    publishBoot(); // normal recorder; no I2C at this late stage
  }
}

bool hasRequest() {
  return initialized && retained.magic == policy::kMagic &&
         retained.fingerprint == boot.firmwareFingerprint;
}

} // namespace

void begin() {
  if (initialized) return;
  initialized = true;
  boot = boot_diagnostics::snapshot();
  wakeCause = static_cast<uint32_t>(esp_sleep_get_wakeup_cause());
  if (wakeCause == static_cast<uint32_t>(ESP_SLEEP_WAKEUP_EXT1))
    wakePins = esp_sleep_get_ext1_wakeup_status();
  // Read time before the board's hardware-RTC restore can overwrite IDF time.
  resume = policy::consume(retained, boot.firmwareFingerprint, boot.resetReason,
                            wakeCause, epochUs());
  boot_diagnostics::setStageCompletionObserver(stageCompleted);
}

void requested(const RequestContext &context) {
  if (!initialized) return;
  std::memset(&retained, 0, sizeof(retained));
  retained.fingerprint = boot.firmwareFingerprint;
  retained.bootSequence = boot.bootSequence;
  retained.attemptHigh = esp_random();
  retained.attemptLow = esp_random();
  retained.stage = static_cast<uint8_t>(policy::Stage::Requested);
  retained.requestUptimeMs = millis();
  retained.configuredTimeoutSeconds = context.configuredTimeoutSeconds;
  retained.connected = context.connected;
  retained.displayState = context.displayState;
  retained.audioPlaying = context.audioPlaying;
  retained.diagnosticsStorageAvailable = ride_diagnostics::stats().storageAvailable;
  retained.bootPinLevel = 255; // unavailable until sampled as an input at entry
  retained.wifiStopResult = retained.bluetoothStopResult =
      retained.bluedroidStopResult = retained.wakeConfigResult = policy::kNotAttempted;
  policy::seal(retained); // a reset during the read still preserves intent
  const auto pmic = samplePmic();
  retained.pmic = pmic;
  policy::seal(retained);
  char id[18] = {};
  attemptId(retained, id);
  retained.acceptedRequestRecords = observePmic("request", id, pmic);
  if (observeContext("request", id, retained)) retained.acceptedRequestRecords |= 8;
  policy::seal(retained);
}

void recorderSealed(bool success) {
  if (!hasRequest()) return;
  retained.recorderSealed = success;
  policy::seal(retained);
}

void panelRequested(bool applied) {
  if (!hasRequest()) return;
  retained.panelOffRequested = 1;
  // False can mean no pending change OR failure. Even true only describes
  // software command dispatch, not controller readback or electrical state.
  retained.panelChangeApplied = applied;
  policy::seal(retained);
}

void peripheralsReturned() {
  if (!hasRequest()) return;
  retained.spiEndCalled = retained.wireEndCalled = 1;
  retained.stage = static_cast<uint8_t>(policy::Stage::PeripheralsReturned);
  policy::seal(retained);
}

void entering(int32_t wifiStop, int32_t btStop, int32_t bluedroidStop,
              int32_t wakeConfig, uint64_t wakeMask, uint8_t bootLevel) {
  if (!hasRequest()) return;
  retained.wifiStopResult = wifiStop;
  retained.bluetoothStopResult = btStop;
  retained.bluedroidStopResult = bluedroidStop;
  retained.wakeConfigResult = wakeConfig;
  retained.requestedWakeMask = wakeMask;
  retained.bootPinLevel = bootLevel;
  retained.entryEpochUs = epochUs();
  retained.stage = static_cast<uint8_t>(policy::Stage::Entering);
  policy::seal(retained);
  // No logging, flushing, peripheral reads, allocation, or wake reconfiguration
  // here. The caller immediately executes its existing deep-sleep call.
}

} // namespace sleep_audit
#endif
