#pragma once

#include <cmath>
#include <cstdint>

namespace map_render_policy {

constexpr uint32_t kMinimumRenderIntervalMs = 750;
constexpr double kMovementThresholdMeters = 8.0;
constexpr uint16_t kHeadingThresholdDegrees = 12;

enum class Reason : uint32_t {
  Position = 1u << 0,
  Heading = 1u << 1,
  Route = 1u << 2,
  Style = 1u << 3,
  Zoom = 1u << 4,
  Screen = 1u << 5,
  Recovery = 1u << 6,
  Other = 1u << 7,
};

constexpr uint32_t reasonMask(Reason reason) {
  return static_cast<uint32_t>(reason);
}

struct Fix {
  double latitude = 0.0;
  double longitude = 0.0;
  uint16_t headingDegrees = 0;
};

struct Decision {
  bool render = false;
  bool deferredByCadence = false;
  uint32_t reasons = 0;
  double distanceMeters = 0.0;
  uint16_t headingDeltaDegrees = 0;
};

inline uint16_t headingDelta(uint16_t first, uint16_t second) {
  const uint16_t normalizedFirst = first % 360U;
  const uint16_t normalizedSecond = second % 360U;
  const uint16_t direct = normalizedFirst > normalizedSecond
                              ? normalizedFirst - normalizedSecond
                              : normalizedSecond - normalizedFirst;
  return direct > 180U ? 360U - direct : direct;
}

inline double distanceMeters(const Fix &first, const Fix &second) {
  constexpr double kRadiansPerDegree =
      3.14159265358979323846 / 180.0;
  constexpr double kEarthRadiusMeters = 6371000.0;
  const double firstLatitude = first.latitude * kRadiansPerDegree;
  const double secondLatitude = second.latitude * kRadiansPerDegree;
  const double latitudeDelta =
      (second.latitude - first.latitude) * kRadiansPerDegree;
  const double longitudeDelta =
      (second.longitude - first.longitude) * kRadiansPerDegree;
  const double sinLatitude = std::sin(latitudeDelta / 2.0);
  const double sinLongitude = std::sin(longitudeDelta / 2.0);
  const double a = sinLatitude * sinLatitude +
                   std::cos(firstLatitude) * std::cos(secondLatitude) *
                       sinLongitude * sinLongitude;
  const double clamped = a > 1.0 ? 1.0 : (a < 0.0 ? 0.0 : a);
  return 2.0 * kEarthRadiusMeters *
         std::atan2(std::sqrt(clamped), std::sqrt(1.0 - clamped));
}

class Scheduler {
public:
  void request(Reason reason) { pendingForcedReasons_ |= reasonMask(reason); }

  void observe(const Fix &fix) {
    observedFix_ = fix;
    hasObservation_ = true;
  }

  Decision evaluate(uint32_t nowMs, bool allowPosition, bool courseUp) {
    Decision decision;
    decision.reasons = pendingForcedReasons_;

    if (!hasRenderedFix_) {
      if (hasObservation_) {
        decision.reasons |= reasonMask(Reason::Position);
      }
      decision.render = decision.reasons != 0;
      return decision;
    }

    if (hasObservation_) {
      decision.distanceMeters =
          map_render_policy::distanceMeters(renderedFix_, observedFix_);
      decision.headingDeltaDegrees = map_render_policy::headingDelta(
          renderedFix_.headingDegrees, observedFix_.headingDegrees);
    }

    if (decision.reasons != 0) {
      decision.render = true;
      return decision;
    }

    if (!hasObservation_) {
      return decision;
    }

    const bool moved =
        allowPosition && decision.distanceMeters >= kMovementThresholdMeters;
    const bool turned = courseUp &&
                        decision.headingDeltaDegrees >=
                            kHeadingThresholdDegrees;
    if (!moved && !turned) {
      hasObservation_ = false;
      return decision;
    }

    if (static_cast<uint32_t>(nowMs - lastRenderMs_) <
        kMinimumRenderIntervalMs) {
      decision.deferredByCadence = true;
      return decision;
    }

    if (moved) {
      decision.reasons |= reasonMask(Reason::Position);
    }
    if (turned) {
      decision.reasons |= reasonMask(Reason::Heading);
    }
    decision.render = true;
    return decision;
  }

  void commit(const Decision &decision) {
    if (decision.render) {
      pendingForcedReasons_ |= decision.reasons;
    }
  }

  void markRendered(uint32_t nowMs, const Fix &renderedFix) {
    renderedFix_ = renderedFix;
    observedFix_ = renderedFix;
    hasRenderedFix_ = true;
    hasObservation_ = false;
    pendingForcedReasons_ = 0;
    lastRenderMs_ = nowMs;
  }

  void markInterrupted() { request(Reason::Recovery); }

  void discardObservation() { hasObservation_ = false; }

  bool hasPendingWork() const {
    return pendingForcedReasons_ != 0 || hasObservation_;
  }

  uint32_t pendingForcedReasons() const { return pendingForcedReasons_; }

private:
  Fix renderedFix_{};
  Fix observedFix_{};
  uint32_t lastRenderMs_ = 0;
  uint32_t pendingForcedReasons_ = 0;
  bool hasRenderedFix_ = false;
  bool hasObservation_ = false;
};

} // namespace map_render_policy
