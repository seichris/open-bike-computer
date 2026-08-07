#pragma once

#include <cstddef>
#include <cstdint>

namespace map_render_job {

/**
 * Immutable semantic version captured by every render request.  Sequence is
 * strictly monotonic; the remaining epochs make stale-publication diagnostics
 * actionable instead of merely reporting "old frame".
 */
struct Version {
  uint32_t sequence = 0;
  uint32_t routeRevision = 0;
  uint32_t navigationEpoch = 0;
  uint32_t styleEpoch = 0;
  uint32_t mapEpoch = 0;
  uint32_t projectionEpoch = 0;

  bool operator==(const Version &other) const {
    return sequence == other.sequence &&
           routeRevision == other.routeRevision &&
           navigationEpoch == other.navigationEpoch &&
           styleEpoch == other.styleEpoch && mapEpoch == other.mapEpoch &&
           projectionEpoch == other.projectionEpoch;
  }

  bool operator!=(const Version &other) const { return !(*this == other); }

  // Sequence identifies a submission. The remaining fields identify the
  // frame contract, so a completed overscanned frame can still be published
  // after a position-only request supersedes it.
  static bool sameFrame(const Version &left, const Version &right) {
    return left.routeRevision == right.routeRevision &&
           left.navigationEpoch == right.navigationEpoch &&
           left.styleEpoch == right.styleEpoch &&
           left.mapEpoch == right.mapEpoch &&
           left.projectionEpoch == right.projectionEpoch;
  }
};

enum class State : uint8_t { Idle, Rendering, Ready };
enum class StopReason : uint8_t { None, Superseded, Shutdown, Invariant };

struct Diagnostics {
  uint32_t submitted = 0;
  uint32_t started = 0;
  uint32_t completed = 0;
  uint32_t cancelled = 0;
  uint32_t stalePublications = 0;
  uint32_t invariantFailures = 0;
  uint32_t published = 0;
  uint32_t boundedSlices = 0;
  uint32_t longestSliceUs = 0;
};

/**
 * Lock-free policy core for a single render worker and a single publisher.
 * Synchronisation is deliberately supplied by the caller, so this contract is
 * executable on the host and can be wrapped by a tiny FreeRTOS critical
 * section on device.
 */
class LatestWins {
public:
  Version submit(Version request) {
    if (request.sequence <= latest_.sequence) {
      request.sequence = latest_.sequence + 1;
    }
    latest_ = request;
    diagnostics_.submitted++;
    return latest_;
  }

  bool hasRequestNewerThan(uint32_t sequence) const {
    return latest_.sequence > sequence;
  }

  const Version &latest() const { return latest_; }
  const Version &active() const { return active_; }
  const Version &ready() const { return ready_; }
  State state() const { return state_; }
  const Diagnostics &diagnostics() const { return diagnostics_; }

  bool beginLatest() {
    // The ready frame owns the back surface until the UI publishes it.
    if (latest_.sequence == 0 || state_ == State::Ready ||
        (state_ == State::Rendering && active_ == latest_)) {
      return false;
    }
    active_ = latest_;
    activeCancellationGeneration_ = cancellationGeneration_;
    state_ = State::Rendering;
    diagnostics_.started++;
    return true;
  }

  StopReason checkpoint(bool shutdownRequested = false) const {
    if (shutdownRequested)
      return StopReason::Shutdown;
    if (state_ != State::Rendering)
      return StopReason::Invariant;
    if (activeCancellationGeneration_ != cancellationGeneration_ ||
        !Version::sameFrame(active_, latest_))
      return StopReason::Superseded;
    return StopReason::None;
  }

  void noteSlice(uint32_t elapsedUs, uint32_t declaredMaximumUs) {
    noteSlices(1, elapsedUs, declaredMaximumUs);
  }

  void noteSlices(uint32_t count, uint32_t longestElapsedUs,
                  uint32_t declaredMaximumUs) {
    diagnostics_.boundedSlices += count;
    if (longestElapsedUs > diagnostics_.longestSliceUs)
      diagnostics_.longestSliceUs = longestElapsedUs;
    if (declaredMaximumUs != 0 && longestElapsedUs > declaredMaximumUs)
      sliceBudgetExceeded_ = true;
  }

  bool sliceBudgetExceeded() const { return sliceBudgetExceeded_; }

  void cancelActive() {
    if (state_ == State::Rendering) {
      diagnostics_.cancelled++;
      state_ = State::Idle;
      active_ = {};
    }
  }

  bool completeActive() {
    if (state_ != State::Rendering)
      return false;
    if (activeCancellationGeneration_ != cancellationGeneration_ ||
        !Version::sameFrame(active_, latest_)) {
      diagnostics_.cancelled++;
      state_ = State::Idle;
      active_ = {};
      return false;
    }
    ready_ = active_;
    readyCancellationGeneration_ = activeCancellationGeneration_;
    active_ = {};
    state_ = State::Ready;
    diagnostics_.completed++;
    return true;
  }

  /**
   * Publication is valid only while the completed semantic version is still
   * latest.  A route/style/navigation change between render completion and the
   * next LVGL tick rejects the frame without exposing it.
   */
  bool takeReady(Version &published) {
    if (state_ != State::Ready)
      return false;
    if (readyCancellationGeneration_ != cancellationGeneration_ ||
        !Version::sameFrame(ready_, latest_)) {
      diagnostics_.stalePublications++;
      ready_ = {};
      state_ = State::Idle;
      return false;
    }
    published = ready_;
    diagnostics_.published++;
    ready_ = {};
    state_ = State::Idle;
    return true;
  }

  void rejectReadyAsStale() {
    if (state_ == State::Ready) {
      diagnostics_.stalePublications++;
      ready_ = {};
      state_ = State::Idle;
    }
  }

  void rejectReadyAsInvariant() {
    if (state_ == State::Ready) {
      diagnostics_.invariantFailures++;
      ready_ = {};
      state_ = State::Idle;
    }
  }

  // Semantic invalidations cancel the active unit. Position-only latest
  // requests remain coalesced and do not starve publication of the current
  // complete frame.
  void requestCancellation() { ++cancellationGeneration_; }

  /**
   * Invalidate every active/ready result while preserving the monotonic
   * sequence. This is used when an LVGL screen is destroyed while the raw
   * worker is still allowed to finish its current bounded work unit.
   */
  Version invalidate() {
    Version invalidated = latest_;
    invalidated.sequence = latest_.sequence + 1U;
    ++cancellationGeneration_;
    latest_ = invalidated;
    if (state_ == State::Rendering)
      diagnostics_.cancelled++;
    else if (state_ == State::Ready)
      diagnostics_.stalePublications++;
    active_ = {};
    ready_ = {};
    activeCancellationGeneration_ = cancellationGeneration_;
    readyCancellationGeneration_ = cancellationGeneration_;
    state_ = State::Idle;
    return latest_;
  }

  void reset() {
    latest_ = {};
    active_ = {};
    ready_ = {};
    state_ = State::Idle;
    sliceBudgetExceeded_ = false;
    cancellationGeneration_ = 0;
    activeCancellationGeneration_ = 0;
    readyCancellationGeneration_ = 0;
  }

private:
  Version latest_{};
  Version active_{};
  Version ready_{};
  State state_ = State::Idle;
  Diagnostics diagnostics_{};
  bool sliceBudgetExceeded_ = false;
  uint32_t cancellationGeneration_ = 0;
  uint32_t activeCancellationGeneration_ = 0;
  uint32_t readyCancellationGeneration_ = 0;
};

} // namespace map_render_job
