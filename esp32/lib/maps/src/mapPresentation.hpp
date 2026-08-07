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

struct Fix {
  WorldPoint position{};
  double headingDegrees = 0.0;
  bool headingValid = false;
  double speedMetersPerSecond = 0.0;
  // Web Mercator is locally stretched by sec(latitude). Keeping that scale in
  // the fix lets prediction remain bounded in real metres while producing a
  // position in the exact world-coordinate space used by the map renderer.
  double worldUnitsPerMeter = 1.0;
  uint32_t timestampMs = 0;
};

struct PresentedPose {
  WorldPoint position{};
  double headingDegrees = 0.0;
  bool headingValid = false;
  uint32_t sourceTimestampMs = 0;
  uint32_t predictionAgeMs = 0;
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
               bool routeValid, double routeDegrees, double &resolved) {
    if (!active_) {
      valid_ = false;
      source_ = Source::None;
      return false;
    }
    if (measuredValid && std::isfinite(measuredDegrees) &&
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
    uint32_t maximumPredictionMs = 1500;
    uint32_t convergenceMs = 350;
    double maximumPredictionMeters = 30.0;
    double maximumSpeedMetersPerSecond = 35.0;
  };

  Presenter() = default;
  explicit Presenter(const Config &config) : config_(config) {}

  void reset() {
    hasFix_ = false;
    current_ = {};
    previousPresented_ = {};
    convergenceStartMs_ = 0;
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
      convergenceStartMs_ = receivedAtMs;
    } else {
      previousPresented_.position = normalized.position;
      previousPresented_.headingDegrees = normalized.headingDegrees;
      previousPresented_.headingValid = normalized.headingValid;
      previousPresented_.sourceTimestampMs = normalized.timestampMs;
      previousPresented_.predictionAgeMs = 0;
      convergenceStartMs_ = receivedAtMs;
    }
    current_ = normalized;
    receivedAtMs_ = receivedAtMs;
    hasFix_ = true;
  }

  bool hasFix() const { return hasFix_; }

  PresentedPose present(uint32_t nowMs) const {
    if (!hasFix_)
      return {};

    const uint32_t ageMs = nowMs - receivedAtMs_;
    const uint32_t predictionMs =
        std::min(ageMs, config_.maximumPredictionMs);
    double distanceMeters =
        current_.speedMetersPerSecond * predictionMs / 1000.0;
    distanceMeters =
        std::min(distanceMeters, config_.maximumPredictionMeters);
    const double distance = distanceMeters * current_.worldUnitsPerMeter;

    WorldPoint predicted = current_.position;
    if (current_.headingValid && distance > 0.0) {
      const double radians = normalizeDegrees(current_.headingDegrees) *
                             kPi / 180.0;
      predicted.x += std::sin(radians) * distance;
      predicted.y += std::cos(radians) * distance;
    }

    double blend = 1.0;
    if (config_.convergenceMs != 0) {
      blend = std::min(1.0, static_cast<double>(nowMs - convergenceStartMs_) /
                                config_.convergenceMs);
      // Smoothstep has zero slope at both ends and avoids a visible kink.
      blend = blend * blend * (3.0 - 2.0 * blend);
    }

    PresentedPose pose;
    pose.position.x = previousPresented_.position.x +
                      (predicted.x - previousPresented_.position.x) * blend;
    pose.position.y = previousPresented_.position.y +
                      (predicted.y - previousPresented_.position.y) * blend;
    pose.headingValid = current_.headingValid || previousPresented_.headingValid;
    if (current_.headingValid) {
      const double from = previousPresented_.headingValid
                              ? previousPresented_.headingDegrees
                              : current_.headingDegrees;
      pose.headingDegrees = normalizeDegrees(
          from + signedHeadingDelta(from, current_.headingDegrees) * blend);
    } else if (previousPresented_.headingValid) {
      // An invalid fix carries no new direction. Keep the last valid heading
      // instead of interpolating its default zero value (north), which would
      // make the map snap north whenever a GPS course briefly disappears.
      pose.headingDegrees = previousPresented_.headingDegrees;
    }
    pose.sourceTimestampMs = current_.timestampMs;
    pose.predictionAgeMs = predictionMs;
    return pose;
  }

private:
  Config config_{};
  bool hasFix_ = false;
  Fix current_{};
  PresentedPose previousPresented_{};
  uint32_t receivedAtMs_ = 0;
  uint32_t convergenceStartMs_ = 0;
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
