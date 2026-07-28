/**
 * @file mapPinchZoom.hpp
 * @brief Pure two-contact pinch ownership and zoom-settlement state machine.
 */

#pragma once

#include "../../maps/src/mapTransform.hpp"
#include <cmath>
#include <cstdint>

namespace map_pinch_zoom {

struct Contact {
  uint8_t id = 0;
  int16_t x = 0;
  int16_t y = 0;
};

struct Frame {
  uint32_t sequence = 0;
  uint8_t count = 0;
  Contact contacts[2] = {};
};

enum class State : uint8_t {
  Idle = 0,
  Candidate,
  Active,
  SuppressedUntilRelease,
};

enum class Action : uint8_t { None = 0, Begin, Update, Commit, Cancel };

struct Decision {
  Action action = Action::None;
  double previewRatio = 1.0;
  int16_t midpointX = 0;
  int16_t midpointY = 0;
  uint8_t targetZoom = map_transform::kMinimumRuntimeZoom;
};

class Controller {
public:
  Decision update(const Frame &frame, uint8_t runtimeZoom) {
    if (frame.sequence == lastSequence_) {
      return {};
    }
    lastSequence_ = frame.sequence;

    if (state_ == State::SuppressedUntilRelease) {
      if (frame.count == 0) {
        reset();
      }
      return {};
    }

    if (frame.count < 2) {
      return handleContactLoss(frame.count);
    }
    releaseFrames_ = 0;

    Contact first;
    Contact second;
    if (!orderedContacts(frame, first, second)) {
      return cancelToSuppressed(frame.count);
    }

    const double distance = contactDistance(first, second);
    const int16_t midpointX =
        static_cast<int16_t>((static_cast<int32_t>(first.x) + second.x) / 2);
    const int16_t midpointY =
        static_cast<int16_t>((static_cast<int32_t>(first.y) + second.y) / 2);

    if (state_ == State::Idle) {
      if (distance < kMinimumInitialSeparationPx) {
        return {};
      }
      state_ = State::Candidate;
      baseZoom_ = map_transform::clampRuntimeZoom(runtimeZoom);
      firstId_ = first.id;
      secondId_ = second.id;
      initialDistance_ = distance;
      filteredRatio_ = 1.0;
      validTwoContactFrames_ = 1;
      lastFirst_ = first;
      lastSecond_ = second;
      lastMidpointX_ = midpointX;
      lastMidpointY_ = midpointY;
      return {Action::Begin, 1.0, midpointX, midpointY, baseZoom_};
    }

    if (first.id != firstId_ || second.id != secondId_) {
      return cancelToSuppressed(frame.count);
    }
    if (implausibleJump(first, lastFirst_) ||
        implausibleJump(second, lastSecond_)) {
      return {};
    }
    lastFirst_ = first;
    lastSecond_ = second;
    lastMidpointX_ = midpointX;
    lastMidpointY_ = midpointY;
    if (validTwoContactFrames_ < 255)
      ++validTwoContactFrames_;

    const double rawRatio = distance / initialDistance_;
    const double activationDelta =
        std::fmax(kActivationDistancePx,
                  initialDistance_ * kActivationDistanceFraction);
    if (state_ == State::Candidate &&
        (validTwoContactFrames_ < kActivationFrames ||
         std::fabs(distance - initialDistance_) < activationDelta)) {
      return {};
    }

    if (state_ == State::Candidate) {
      state_ = State::Active;
      filteredRatio_ = rawRatio;
    } else {
      filteredRatio_ = (kNewSampleWeight * rawRatio) +
                       ((1.0 - kNewSampleWeight) * filteredRatio_);
    }
    filteredRatio_ =
        map_transform::clampPreviewRatio(filteredRatio_, baseZoom_);
    return {Action::Update, filteredRatio_, midpointX, midpointY, baseZoom_};
  }

  Decision cancelForContext(uint8_t contactCount) {
    if (state_ == State::Idle || state_ == State::SuppressedUntilRelease) {
      if (contactCount == 0 && state_ == State::SuppressedUntilRelease)
        reset();
      return {};
    }
    return cancelToSuppressed(contactCount);
  }

  void reset() {
    state_ = State::Idle;
    lastSequence_ = 0;
    firstId_ = 0;
    secondId_ = 0;
    initialDistance_ = 0.0;
    filteredRatio_ = 1.0;
    validTwoContactFrames_ = 0;
    releaseFrames_ = 0;
    lastMidpointX_ = 0;
    lastMidpointY_ = 0;
  }

  State state() const { return state_; }
  bool ownsInput() const { return state_ != State::Idle; }
  bool blocksMapRender() const {
    return state_ == State::Candidate || state_ == State::Active;
  }

private:
  static constexpr double kMinimumInitialSeparationPx = 40.0;
  static constexpr double kActivationDistancePx = 10.0;
  static constexpr double kActivationDistanceFraction = 0.04;
  static constexpr uint8_t kActivationFrames = 2;
  static constexpr uint8_t kReleaseFrames = 2;
  static constexpr int16_t kMaximumSampleJumpPx = 320;
  static constexpr double kNewSampleWeight = 0.65;

  static double contactDistance(const Contact &first, const Contact &second) {
    const double dx = static_cast<double>(second.x) - first.x;
    const double dy = static_cast<double>(second.y) - first.y;
    return std::sqrt((dx * dx) + (dy * dy));
  }

  static bool implausibleJump(const Contact &current, const Contact &previous) {
    return std::abs(static_cast<int>(current.x) - previous.x) >
               kMaximumSampleJumpPx ||
           std::abs(static_cast<int>(current.y) - previous.y) >
               kMaximumSampleJumpPx;
  }

  bool orderedContacts(const Frame &frame, Contact &first,
                       Contact &second) const {
    first = frame.contacts[0];
    second = frame.contacts[1];
    if (second.id < first.id) {
      const Contact swap = first;
      first = second;
      second = swap;
    }
    return first.id != second.id;
  }

  Decision handleContactLoss(uint8_t contactCount) {
    if (state_ == State::Idle)
      return {};
    if (contactCount == 0) {
      releaseFrames_ = kReleaseFrames;
    } else if (releaseFrames_ < kReleaseFrames) {
      ++releaseFrames_;
    }
    if (releaseFrames_ < kReleaseFrames)
      return {};

    if (state_ == State::Active) {
      const double effectiveScale =
          map_transform::worldToScreenScale(baseZoom_) * filteredRatio_;
      const uint8_t target =
          map_transform::nearestRuntimeZoom(effectiveScale);
      if (contactCount == 0)
        state_ = State::Idle;
      else
        state_ = State::SuppressedUntilRelease;
      if (target == baseZoom_) {
        return {Action::Cancel, filteredRatio_, lastMidpointX_,
                lastMidpointY_, baseZoom_};
      }
      return {Action::Commit, filteredRatio_, lastMidpointX_, lastMidpointY_,
              target};
    }
    return cancelToSuppressed(contactCount);
  }

  Decision cancelToSuppressed(uint8_t contactCount) {
    const Decision decision = {Action::Cancel, filteredRatio_, lastMidpointX_,
                               lastMidpointY_, baseZoom_};
    if (contactCount == 0)
      reset();
    else
      state_ = State::SuppressedUntilRelease;
    return decision;
  }

  State state_ = State::Idle;
  uint32_t lastSequence_ = 0;
  uint8_t baseZoom_ = map_transform::kMinimumRuntimeZoom;
  uint8_t firstId_ = 0;
  uint8_t secondId_ = 0;
  double initialDistance_ = 0.0;
  double filteredRatio_ = 1.0;
  uint8_t validTwoContactFrames_ = 0;
  uint8_t releaseFrames_ = 0;
  Contact lastFirst_ = {};
  Contact lastSecond_ = {};
  int16_t lastMidpointX_ = 0;
  int16_t lastMidpointY_ = 0;
};

} // namespace map_pinch_zoom
