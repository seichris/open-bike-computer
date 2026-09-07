#pragma once

#include "ride_automation_policy.hpp"
#include "ride_detection_health.hpp"

#include <cstddef>
#include <cstdint>

namespace ride_automation {

// Source-neutral seam for direct wheel/cadence sensors (future issue #85).
// Implementations append only fresh metrics and must leave unavailable values
// absent rather than writing zero.
class CyclingMotionSource {
public:
  virtual ~CyclingMotionSource() = default;
  virtual void appendEvidence(uint32_t nowMs,
                              RideEvidenceObservation &observation) const = 0;
};

// Phase 0/1 runtime is intentionally incapable of mutating workout state. It
// exposes the policy output only for trace capture and bounded diagnostics.
class ShadowRuntime {
public:
  static constexpr bool kCanControlRide = false;

  Decision update(uint32_t nowMs, const RideEvidenceObservation &observation,
                  ConfirmedLifecycle lifecycle, const Settings &settings) {
    const Decision decision = policy_.update(nowMs, observation, lifecycle,
                                             settings);
    lastDecision_ = decision;
    return decision;
  }

  const Decision &lastDecision() const { return lastDecision_; }
  const ShadowCounters &counters() const { return policy_.counters(); }
  uint16_t lastEvidenceMask() const { return policy_.lastEvidenceMask(); }
  const RideAutomationPolicy &policy() const { return policy_; }
  RideAutomationPolicy &policy() { return policy_; }

private:
  RideAutomationPolicy policy_;
  Decision lastDecision_{};
};

static_assert(!ShadowRuntime::kCanControlRide,
              "Shadow runtime must never control a ride");

} // namespace ride_automation

namespace ride_automation_runtime {

// Deadline applies even when no transport acknowledgement ever arrives.
inline bool decisionTransportExpired(uint32_t nowMs, uint32_t beganAtMs) {
  return nowMs - beganAtMs >= 30'000U;
}

inline bool shouldEndDetailedCapture(
    ride_automation::ConfirmedLifecycle previous,
    ride_automation::ConfirmedLifecycle current) {
  return previous != ride_automation::ConfirmedLifecycle::Finished &&
         current == ride_automation::ConfirmedLifecycle::Finished;
}

// A short BLE gap must not end an opted-in ride trace, but once the device has
// received no live workout state for five minutes it can no longer observe a
// remote ride-end transition. Stop the privacy-sensitive detailed stream
// conservatively instead of replaying stale state until the four-hour cap.
constexpr uint32_t kDetailedCaptureTelemetryLossGraceMs = 5U * 60U * 1000U;

inline bool shouldEndDetailedCaptureAfterTelemetryLoss(
    ride_automation::ConfirmedLifecycle retained,
    bool workoutTelemetryStale, uint32_t nowMs,
    uint32_t lastCoreReceivedAtMs) {
  const bool rideWasActive =
      retained == ride_automation::ConfirmedLifecycle::Running ||
      retained == ride_automation::ConfirmedLifecycle::AutomaticallyPaused ||
      retained == ride_automation::ConfirmedLifecycle::ManuallyPaused;
  return rideWasActive && workoutTelemetryStale &&
         static_cast<uint32_t>(nowMs - lastCoreReceivedAtMs) >=
             kDetailedCaptureTelemetryLossGraceMs;
}

enum class UiPhase : uint8_t {
  Hidden = 0,
  StartCandidate,
  StartPrompt,
  Starting,
  PauseCandidate,
  AwaitingPause,
  ResumeCandidate,
  AwaitingResume,
  RideResumed,
  SensorDegraded,
  Error,
};

enum class UiError : uint8_t {
  None = 0,
  PhoneOrWatchUnavailable,
  Rejected,
  SessionMismatch,
};

inline bool shouldShowAutomationPanel(UiPhase phase) {
  return phase != UiPhase::Hidden && phase != UiPhase::SensorDegraded;
}

inline bool shouldShowDetectionWaitingMessage(UiPhase phase,
                                              bool startWorkoutVisible) {
  return startWorkoutVisible && phase == UiPhase::SensorDegraded;
}

struct UiSnapshot {
  UiPhase phase = UiPhase::Hidden;
  UiError error = UiError::None;
  uint8_t progressPercent = 0;
  uint32_t decisionSequence = 0;
  uint8_t remainingSeconds = 0;
  ride_automation::DetectionHealth detectionHealth{};
};

struct ConfigurationSnapshot {
  ride_automation::StartMode startMode = ride_automation::StartMode::Ask;
  bool autoPauseEnabled = true;
  uint8_t alertMode = 0;
  uint32_t generation = 0;
};

void setCyclingMotionSource(const ride_automation::CyclingMotionSource *source);
void beginFirmwareShadow();
void processFirmwareShadow(uint32_t nowMs);
bool ingestTransportFrame(const uint8_t *data, std::size_t length,
                          uint32_t receivedAtMs);
UiSnapshot uiSnapshot(uint32_t nowMs);
bool respondToStartPrompt(bool accept, uint32_t nowMs);
bool needsAttention(uint32_t nowMs);
ConfigurationSnapshot configurationSnapshot();
bool setLocalConfiguration(ride_automation::StartMode startMode,
                           bool autoPauseEnabled, uint8_t alertMode);

} // namespace ride_automation_runtime
