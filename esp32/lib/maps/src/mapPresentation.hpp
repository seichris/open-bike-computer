#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace map_presentation {

constexpr double kPi = 3.14159265358979323846;

inline double normalizeDegrees(double degrees) {
  if (!std::isfinite(degrees))
    return 0.0;
  degrees = std::fmod(degrees, 360.0);
  if (degrees < 0.0)
    degrees += 360.0;
  return degrees;
}

inline double signedHeadingDelta(double from, double to) {
  double delta = normalizeDegrees(to) - normalizeDegrees(from);
  if (delta > 180.0)
    delta -= 360.0;
  if (delta < -180.0)
    delta += 360.0;
  return delta;
}

/** Marker rotation in screen degrees. Map rotation is negative for course-up,
 * so adding it to the world heading leaves the marker upright on a course-up
 * map and points it along the course on a north-up map. */
inline double markerRotationDegrees(double headingDegrees,
                                    double displayedMapRotationRad) {
  return normalizeDegrees(headingDegrees +
                          displayedMapRotationRad * 180.0 / kPi);
}

struct WorldPoint {
  double x = 0.0;
  double y = 0.0;
};

struct ScreenPoint {
  double x = 0.0;
  double y = 0.0;
};

/**
 * Apply the exact 2D transform used to present an older complete base frame:
 * rotate around the projected rider point, then place that pivot at the live
 * screen anchor. Route and marker geometry use this same function, so even a
 * bird's-eye raster remains pixel-aligned while a replacement frame renders.
 */
inline ScreenPoint presentFramePoint(ScreenPoint projected,
                                     ScreenPoint projectedPivot,
                                     ScreenPoint screenAnchor,
                                     double rotationDeltaRad) {
  const double dx = projected.x - projectedPivot.x;
  const double dy = projected.y - projectedPivot.y;
  const double cosine = std::cos(rotationDeltaRad);
  const double sine = std::sin(rotationDeltaRad);
  return {screenAnchor.x + cosine * dx - sine * dy,
          screenAnchor.y + sine * dx + cosine * dy};
}

/**
 * Prove that the complete visible viewport inverse-transforms into a finished
 * overscanned frame. This is checked immediately before publication because a
 * rider can move or turn while the worker is rendering. Publishing a frame
 * without this invariant would expose blank edges or spatially stale pixels.
 */
inline bool frameCoversViewport(double renderWidth, double renderHeight,
                                double viewportWidth, double viewportHeight,
                                ScreenPoint projectedPivot,
                                ScreenPoint screenAnchor,
                                double rotationDeltaRad,
                                double safetyPixels) {
  if (!(renderWidth > 0.0 && renderHeight > 0.0 && viewportWidth > 0.0 &&
        viewportHeight > 0.0 && safetyPixels >= 0.0)) {
    return false;
  }
  const double cosine = std::cos(rotationDeltaRad);
  const double sine = std::sin(rotationDeltaRad);
  const ScreenPoint corners[] = {{0.0, 0.0},
                                 {viewportWidth, 0.0},
                                 {viewportWidth, viewportHeight},
                                 {0.0, viewportHeight}};
  for (const ScreenPoint &corner : corners) {
    const double dx = corner.x - screenAnchor.x;
    const double dy = corner.y - screenAnchor.y;
    // Inverse of presentFramePoint's rotation.
    const double sourceX = projectedPivot.x + cosine * dx + sine * dy;
    const double sourceY = projectedPivot.y - sine * dx + cosine * dy;
    if (sourceX < safetyPixels || sourceY < safetyPixels ||
        sourceX > renderWidth - safetyPixels ||
        sourceY > renderHeight - safetyPixels) {
      return false;
    }
  }
  return true;
}

struct Fix {
  WorldPoint position{};
  double headingDegrees = 0.0;
  bool headingValid = false;
  double speedMetersPerSecond = 0.0;
  // Web Mercator is locally stretched by sec(latitude). Keeping that scale in
  // the fix lets prediction remain bounded in real metres while producing a
  // position in the exact world-coordinate space used by the map renderer.
  double worldUnitsPerMeter = 1.0;
  // Local monotonic time when the GPS packet was accepted. This deliberately
  // remains separate from the later UI time at which heading convergence may
  // re-observe the same physical fix.
  uint32_t timestampMs = 0;
};

struct PresentedPose {
  WorldPoint position{};
  double headingDegrees = 0.0;
  bool headingValid = false;
  uint32_t sourceTimestampMs = 0;
  uint32_t observationAgeMs = 0;
  uint32_t predictionAgeMs = 0;
  bool predictionGraceActive = false;
  bool predictionExhausted = false;
};

/**
 * Explicit measured-course/route-bearing resolver.  Invalid Core Location
 * courses never turn into north; the remembered value is scoped to one
 * navigation epoch and is discarded on a mode/session change.
 */
class HeadingResolver {
public:
  enum class Source : uint8_t { None, Measured, Route, Remembered };

  void setNavigationSession(bool active, uint32_t epoch) {
    if (active_ == active && epoch_ == epoch)
      return;
    active_ = active;
    epoch_ = epoch;
    valid_ = false;
    heading_ = 0.0;
    source_ = Source::None;
  }

  bool resolve(bool measuredValid, double measuredDegrees,
               bool routeValid, double routeDegrees, double &resolved,
               bool preferRoute = false) {
    if (!active_) {
      valid_ = false;
      source_ = Source::None;
      return false;
    }
    if (preferRoute && routeValid && std::isfinite(routeDegrees)) {
      heading_ = normalizeDegrees(routeDegrees);
      valid_ = true;
      source_ = Source::Route;
    } else if (measuredValid && std::isfinite(measuredDegrees) &&
        measuredDegrees >= 0.0) {
      heading_ = normalizeDegrees(measuredDegrees);
      valid_ = true;
      source_ = Source::Measured;
    } else if (routeValid && std::isfinite(routeDegrees)) {
      heading_ = normalizeDegrees(routeDegrees);
      valid_ = true;
      source_ = Source::Route;
    } else if (valid_) {
      source_ = Source::Remembered;
    } else {
      source_ = Source::None;
      return false;
    }
    resolved = heading_;
    return true;
  }

  Source source() const { return source_; }
  bool valid() const { return valid_; }
  uint32_t epoch() const { return epoch_; }

private:
  bool active_ = false;
  bool valid_ = false;
  uint32_t epoch_ = 0;
  double heading_ = 0.0;
  Source source_ = Source::None;
};

/**
 * Presentation-time interpolation with deliberately finite prediction.  The
 * rider advances between BLE fixes, then stops at the declared horizon rather
 * than drifting forever.  A new fix converges over a bounded interval instead
 * of teleporting the foreground independently of the base map.
 */
class Presenter {
public:
  struct Config {
    // A healthy navigation session supplies a pose heartbeat every second.
    // Keep ordinary interpolation at full speed through 1.5 seconds, then
    // decelerate to a bounded stop at 2.5 seconds. This bridges one missed
    // heartbeat without turning transport loss into unbounded dead reckoning.
    uint32_t fullSpeedPredictionMs = 1500;
    uint32_t maximumPredictionMs = 2500;
    uint32_t convergenceMs = 350;
    // The 70 m default equals the most the 35 m/s supported-speed clamp can
    // travel under the integrated 2.5-second horizon. The time horizon remains
    // authoritative, so the distance guard cannot end a missed-heartbeat
    // bridge early at a valid cycling speed.
    double maximumPredictionMeters = 70.0;
    double maximumSpeedMetersPerSecond = 35.0;
  };

  Presenter() = default;
  explicit Presenter(const Config &config) : config_(config) {}

  void reset() {
    hasFix_ = false;
    current_ = {};
    previousPresented_ = {};
    predictionHeadingDegrees_ = 0.0;
    predictionHeadingValid_ = false;
    positionConvergenceStartMs_ = 0;
    headingConvergenceStartMs_ = 0;
  }

  /** Start a new heading epoch without teleporting the presented position.
   * Both sides of heading convergence are cleared so an invalid first fix in
   * the new epoch cannot inherit the prior route's direction. */
  void resetHeading(uint32_t nowMs) {
    if (!hasFix_)
      return;
    // Freeze the exact pose that is currently on screen before removing its
    // direction. Prediction direction belongs to the physical fix, so clear it
    // with the heading epoch and wait for the next fix before moving again.
    const PresentedPose frozen = present(nowMs);
    current_.position = frozen.position;
    current_.timestampMs = frozen.sourceTimestampMs;
    current_.headingDegrees = 0.0;
    current_.headingValid = false;
    predictionHeadingDegrees_ = 0.0;
    predictionHeadingValid_ = false;
    previousPresented_ = frozen;
    previousPresented_.headingDegrees = 0.0;
    previousPresented_.headingValid = false;
    positionConvergenceStartMs_ = nowMs;
    headingConvergenceStartMs_ = nowMs;
  }

  void observe(const Fix &fix, uint32_t receivedAtMs) {
    Fix normalized = fix;
    normalized.speedMetersPerSecond = std::max(
        0.0, std::min(config_.maximumSpeedMetersPerSecond,
                      std::isfinite(fix.speedMetersPerSecond)
                          ? fix.speedMetersPerSecond
                          : 0.0));
    normalized.worldUnitsPerMeter =
        std::isfinite(fix.worldUnitsPerMeter) &&
                fix.worldUnitsPerMeter > 0.0
            ? fix.worldUnitsPerMeter
            : 1.0;
    normalized.headingDegrees = normalizeDegrees(fix.headingDegrees);
    if (hasFix_) {
      previousPresented_ = present(receivedAtMs);
      positionConvergenceStartMs_ = receivedAtMs;
      headingConvergenceStartMs_ = receivedAtMs;
    } else {
      previousPresented_.position = normalized.position;
      previousPresented_.headingDegrees = normalized.headingDegrees;
      previousPresented_.headingValid = normalized.headingValid;
      previousPresented_.sourceTimestampMs = normalized.timestampMs;
      previousPresented_.observationAgeMs = 0;
      previousPresented_.predictionAgeMs = 0;
      previousPresented_.predictionGraceActive = false;
      previousPresented_.predictionExhausted = false;
      positionConvergenceStartMs_ = receivedAtMs;
      headingConvergenceStartMs_ = receivedAtMs;
    }
    current_ = normalized;
    predictionHeadingDegrees_ = normalized.headingDegrees;
    predictionHeadingValid_ = normalized.headingValid;
    hasFix_ = true;
  }

  /** Update presentation direction without re-observing the physical fix.
   *
   * A route window can refine course while the GPS packet is unchanged. It may
   * rotate the map and marker, but the predicted path remains owned by the last
   * physical fix. This also preserves an in-progress position correction and
   * prevents an exhausted endpoint from moving to a newly rotated location.
   */
  void updateHeading(double headingDegrees, bool headingValid,
                     uint32_t nowMs) {
    if (!hasFix_)
      return;
    const PresentedPose frozen = present(nowMs);
    previousPresented_.headingDegrees = frozen.headingDegrees;
    previousPresented_.headingValid = frozen.headingValid;
    current_.headingDegrees = normalizeDegrees(headingDegrees);
    current_.headingValid = headingValid;
    headingConvergenceStartMs_ = nowMs;
  }

  bool hasFix() const { return hasFix_; }

  PresentedPose present(uint32_t nowMs) const {
    if (!hasFix_)
      return {};

    // Fix::timestampMs is the accepted GPS-packet time. Keep freshness tied to
    // that source while later route-bearing updates affect only display
    // heading convergence.
    const uint32_t ageMs = nowMs - current_.timestampMs;
    const uint32_t predictionMs =
        std::min(ageMs, config_.maximumPredictionMs);
    const uint32_t fullSpeedPredictionMs =
        std::min(config_.fullSpeedPredictionMs,
                 config_.maximumPredictionMs);
    const double effectivePredictionMs =
        integratedPredictionMs(predictionMs, fullSpeedPredictionMs);
    const double uncappedDistanceMeters =
        current_.speedMetersPerSecond * effectivePredictionMs / 1000.0;
    const double maximumPredictionMeters =
        std::max(0.0, config_.maximumPredictionMeters);
    const double distanceMeters =
        std::min(uncappedDistanceMeters, maximumPredictionMeters);
    const double distance = distanceMeters * current_.worldUnitsPerMeter;

    WorldPoint predicted = current_.position;
    if (predictionHeadingValid_ && distance > 0.0) {
      const double radians = normalizeDegrees(predictionHeadingDegrees_) *
                             kPi / 180.0;
      predicted.x += std::sin(radians) * distance;
      predicted.y += std::cos(radians) * distance;
    }

    const double positionBlend =
        convergenceBlend(nowMs, positionConvergenceStartMs_);
    const double headingBlend =
        convergenceBlend(nowMs, headingConvergenceStartMs_);

    PresentedPose pose;
    pose.position.x = previousPresented_.position.x +
                      (predicted.x - previousPresented_.position.x) *
                          positionBlend;
    pose.position.y = previousPresented_.position.y +
                      (predicted.y - previousPresented_.position.y) *
                          positionBlend;
    pose.headingValid = current_.headingValid || previousPresented_.headingValid;
    if (current_.headingValid) {
      const double from = previousPresented_.headingValid
                              ? previousPresented_.headingDegrees
                              : current_.headingDegrees;
      pose.headingDegrees = normalizeDegrees(
          from + signedHeadingDelta(from, current_.headingDegrees) *
                     headingBlend);
    } else if (previousPresented_.headingValid) {
      // An invalid fix carries no new direction. Keep the last valid heading
      // instead of interpolating its default zero value (north), which would
      // make the map snap north whenever a GPS course briefly disappears.
      pose.headingDegrees = previousPresented_.headingDegrees;
    }
    pose.sourceTimestampMs = current_.timestampMs;
    pose.observationAgeMs = ageMs;
    pose.predictionAgeMs = predictionMs;
    const bool timeExhausted = ageMs >= config_.maximumPredictionMs;
    const bool distanceExhausted =
        current_.speedMetersPerSecond > 0.0 &&
        uncappedDistanceMeters >= maximumPredictionMeters;
    pose.predictionExhausted = timeExhausted || distanceExhausted;
    pose.predictionGraceActive =
        !pose.predictionExhausted && ageMs > fullSpeedPredictionMs;
    return pose;
  }

private:
  double convergenceBlend(uint32_t nowMs, uint32_t startedAtMs) const {
    if (config_.convergenceMs == 0)
      return 1.0;
    double blend =
        std::min(1.0, static_cast<double>(nowMs - startedAtMs) /
                          config_.convergenceMs);
    // Smoothstep has zero slope at both ends and avoids a visible kink.
    return blend * blend * (3.0 - 2.0 * blend);
  }

  double integratedPredictionMs(uint32_t predictionMs,
                                uint32_t fullSpeedPredictionMs) const {
    if (predictionMs <= fullSpeedPredictionMs ||
        config_.maximumPredictionMs <= fullSpeedPredictionMs) {
      return predictionMs;
    }
    const double graceElapsedMs =
        static_cast<double>(predictionMs - fullSpeedPredictionMs);
    const double graceDurationMs = static_cast<double>(
        config_.maximumPredictionMs - fullSpeedPredictionMs);
    // Integrate a velocity that falls linearly from 100% to 0% over the grace
    // window. Position remains monotonic and settles without visual reversal.
    return fullSpeedPredictionMs + graceElapsedMs -
           graceElapsedMs * graceElapsedMs / (2.0 * graceDurationMs);
  }

  Config config_{};
  bool hasFix_ = false;
  Fix current_{};
  PresentedPose previousPresented_{};
  double predictionHeadingDegrees_ = 0.0;
  bool predictionHeadingValid_ = false;
  uint32_t positionConvergenceStartMs_ = 0;
  uint32_t headingConvergenceStartMs_ = 0;
};

inline double refreshLeadPixels(double speedMetersPerSecond,
                                double pixelsPerMeter,
                                uint32_t worstCaseRenderLatencyMs,
                                double safetyPixels,
                                double minimumPixels,
                                double maximumPixels) {
  const double dynamic = std::max(0.0, speedMetersPerSecond) *
                             std::max(0.0, pixelsPerMeter) *
                             worstCaseRenderLatencyMs / 1000.0 +
                         std::max(0.0, safetyPixels);
  return std::max(minimumPixels, std::min(maximumPixels, dynamic));
}

} // namespace map_presentation
