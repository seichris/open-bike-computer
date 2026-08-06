/**
 * @file mapMotion.hpp
 * @brief Small, deterministic presenters for GPS position and course heading.
 *
 * The GPS receiver produces fixes at a much lower rate than the LVGL frame
 * timer.  These presenters keep the render loop independent from that input
 * cadence: position is dead-reckoned for a short, bounded interval and then
 * eases back to the next measured fix; heading uses the same shortest-angle
 * easing so a turn cannot rotate the map in one large step.
 */

#pragma once

#include "mapTransform.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace map_motion {

inline double distanceSquared(map_transform::WorldPoint a,
                              map_transform::WorldPoint b) {
  const double dx = a.x - b.x;
  const double dy = a.y - b.y;
  return dx * dx + dy * dy;
}

inline double clampDelta(double value, double minimum, double maximum) {
  return std::max(minimum, std::min(maximum, value));
}

/**
 * Presents a GPS world position at the display frame rate.
 *
 * A fix is never extrapolated indefinitely.  This is important when a phone
 * loses GPS: a stale velocity must not move the map away from the last known
 * position forever.  The presenter is deliberately value-only so it can be
 * exercised in host tests without Arduino or LVGL.
 */
class PositionPresenter {
public:
  map_transform::WorldPoint update(map_transform::WorldPoint raw,
                                   uint32_t nowMs) {
    if (!initialized_) {
      initialized_ = true;
      target_ = raw;
      displayed_ = raw;
      velocity_ = {};
      lastFixMs_ = nowMs;
      lastFrameMs_ = nowMs;
      return displayed_;
    }

    const uint32_t sinceFixMs = nowMs - lastFixMs_;
    if (distanceSquared(raw, target_) > kFixChangeEpsilonSquared) {
      const double intervalSeconds = clampDelta(
          static_cast<double>(sinceFixMs) / 1000.0, 0.05, 2.0);
      lastFixIntervalMs_ = std::max<uint32_t>(
          kMinimumPredictionMs,
          std::min<uint32_t>(kMaximumPredictionMs, sinceFixMs));
      const map_transform::WorldPoint measuredVelocity = {
          (raw.x - target_.x) / intervalSeconds,
          (raw.y - target_.y) / intervalSeconds};
      const double measuredSpeed =
          std::hypot(measuredVelocity.x, measuredVelocity.y);
      if (measuredSpeed <= kMaximumWorldSpeedPerSecond) {
        // Keep most of the measured velocity so a normally spaced fix can be
        // presented continuously, while retaining enough previous velocity
        // to avoid a single noisy fix causing a visible jerk.
        velocity_.x = velocity_.x * 0.35 + measuredVelocity.x * 0.65;
        velocity_.y = velocity_.y * 0.35 + measuredVelocity.y * 0.65;
      } else {
        // A jump this large is a teleport or a bad fix, not a bicycle speed.
        // Snap the target and wait for a trustworthy subsequent measurement.
        velocity_ = {};
      }
      target_ = raw;
      lastFixMs_ = nowMs;
    }

    const uint32_t frameDeltaMs = nowMs - lastFrameMs_;
    const double frameDeltaSeconds = clampDelta(
        static_cast<double>(frameDeltaMs) / 1000.0, 0.0, 0.05);
    // Native GPS writes are driven by Core Location's distance filter and are
    // not guaranteed to arrive at a fixed one-second cadence. Match the
    // bounded dead-reckoning window to the most recent accepted fix interval
    // instead of stopping at a hard 750 ms on a slower phone update. The
    // horizon remains bounded and the stale decay still brings the presenter
    // back to the last measured point when the link goes quiet.
    const uint32_t predictionHorizonMs = std::max<uint32_t>(
        kMinimumPredictionMs,
        std::min<uint32_t>(kMaximumPredictionMs, lastFixIntervalMs_));
    const uint32_t predictionAgeMs =
        std::min<uint32_t>(nowMs - lastFixMs_, predictionHorizonMs);
    const double predictionSeconds =
        static_cast<double>(predictionAgeMs) / 1000.0;
    const uint32_t staleAgeMs =
        nowMs - lastFixMs_ > predictionHorizonMs
            ? nowMs - lastFixMs_ - predictionHorizonMs
            : 0;
    const double staleVelocityScale = std::exp(
        -static_cast<double>(staleAgeMs) / 1000.0 /
        kStaleVelocityDecaySeconds);
    const map_transform::WorldPoint predicted = {
        target_.x + velocity_.x * predictionSeconds * staleVelocityScale,
        target_.y + velocity_.y * predictionSeconds * staleVelocityScale};

    if (frameDeltaSeconds > 0.0) {
      const double response =
          1.0 - std::exp(-frameDeltaSeconds / kResponseTimeSeconds);
      displayed_.x += (predicted.x - displayed_.x) * response;
      displayed_.y += (predicted.y - displayed_.y) * response;
    }
    lastFrameMs_ = nowMs;
    return displayed_;
  }

  void reset() {
    initialized_ = false;
    target_ = {};
    displayed_ = {};
    velocity_ = {};
    lastFixMs_ = 0;
    lastFixIntervalMs_ = kMinimumPredictionMs;
    lastFrameMs_ = 0;
  }

  bool initialized() const { return initialized_; }

private:
  static constexpr double kFixChangeEpsilonSquared = 1e-8;
  static constexpr double kMaximumWorldSpeedPerSecond = 100.0;
  static constexpr uint32_t kMinimumPredictionMs = 750;
  static constexpr uint32_t kMaximumPredictionMs = 1800;
  static constexpr double kResponseTimeSeconds = 0.14;
  static constexpr double kStaleVelocityDecaySeconds = 0.18;

  bool initialized_ = false;
  map_transform::WorldPoint target_{};
  map_transform::WorldPoint displayed_{};
  map_transform::WorldPoint velocity_{};
  uint32_t lastFixMs_ = 0;
  uint32_t lastFixIntervalMs_ = kMinimumPredictionMs;
  uint32_t lastFrameMs_ = 0;
};

/**
 * Smooths a compass/course value in degrees using the shortest turn.
 *
 * The revision is retained as an input for callers that want to correlate the
 * sample with route data, but it deliberately does not reset the filter:
 * sliding geometry windows are expected during one navigation session and
 * resetting on each window would reintroduce a heading snap. Calls made in
 * the same millisecond return the current value, which keeps the scheduler and
 * renderer consistent when they sample the heading during one UI cycle.
 */
class HeadingPresenter {
public:
  uint16_t update(double rawDegrees, uint32_t nowMs, uint32_t routeRevision) {
    rawDegrees = normalize(rawDegrees);
    if (!initialized_) {
      initialized_ = true;
      routeRevision_ = routeRevision;
      displayedDegrees_ = rawDegrees;
      lastUpdateMs_ = nowMs;
      return rounded(displayedDegrees_);
    }
    routeRevision_ = routeRevision;

    const uint32_t elapsedMs = nowMs - lastUpdateMs_;
    if (elapsedMs == 0) {
      return rounded(displayedDegrees_);
    }

    const double elapsedSeconds = clampDelta(
        static_cast<double>(elapsedMs) / 1000.0, 0.0, 0.25);
    const double difference = shortestDifference(rawDegrees, displayedDegrees_);
    const double response =
        1.0 - std::exp(-elapsedSeconds / kResponseTimeSeconds);
    const double maximumStep = std::max(4.0, 120.0 * elapsedSeconds);
    const double step = clampDelta(difference * response, -maximumStep,
                                   maximumStep);
    displayedDegrees_ = normalize(displayedDegrees_ + step);
    lastUpdateMs_ = nowMs;
    return rounded(displayedDegrees_);
  }

  void reset() {
    initialized_ = false;
    displayedDegrees_ = 0.0;
    routeRevision_ = 0;
    lastUpdateMs_ = 0;
  }

private:
  static constexpr double kResponseTimeSeconds = 0.18;

  static double normalize(double degrees) {
    degrees = std::fmod(degrees, 360.0);
    if (degrees < 0.0)
      degrees += 360.0;
    return degrees;
  }

  static double shortestDifference(double target, double current) {
    double difference = normalize(target) - normalize(current);
    if (difference > 180.0)
      difference -= 360.0;
    if (difference < -180.0)
      difference += 360.0;
    return difference;
  }

  static uint16_t rounded(double degrees) {
    const int32_t value = static_cast<int32_t>(std::lround(normalize(degrees)));
    return static_cast<uint16_t>(value % 360);
  }

  bool initialized_ = false;
  double displayedDegrees_ = 0.0;
  uint32_t routeRevision_ = 0;
  uint32_t lastUpdateMs_ = 0;
};

} // namespace map_motion
