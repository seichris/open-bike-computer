#include "firmware_maintenance.hpp"

#include "firmware_maintenance_policy.hpp"

#include <Arduino.h>
#include <atomic>
#include <esp_attr.h>
#include <esp_system.h>

namespace firmware_maintenance {
namespace {

RTC_NOINIT_ATTR policy::Request retainedRequest;
std::atomic<uint8_t> runtimeStage{static_cast<uint8_t>(Stage::Normal)};
std::atomic<bool> runtimeActive{false};
std::atomic<bool> runtimeExitRequested{false};
uint32_t runtimeCorrelation = 0;
uint32_t runtimeStartedAtMs = 0;

} // namespace

const char *stageName(Stage value) {
  switch (value) {
  case Stage::Normal:
    return "normal";
  case Stage::RebootPending:
    return "reboot_pending";
  case Stage::AwaitingAuthentication:
    return "awaiting_authentication";
  case Stage::NetworkStarting:
    return "network_starting";
  case Stage::Ready:
    return "ready";
  case Stage::Receiving:
    return "receiving";
  case Stage::Verifying:
    return "verifying";
  case Stage::Committing:
    return "committing";
  case Stage::Rebooting:
    return "rebooting";
  case Stage::Cancelling:
    return "cancelling";
  case Stage::Failed:
    return "failed";
  }
  return "invalid";
}

bool active() { return runtimeActive.load(std::memory_order_acquire); }

Stage stage() {
  return static_cast<Stage>(runtimeStage.load(std::memory_order_acquire));
}

uint32_t correlation() { return runtimeCorrelation; }

uint32_t activeSinceMs() { return runtimeStartedAtMs; }

bool requestNextBoot(uint32_t firmwareFingerprint) {
  if (firmwareFingerprint == 0 || active())
    return false;
  retainedRequest = policy::make(firmwareFingerprint, esp_random());
  runtimeCorrelation = retainedRequest.correlation;
  runtimeStartedAtMs = millis();
  runtimeExitRequested.store(false, std::memory_order_release);
  runtimeStage.store(static_cast<uint8_t>(Stage::RebootPending),
                     std::memory_order_release);
  return policy::valid(retainedRequest);
}

bool consumeForCurrentBoot(uint32_t firmwareFingerprint, uint32_t resetReason) {
  uint32_t acceptedCorrelation = 0;
  const bool accepted = policy::consume(retainedRequest, firmwareFingerprint,
                                        resetReason, acceptedCorrelation);
  runtimeCorrelation = acceptedCorrelation;
  runtimeStartedAtMs = accepted ? millis() : 0;
  runtimeExitRequested.store(false, std::memory_order_release);
  runtimeActive.store(accepted, std::memory_order_release);
  runtimeStage.store(
      static_cast<uint8_t>(accepted ? Stage::AwaitingAuthentication
                                    : Stage::Normal),
      std::memory_order_release);
  return accepted;
}

void setStage(Stage value) {
  if (!active() && value != Stage::RebootPending && value != Stage::Normal)
    return;
  runtimeStage.store(static_cast<uint8_t>(value), std::memory_order_release);
}

void requestExit() {
  if (!active())
    return;
  runtimeExitRequested.store(true, std::memory_order_release);
  setStage(Stage::Cancelling);
}

bool exitRequested() {
  return runtimeExitRequested.load(std::memory_order_acquire);
}

} // namespace firmware_maintenance
