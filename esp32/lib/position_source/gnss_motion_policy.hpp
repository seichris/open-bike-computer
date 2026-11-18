#pragma once

#include <cmath>
#include <cstdint>

// Standalone movement from the board's own GNSS receiver, for power
// decisions on boards that have one (docs/firmware-power-management.md).
//
// Without a phone the board only knows it is being ridden from its own fixes.
// A stationary receiver still reports speed and position jitter, so movement
// needs a fresh valid fix, a speed above the start threshold for consecutive
// samples, and real displacement. It continues while the speed stays above a
// lower stop threshold and the position keeps progressing, and ends once the
// speed stays low, the progress check fails, or no valid fix arrives for
// kStopMs. Only the receiver feeds this detector: phone positions, which may
// be simulated, never count.
namespace gnss_motion {

// About 9 km/h: a slow cyclist rather than receiver jitter.
constexpr float kStartSpeedKmh = 9.0F;
// Below about 4 km/h (walking pace) the board counts as stationary.
constexpr float kStopSpeedKmh = 4.0F;
// Consecutive valid fast samples (the receiver reports about once a second).
constexpr uint8_t kStartSamples = 3;
// Net displacement from the first fast sample before movement is confirmed.
constexpr float kStartDisplacementMeters = 15.0F;
// Samples further apart than this do not count as consecutive.
constexpr uint32_t kMaximumSampleGapMs = 3'000;
// Slow, invalid or missing fixes for this long end the movement.
constexpr uint32_t kStopMs = 10'000;
// While moving, the position must progress this far in each window; speed
// alone never keeps the detector moving indefinitely.
constexpr uint32_t kProgressWindowMs = 30'000;
constexpr float kProgressMinimumMeters = 30.0F;

struct Sample {
  uint32_t capturedAtMs = 0;
  // A spatial fix (not time-only or estimated) with a valid location.
  bool locationValid = false;
  bool speedValid = false;
  float speedKmh = 0.0F;
  double latitude = 0.0;
  double longitude = 0.0;
};

// Equirectangular distance; ample for tens to hundreds of metres.
inline float distanceMeters(double latitudeA, double longitudeA,
                            double latitudeB, double longitudeB) {
  constexpr double kEarthRadiusMeters = 6'371'008.8;
  constexpr double kRadiansPerDegree = 3.14159265358979323846 / 180.0;
  const double meanLatitude =
      (latitudeA + latitudeB) * 0.5 * kRadiansPerDegree;
  const double dLatitude = (latitudeB - latitudeA) * kRadiansPerDegree;
  const double dLongitude =
      (longitudeB - longitudeA) * kRadiansPerDegree * std::cos(meanLatitude);
  return static_cast<float>(
      kEarthRadiusMeters *
      std::sqrt(dLatitude * dLatitude + dLongitude * dLongitude));
}

enum class Transition : uint8_t { None = 0, Started = 1, Stopped = 2 };

class Detector {
public:
  // Every receiver fix, in order (main loop).
  void observe(const Sample &sample) {
    const bool consecutive =
        haveLastSample_ &&
        static_cast<uint32_t>(sample.capturedAtMs - lastSampleMs_) <=
            kMaximumSampleGapMs;
    haveLastSample_ = true;
    lastSampleMs_ = sample.capturedAtMs;
    if (!sample.locationValid || !sample.speedValid) {
      candidateSamples_ = 0;
      return;
    }
    if (moving_) {
      observeWhileMoving(sample);
      return;
    }
    if (sample.speedKmh < kStartSpeedKmh) {
      candidateSamples_ = 0;
      return;
    }
    if (candidateSamples_ == 0 || !consecutive) {
      candidateSamples_ = 0;
      candidateAnchor_ = sample;
    }
    if (candidateSamples_ < UINT8_MAX)
      ++candidateSamples_;
    if (candidateSamples_ >= kStartSamples &&
        distanceMeters(candidateAnchor_.latitude, candidateAnchor_.longitude,
                       sample.latitude, sample.longitude) >=
            kStartDisplacementMeters) {
      start(sample);
    }
  }

  // Every loop pass: ends movement when no moving fix arrived for kStopMs.
  void tick(uint32_t nowMs) {
    if (moving_ &&
        static_cast<uint32_t>(nowMs - lastMovementMs_) >= kStopMs) {
      stop(nowMs);
    }
  }

  bool moving() const { return moving_; }
  // Movement has been confirmed at least once; lastMovementMs() is valid.
  bool moved() const { return moved_; }
  // The last fix that still counted as movement.
  uint32_t lastMovementMs() const { return lastMovementMs_; }
  uint32_t movementStartedMs() const { return movementStartedMs_; }

  Transition takeTransition() {
    const Transition transition = transition_;
    transition_ = Transition::None;
    return transition;
  }

private:
  void observeWhileMoving(const Sample &sample) {
    if (static_cast<uint32_t>(sample.capturedAtMs - progressAnchor_.capturedAtMs) >=
        kProgressWindowMs) {
      if (distanceMeters(progressAnchor_.latitude, progressAnchor_.longitude,
                         sample.latitude, sample.longitude) <
          kProgressMinimumMeters) {
        // Speed without progress: jitter or a parked rider. The last real
        // movement time stands, so the bounded hold runs from there.
        stop(sample.capturedAtMs);
        return;
      }
      progressAnchor_ = sample;
    }
    if (sample.speedKmh >= kStopSpeedKmh)
      lastMovementMs_ = sample.capturedAtMs;
  }

  void start(const Sample &sample) {
    moving_ = true;
    moved_ = true;
    movementStartedMs_ = candidateAnchor_.capturedAtMs;
    lastMovementMs_ = sample.capturedAtMs;
    progressAnchor_ = sample;
    candidateSamples_ = 0;
    transition_ = Transition::Started;
  }

  void stop(uint32_t) {
    moving_ = false;
    candidateSamples_ = 0;
    transition_ = Transition::Stopped;
  }

  bool moving_ = false;
  bool moved_ = false;
  bool haveLastSample_ = false;
  uint32_t lastSampleMs_ = 0;
  uint32_t lastMovementMs_ = 0;
  uint32_t movementStartedMs_ = 0;
  uint8_t candidateSamples_ = 0;
  Sample candidateAnchor_{};
  Sample progressAnchor_{};
  Transition transition_ = Transition::None;
};

} // namespace gnss_motion
