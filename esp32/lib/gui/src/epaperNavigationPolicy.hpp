#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

// Pure, allocation-free policy for the Waveshare 3.97-inch navigation
// presentation. Platform clocks, LVGL, storage and worker ownership stay with
// the callers so this contract remains deterministic on the host.
namespace epaper_navigation_policy {

constexpr uint32_t kMinimumBaseSubmissionIntervalMs = 1000;
constexpr uint32_t kMaximumMovingDeferralMs = 2000;
constexpr double kMarkerDeadbandPixels = 2.0;
constexpr double kRecenterThresholdPixels = 6.0;
constexpr double kHeadingThresholdDegrees = 10.0;
constexpr double kClearTurnDegrees = 20.0;
constexpr double kHeadingHoldBelowKmh = 4.0;
constexpr double kHeadingResumeAboveKmh = 6.0;
constexpr double kHeadingTimeConstantMs = 1500.0;

enum class Reason : uint32_t {
  Position = 1U << 0,
  Heading = 1U << 1,
  MaximumDeferral = 1U << 2,
  Screen = 1U << 3,
  MapContext = 1U << 4,
  RouteSession = 1U << 5,
  Recovery = 1U << 6,
};

constexpr uint32_t reasonMask(Reason reason) {
  return static_cast<uint32_t>(reason);
}

constexpr uint32_t kHardReasonMask =
    reasonMask(Reason::Screen) | reasonMask(Reason::MapContext) |
    reasonMask(Reason::RouteSession) | reasonMask(Reason::Recovery);

inline double normalizeDegrees(double value) {
  while (value < 0.0)
    value += 360.0;
  while (value >= 360.0)
    value -= 360.0;
  return value;
}

inline double headingDeltaDegrees(double first, double second) {
  const double direct =
      std::fabs(normalizeDegrees(first) - normalizeDegrees(second));
  return direct > 180.0 ? 360.0 - direct : direct;
}

struct HeadingSample {
  uint32_t sequence = 0;
  uint32_t capturedAtMs = 0;
  double speedKmh = 0.0;
  double headingDegrees = 0.0;
  bool headingValid = false;
};

struct FilteredHeading {
  double degrees = 0.0;
  bool valid = false;
  bool courseDriven = false;
};

class HeadingFilter {
public:
  FilteredHeading observe(const HeadingSample &sample) {
    // Capture timestamps are uint32_t device-clock values. Reject a delayed
    // sample without disturbing either the held heading or speed hysteresis;
    // the signed comparison remains correct across normal millis() wrap.
    if (initialized_ && lastCapturedAtMs_ != 0 &&
        static_cast<int32_t>(sample.capturedAtMs - lastCapturedAtMs_) < 0) {
      return {heading(), initialized_, courseDriven_};
    }
    const bool wasCourseDriven = courseDriven_;
    if (courseDriven_) {
      if (sample.speedKmh < kHeadingHoldBelowKmh)
        courseDriven_ = false;
    } else if (sample.speedKmh >= kHeadingResumeAboveKmh) {
      courseDriven_ = true;
    }

    if (!sample.headingValid) {
      return {heading(), initialized_, courseDriven_};
    }

    // A stationary first fix is useful as a held orientation, but subsequent
    // low-speed noise cannot rotate the camera until the resume threshold is
    // crossed.
    if (!initialized_) {
      const double radians = normalizeDegrees(sample.headingDegrees) *
                             kPi / 180.0;
      x_ = std::cos(radians);
      y_ = std::sin(radians);
      initialized_ = true;
      lastCapturedAtMs_ = sample.capturedAtMs;
    } else if (courseDriven_) {
      const uint32_t elapsedMs =
          lastCapturedAtMs_ == 0
              ? static_cast<uint32_t>(kHeadingTimeConstantMs)
              : static_cast<uint32_t>(sample.capturedAtMs -
                                      lastCapturedAtMs_);
      const double alpha = wasCourseDriven
                               ? 1.0 - std::exp(-static_cast<double>(elapsedMs) /
                                                kHeadingTimeConstantMs)
                               : 1.0;
      const double radians = normalizeDegrees(sample.headingDegrees) *
                             kPi / 180.0;
      x_ += alpha * (std::cos(radians) - x_);
      y_ += alpha * (std::sin(radians) - y_);
      const double magnitude = std::hypot(x_, y_);
      if (magnitude > 1e-9) {
        x_ /= magnitude;
        y_ /= magnitude;
      }
      lastCapturedAtMs_ = sample.capturedAtMs;
    }
    return {heading(), initialized_, courseDriven_};
  }

  FilteredHeading current() const {
    return {heading(), initialized_, courseDriven_};
  }

  void reset() { *this = {}; }

private:
  static constexpr double kPi = 3.14159265358979323846;

  double heading() const {
    return initialized_
               ? normalizeDegrees(std::atan2(y_, x_) * 180.0 / kPi)
               : 0.0;
  }

  double x_ = 1.0;
  double y_ = 0.0;
  uint32_t lastCapturedAtMs_ = 0;
  bool initialized_ = false;
  bool courseDriven_ = false;
};

struct Fix {
  uint32_t sequence = 0;
  uint32_t capturedAtMs = 0;
  double speedKmh = 0.0;
  double filteredHeadingDegrees = 0.0;
  bool filteredHeadingValid = false;
};

struct CameraState {
  bool hasBase = false;
  bool baseCompatible = false;
  bool mapCoverageAvailable = false;
  bool riderProjected = false;
  bool riderInsideViewport = false;
  double riderOffsetPixels = 0.0;
  double headingDeltaDegrees = 0.0;
  uint32_t baseAcceptedAtMs = 0;
  uint32_t baseFixSequence = 0;
  uint32_t baseCameraSequence = 0;
  bool renderRunning = false;
  bool successorPending = false;
  uint32_t latestRequestedFixSequence = 0;
};

enum class Visibility : uint8_t {
  NoBase,
  Compatible,
  Recentering,
  NoCoverage,
  Incompatible,
  RiderOutsideCoverage,
};

inline Visibility visibility(const CameraState &camera,
                             bool updateRequired) {
  if (!camera.hasBase)
    return Visibility::NoBase;
  if (!camera.baseCompatible)
    return Visibility::Incompatible;
  if (!camera.mapCoverageAvailable)
    return Visibility::NoCoverage;
  if (!camera.riderProjected || !camera.riderInsideViewport)
    return Visibility::RiderOutsideCoverage;
  return updateRequired ? Visibility::Recentering : Visibility::Compatible;
}

struct Decision {
  bool updateForeground = false;
  bool submitBase = false;
  bool urgent = false;
  bool keepRunning = false;
  bool replacePending = false;
  bool hardInvalidation = false;
  uint32_t reasons = 0;
};

class Scheduler {
public:
  void request(Reason reason) { forcedReasons_ |= reasonMask(reason); }

  void observe(const Fix &fix) {
    if (fix.sequence == 0)
      return;
    latestFix_ = fix;
    hasFix_ = true;
  }

  Decision evaluate(uint32_t nowMs, const CameraState &camera,
                    bool followPosition, bool courseUp) const {
    Decision decision;
    decision.updateForeground = hasFix_;
    decision.reasons = forcedReasons_;
    decision.hardInvalidation = (decision.reasons & kHardReasonMask) != 0;
    decision.keepRunning = camera.renderRunning && !decision.hardInvalidation;

    if (!camera.hasBase && hasFix_)
      decision.reasons |= reasonMask(Reason::Position);
    if (camera.hasBase && !camera.baseCompatible)
      decision.reasons |= reasonMask(Reason::MapContext);

    if (hasFix_ && camera.hasBase && camera.baseCompatible) {
      if (followPosition && camera.riderProjected &&
          camera.riderOffsetPixels >= kRecenterThresholdPixels) {
        decision.reasons |= reasonMask(Reason::Position);
      }
      if (courseUp && latestFix_.filteredHeadingValid &&
          camera.headingDeltaDegrees >= kHeadingThresholdDegrees) {
        decision.reasons |= reasonMask(Reason::Heading);
      }
      const bool moving = latestFix_.speedKmh >= kHeadingHoldBelowKmh;
      const bool foregroundDrift =
          camera.riderOffsetPixels >= kMarkerDeadbandPixels ||
          (courseUp && camera.headingDeltaDegrees >=
                           kHeadingThresholdDegrees / 2.0);
      if (moving && foregroundDrift && camera.baseAcceptedAtMs != 0 &&
          static_cast<uint32_t>(nowMs - camera.baseAcceptedAtMs) >=
              kMaximumMovingDeferralMs) {
        decision.reasons |= reasonMask(Reason::MaximumDeferral);
      }
      if (camera.headingDeltaDegrees >= kClearTurnDegrees)
        decision.urgent = true;
    }

    const bool requested = decision.reasons != 0;
    if (!requested)
      return decision;

    const bool cadenceDue =
        lastSubmissionMs_ == 0 || decision.hardInvalidation ||
        static_cast<uint32_t>(nowMs - lastSubmissionMs_) >=
            kMinimumBaseSubmissionIntervalMs;
    if (!cadenceDue)
      return decision;

    if (camera.successorPending && hasFix_ &&
        latestFix_.sequence <= camera.latestRequestedFixSequence &&
        !decision.hardInvalidation) {
      return decision;
    }

    decision.submitBase = true;
    decision.replacePending = camera.successorPending;
    decision.urgent = decision.urgent || decision.hardInvalidation;
    return decision;
  }

  void markSubmitted(uint32_t nowMs, const Fix &fix, uint32_t reasons) {
    lastSubmissionMs_ = nowMs == 0 ? 1 : nowMs;
    latestSubmittedFix_ = fix;
    forcedReasons_ &= ~reasons;
  }

  void markPublished(uint32_t nowMs, const Fix &capturedFix) {
    lastPublishedMs_ = nowMs;
    publishedFix_ = capturedFix;
  }

  void markInterrupted() { request(Reason::Recovery); }

  uint32_t pendingForcedReasons() const { return forcedReasons_; }
  bool hasPendingWork() const { return hasFix_ || forcedReasons_ != 0; }
  const Fix &latestFix() const { return latestFix_; }
  const Fix &publishedFix() const { return publishedFix_; }
  uint32_t lastPublishedMs() const { return lastPublishedMs_; }

private:
  Fix latestFix_{};
  Fix latestSubmittedFix_{};
  Fix publishedFix_{};
  uint32_t lastSubmissionMs_ = 0;
  uint32_t lastPublishedMs_ = 0;
  uint32_t forcedReasons_ = 0;
  bool hasFix_ = false;
};

enum class Disposition : uint8_t {
  None,
  Foreground,
  Base,
  Coalesced,
  Duplicate,
  Invalid,
  Stale,
  Deadband,
  Incompatible,
};

struct DispositionCounters {
  uint32_t accepted = 0;
  uint32_t foreground = 0;
  uint32_t base = 0;
  uint32_t coalesced = 0;
  uint32_t ignored = 0;
};

struct DispositionEvent {
  uint32_t sequence = 0;
  uint32_t newerSequence = 0;
  Disposition disposition = Disposition::None;
};

class DispositionLedger {
public:
  DispositionEvent accept(uint32_t sequence) {
    if (sequence == 0)
      return {};
    if (sequence == pendingSequence_ || sequence == terminalSequence_)
      return {sequence, 0, Disposition::Duplicate};
    DispositionEvent event;
    if (pendingSequence_ != 0) {
      event = terminal(pendingSequence_, Disposition::Coalesced, sequence);
    }
    pendingSequence_ = sequence;
    ++counters_.accepted;
    return event;
  }

  DispositionEvent foreground(uint32_t sequence) {
    return terminal(sequence, Disposition::Foreground, 0);
  }

  DispositionEvent base(uint32_t sequence) {
    return terminal(sequence, Disposition::Base, 0);
  }

  DispositionEvent ignore(uint32_t sequence, Disposition reason) {
    return terminal(sequence, reason, 0);
  }

  const DispositionCounters &counters() const { return counters_; }
  uint32_t pendingSequence() const { return pendingSequence_; }

private:
  DispositionEvent terminal(uint32_t sequence, Disposition disposition,
                            uint32_t newerSequence) {
    if (sequence == 0 || sequence != pendingSequence_)
      return {};
    pendingSequence_ = 0;
    terminalSequence_ = sequence;
    switch (disposition) {
    case Disposition::Foreground:
      ++counters_.foreground;
      break;
    case Disposition::Base:
      ++counters_.base;
      break;
    case Disposition::Coalesced:
      ++counters_.coalesced;
      break;
    default:
      ++counters_.ignored;
      break;
    }
    return {sequence, newerSequence, disposition};
  }

  DispositionCounters counters_{};
  uint32_t pendingSequence_ = 0;
  uint32_t terminalSequence_ = 0;
};

inline uint16_t quantizeDistanceMeters(uint16_t distanceMeters) {
  const uint16_t quantum = distanceMeters > 100 ? 10 : 5;
  return static_cast<uint16_t>(((distanceMeters + quantum / 2U) / quantum) *
                               quantum);
}

} // namespace epaper_navigation_policy
