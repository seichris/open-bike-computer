#pragma once

#include "workout_telemetry_protocol.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace workout_telemetry {

template <typename T> struct OptionalMetric {
  bool available = false;
  T value = 0;
};

struct State {
  workout_telemetry_protocol::SessionState sessionState =
      workout_telemetry_protocol::SessionState::Idle;
  uint16_t sessionToken = 0;
  uint32_t lastCoreReceivedAtMs = 0;
  uint32_t lastExtendedReceivedAtMs = 0;
  uint32_t pendingUnavailableCoreReceivedAtMs = 0;
  bool coreReceived = false;
  bool extendedReceived = false;
  bool transportUnavailable = false;
  bool pendingUnavailableCore = false;
  bool originReceived = false;

  OptionalMetric<uint32_t> elapsedSeconds{};
  OptionalMetric<uint32_t> distanceMeters{};
  OptionalMetric<uint16_t> speedCentimetersPerSecond{};
  // Highest speed observed in the accepted workout telemetry stream. HealthKit
  // exposes the speed samples, but the device only needs the terminal maximum
  // and can retain it without expanding the BLE frame contract.
  OptionalMetric<uint16_t> maximumSpeedCentimetersPerSecond{};
  OptionalMetric<uint16_t> currentHeartRateBpm{};

  uint8_t sourceFlags = 0;
  OptionalMetric<uint16_t> averageHeartRateBpm{};
  OptionalMetric<uint16_t> activeEnergyTenthsKilocalorie{};
  OptionalMetric<uint16_t> cyclingPowerWatts{};
  OptionalMetric<uint16_t> cyclingCadenceTenthsRpm{};
  OptionalMetric<uint8_t> currentHeartRateZone{};
  OptionalMetric<int16_t> altitudeMeters{};
  OptionalMetric<uint8_t> heartRateZoneCount{};
  OptionalMetric<uint32_t> wallElapsedSeconds{};
  std::array<uint8_t, workout_telemetry_protocol::SESSION_ID_SIZE> sessionID{};
  uint16_t detectorProfileVersion = 0;
  workout_telemetry_protocol::PauseOrigin pauseOrigin =
      workout_telemetry_protocol::PauseOrigin::None;
  workout_telemetry_protocol::PauseOrigin lastTransitionOrigin =
      workout_telemetry_protocol::PauseOrigin::None;
  uint32_t lastOriginReceivedAtMs = 0;
};

template <typename T>
inline bool operator==(const OptionalMetric<T> &lhs,
                       const OptionalMetric<T> &rhs) {
  return lhs.available == rhs.available && lhs.value == rhs.value;
}

inline bool operator==(const State &lhs, const State &rhs) {
  return lhs.sessionState == rhs.sessionState &&
         lhs.sessionToken == rhs.sessionToken &&
         lhs.lastCoreReceivedAtMs == rhs.lastCoreReceivedAtMs &&
         lhs.lastExtendedReceivedAtMs == rhs.lastExtendedReceivedAtMs &&
         lhs.pendingUnavailableCoreReceivedAtMs ==
             rhs.pendingUnavailableCoreReceivedAtMs &&
         lhs.coreReceived == rhs.coreReceived &&
         lhs.extendedReceived == rhs.extendedReceived &&
         lhs.transportUnavailable == rhs.transportUnavailable &&
         lhs.pendingUnavailableCore == rhs.pendingUnavailableCore &&
         lhs.originReceived == rhs.originReceived &&
         lhs.elapsedSeconds == rhs.elapsedSeconds &&
         lhs.distanceMeters == rhs.distanceMeters &&
         lhs.speedCentimetersPerSecond == rhs.speedCentimetersPerSecond &&
         lhs.maximumSpeedCentimetersPerSecond ==
             rhs.maximumSpeedCentimetersPerSecond &&
         lhs.currentHeartRateBpm == rhs.currentHeartRateBpm &&
         lhs.sourceFlags == rhs.sourceFlags &&
         lhs.averageHeartRateBpm == rhs.averageHeartRateBpm &&
         lhs.activeEnergyTenthsKilocalorie ==
             rhs.activeEnergyTenthsKilocalorie &&
         lhs.cyclingPowerWatts == rhs.cyclingPowerWatts &&
         lhs.cyclingCadenceTenthsRpm == rhs.cyclingCadenceTenthsRpm &&
         lhs.currentHeartRateZone == rhs.currentHeartRateZone &&
         lhs.altitudeMeters == rhs.altitudeMeters &&
         lhs.heartRateZoneCount == rhs.heartRateZoneCount &&
         lhs.wallElapsedSeconds == rhs.wallElapsedSeconds &&
         lhs.sessionID == rhs.sessionID &&
         lhs.detectorProfileVersion == rhs.detectorProfileVersion &&
         lhs.pauseOrigin == rhs.pauseOrigin &&
         lhs.lastTransitionOrigin == rhs.lastTransitionOrigin &&
         lhs.lastOriginReceivedAtMs == rhs.lastOriginReceivedAtMs;
}

inline bool operator!=(const State &lhs, const State &rhs) {
  return !(lhs == rhs);
}

struct Snapshot {
  State state{};
  bool stale = false;
};

enum class ApplyResult : uint8_t {
  Applied,
  Cleared,
  RejectedUnauthenticated,
  RejectedLength,
  RejectedKind,
  RejectedState,
  RejectedToken,
  RejectedFlags,
  RejectedMetric,
  IgnoredToken,
  IgnoredPair,
  IgnoredStateRegression,
};

constexpr uint32_t STALE_AFTER_MS = 10000;

inline bool isEstablishingState(
    workout_telemetry_protocol::SessionState state) {
  using SessionState = workout_telemetry_protocol::SessionState;
  return state == SessionState::Starting || state == SessionState::Running ||
         state == SessionState::Paused;
}

inline bool isLiveSessionState(
    workout_telemetry_protocol::SessionState state) {
  using SessionState = workout_telemetry_protocol::SessionState;
  return state == SessionState::Starting || state == SessionState::Running ||
         state == SessionState::Paused || state == SessionState::Ending;
}

inline bool isActiveWorkout(const State &state) {
  return state.coreReceived && isLiveSessionState(state.sessionState);
}

inline bool isValidSessionState(uint8_t raw) {
  return raw <= static_cast<uint8_t>(
                    workout_telemetry_protocol::SessionState::Failed);
}

inline bool isFinishedSessionState(
    workout_telemetry_protocol::SessionState state) {
  using SessionState = workout_telemetry_protocol::SessionState;
  return state == SessionState::Ended || state == SessionState::Failed;
}

inline bool isRetainedCollisionBoundaryState(
    workout_telemetry_protocol::SessionState state) {
  using SessionState = workout_telemetry_protocol::SessionState;
  return state == SessionState::Ending || state == SessionState::Ended ||
         state == SessionState::Failed;
}

inline bool canTransitionSameToken(
    workout_telemetry_protocol::SessionState current,
    workout_telemetry_protocol::SessionState incoming) {
  using SessionState = workout_telemetry_protocol::SessionState;
  switch (current) {
  case SessionState::Idle:
    return true;
  case SessionState::Starting:
    return incoming != SessionState::Idle;
  case SessionState::Running:
    return incoming == SessionState::Running ||
           incoming == SessionState::Paused ||
           incoming == SessionState::Ending ||
           incoming == SessionState::Ended ||
           incoming == SessionState::Failed;
  case SessionState::Paused:
    return incoming == SessionState::Paused ||
           incoming == SessionState::Running ||
           incoming == SessionState::Ending ||
           incoming == SessionState::Ended ||
           incoming == SessionState::Failed;
  case SessionState::Ending:
    return incoming == SessionState::Ending ||
           incoming == SessionState::Ended ||
           incoming == SessionState::Failed;
  case SessionState::Ended:
    return incoming == SessionState::Ended;
  case SessionState::Failed:
    return incoming == SessionState::Failed;
  }
  return false;
}

inline void clearCoreMetrics(State &state) {
  state.elapsedSeconds = {};
  state.distanceMeters = {};
  state.speedCentimetersPerSecond = {};
  state.currentHeartRateBpm = {};
}

template <typename T>
inline OptionalMetric<T> decodeUnsignedMetric(T value, T unavailable) {
  if (value == unavailable) {
    return {};
  }
  return {true, value};
}

inline OptionalMetric<int16_t> decodeAltitude(int16_t value) {
  if (value == workout_telemetry_protocol::UNAVAILABLE_ALTITUDE) {
    return {};
  }
  return {true, value};
}

inline bool isStale(const State &state, uint32_t nowMs,
                    uint32_t staleAfterMs = STALE_AFTER_MS) {
  if (!state.coreReceived || !isLiveSessionState(state.sessionState)) {
    return false;
  }
  if (state.transportUnavailable) {
    return true;
  }
  return static_cast<uint32_t>(nowMs - state.lastCoreReceivedAtMs) >=
         staleAfterMs;
}

inline Snapshot makeSnapshot(const State &state, uint32_t nowMs,
                             uint32_t staleAfterMs = STALE_AFTER_MS) {
  return {state, isStale(state, nowMs, staleAfterMs)};
}

class Reducer {
public:
  Reducer() = default;
  explicit Reducer(const State &initialState) : state_(initialState) {}

  const State &state() const { return state_; }

  void reset() {
    state_ = State{};
    transactionalState_ = State{};
    transactionalCorePending_ = false;
    transactionalGeneration_ = 0;
    legacyCoreAwaitingExtended_ = false;
    legacyCoreToken_ = 0;
  }

  ApplyResult applyFrame(const uint8_t *bytes, std::size_t length,
                         uint32_t receivedAtMs, bool authenticated) {
    if (!authenticated) {
      return ApplyResult::RejectedUnauthenticated;
    }
    if (bytes == nullptr ||
        (length != workout_telemetry_protocol::FRAME_SIZE &&
         length != workout_telemetry_protocol::ORIGIN_FRAME_SIZE)) {
      return ApplyResult::RejectedLength;
    }

    switch (bytes[0]) {
    case static_cast<uint8_t>(workout_telemetry_protocol::FrameKind::Core):
      if (length != workout_telemetry_protocol::FRAME_SIZE)
        return ApplyResult::RejectedLength;
      return applyCore(bytes, receivedAtMs);
    case static_cast<uint8_t>(workout_telemetry_protocol::FrameKind::Extended):
      if (length != workout_telemetry_protocol::FRAME_SIZE)
        return ApplyResult::RejectedLength;
      return applyExtended(bytes, receivedAtMs);
    case static_cast<uint8_t>(workout_telemetry_protocol::FrameKind::Origin):
      if (length != workout_telemetry_protocol::ORIGIN_FRAME_SIZE)
        return ApplyResult::RejectedLength;
      return applyOrigin(bytes, receivedAtMs);
    default:
      return ApplyResult::RejectedKind;
    }
  }

private:
  ApplyResult applyCore(const uint8_t *bytes, uint32_t receivedAtMs) {
    using namespace workout_telemetry_protocol;

    const uint8_t generation = pairGenerationValue(bytes[1]);
    const uint8_t rawState = bytes[1] & SESSION_STATE_MASK;
    if (!isValidSessionState(rawState)) {
      return ApplyResult::RejectedState;
    }
    const auto incomingState = static_cast<SessionState>(rawState);
    const uint16_t token = readUInt16LE(bytes, 2);
    const uint32_t elapsed = readUInt32LE(bytes, 4);
    const uint32_t distance = readUInt32LE(bytes, 8);
    const uint16_t speed = readUInt16LE(bytes, 12);
    const uint16_t currentHeartRate = readUInt16LE(bytes, 14);

    if (incomingState == SessionState::Idle) {
      if (generation != 0 || token != 0 || elapsed != UNAVAILABLE_UINT32 ||
          distance != UNAVAILABLE_UINT32 || speed != UNAVAILABLE_UINT16 ||
          currentHeartRate != UNAVAILABLE_UINT16) {
        return ApplyResult::RejectedToken;
      }
      reset();
      return ApplyResult::Cleared;
    }

    if (token == 0) {
      return ApplyResult::RejectedToken;
    }
    if (currentHeartRate == 0) {
      return ApplyResult::RejectedMetric;
    }

    const bool hasExistingCore = state_.coreReceived;
    const bool establishesNewToken =
        hasExistingCore && state_.sessionToken != token;
    if (generation == 0 && establishesNewToken &&
        !isEstablishingState(incomingState)) {
      return ApplyResult::IgnoredToken;
    }
    // Starting is an explicit replacement boundary after a finished session.
    // This keeps a valid newer workout reachable even if its random 16-bit
    // token collides with the retained final snapshot.
    const bool startsCollidingSession =
        hasExistingCore && !establishesNewToken &&
        incomingState == SessionState::Starting &&
        isFinishedSessionState(state_.sessionState);
    if (hasExistingCore && !establishesNewToken && !startsCollidingSession &&
        !canTransitionSameToken(state_.sessionState, incomingState)) {
      return ApplyResult::IgnoredStateRegression;
    }

    const bool allNumericsUnavailable =
        elapsed == UNAVAILABLE_UINT32 && distance == UNAVAILABLE_UINT32 &&
        speed == UNAVAILABLE_UINT16 &&
        currentHeartRate == UNAVAILABLE_UINT16;
    State next =
        !hasExistingCore || establishesNewToken || startsCollidingSession
            ? State{}
            : state_;
    if (hasExistingCore && !establishesNewToken && !startsCollidingSession &&
        incomingState != state_.sessionState) {
      // Origin/timing is a separate, capability-gated frame. Never carry the
      // preceding boundary's pause provenance across a state transition: if
      // the matching origin frame is lost, unknown must fail conservatively
      // as manual rather than allowing an automatic resume.
      next.originReceived = false;
      next.wallElapsedSeconds = {};
      next.sessionID = {};
      next.detectorProfileVersion = 0;
      next.pauseOrigin = PauseOrigin::None;
      next.lastTransitionOrigin = PauseOrigin::None;
      next.lastOriginReceivedAtMs = 0;
    }
    next.sessionState = incomingState;
    next.sessionToken = token;
    next.coreReceived = true;
    if (isLiveSessionState(incomingState) && allNumericsUnavailable) {
      // Do not refresh visible freshness until the matching extended frame
      // proves whether this is current-unavailable or transport loss.
      next.pendingUnavailableCore = true;
      next.pendingUnavailableCoreReceivedAtMs = receivedAtMs;
    } else {
      next.pendingUnavailableCore = false;
      next.pendingUnavailableCoreReceivedAtMs = 0;
      next.transportUnavailable = false;
      next.lastCoreReceivedAtMs = receivedAtMs;
      next.elapsedSeconds = decodeUnsignedMetric(elapsed, UNAVAILABLE_UINT32);
      next.distanceMeters = decodeUnsignedMetric(distance, UNAVAILABLE_UINT32);
      next.speedCentimetersPerSecond =
          decodeUnsignedMetric(speed, UNAVAILABLE_UINT16);
      if (speed != UNAVAILABLE_UINT16 &&
          (!next.maximumSpeedCentimetersPerSecond.available ||
           speed > next.maximumSpeedCentimetersPerSecond.value)) {
        next.maximumSpeedCentimetersPerSecond = {true, speed};
      }
      next.currentHeartRateBpm =
          decodeUnsignedMetric(currentHeartRate, UNAVAILABLE_UINT16);
    }

    if (generation != 0) {
      transactionalState_ = next;
      transactionalCorePending_ = true;
      transactionalGeneration_ = generation;
      legacyCoreAwaitingExtended_ = false;
      legacyCoreToken_ = 0;
      return ApplyResult::Applied;
    }

    state_ = next;
    transactionalState_ = State{};
    transactionalCorePending_ = false;
    transactionalGeneration_ = 0;
    legacyCoreAwaitingExtended_ = true;
    legacyCoreToken_ = token;
    return ApplyResult::Applied;
  }

  ApplyResult applyExtended(const uint8_t *bytes, uint32_t receivedAtMs) {
    using namespace workout_telemetry_protocol;

    const uint8_t flags = bytes[1];
    const uint8_t generation = pairGenerationValue(flags);
    const bool upstreamCurrent = (flags & SOURCE_CURRENT_SNAPSHOT) != 0;
    const uint8_t metricFlags = flags & METRIC_SOURCE_FLAGS_MASK;

    const uint16_t token = readUInt16LE(bytes, 2);
    if (token == 0) {
      return ApplyResult::RejectedToken;
    }
    if (generation != 0 &&
        (!transactionalCorePending_ ||
         transactionalGeneration_ != generation)) {
      return ApplyResult::IgnoredPair;
    }
    State next = generation == 0 ? state_ : transactionalState_;
    if (!next.coreReceived || next.sessionToken != token) {
      return ApplyResult::IgnoredToken;
    }

    const uint16_t averageHeartRate = readUInt16LE(bytes, 4);
    const uint16_t energy = readUInt16LE(bytes, 6);
    const uint16_t power = readUInt16LE(bytes, 8);
    const uint16_t cadence = readUInt16LE(bytes, 10);
    const uint8_t currentZone = bytes[12];
    const int16_t altitude = readInt16LE(bytes, 13);
    const uint8_t zoneCount = bytes[15];

    if (averageHeartRate == 0) {
      return ApplyResult::RejectedMetric;
    }
    const bool zoneUnavailable = currentZone == 0 && zoneCount == 0;
    const bool zoneValid = currentZone > 0 && zoneCount > 0 &&
                           currentZone <= zoneCount;
    if (!zoneUnavailable && !zoneValid) {
      return ApplyResult::RejectedMetric;
    }

    const bool allNumericsUnavailable =
        metricFlags == 0 && averageHeartRate == UNAVAILABLE_UINT16 &&
        energy == UNAVAILABLE_UINT16 && power == UNAVAILABLE_UINT16 &&
        cadence == UNAVAILABLE_UINT16 && zoneUnavailable &&
        altitude == UNAVAILABLE_ALTITUDE;

    if (((metricFlags &
          (SOURCE_PAIRED_SPEED_SENSOR | SOURCE_WATCH_GPS_SPEED)) != 0 &&
         !next.speedCentimetersPerSecond.available) ||
        ((metricFlags & SOURCE_HEALTHKIT_DISTANCE) != 0 &&
         !next.distanceMeters.available) ||
        ((metricFlags & SOURCE_WATCH_ALTITUDE) != 0 &&
         altitude == UNAVAILABLE_ALTITUDE) ||
        ((metricFlags & SOURCE_LIVE_HEART_RATE_ZONE) != 0 && !zoneValid)) {
      return ApplyResult::RejectedFlags;
    }

    if (generation == 0 && upstreamCurrent &&
        (!legacyCoreAwaitingExtended_ || legacyCoreToken_ != token)) {
      return ApplyResult::IgnoredPair;
    }

    const bool legacyHasMatchingCore =
        legacyCoreAwaitingExtended_ && legacyCoreToken_ == token;
    if (isLiveSessionState(next.sessionState) && !upstreamCurrent) {
      if (allNumericsUnavailable && next.pendingUnavailableCore) {
        if (generation != 0) {
          next.lastExtendedReceivedAtMs = receivedAtMs;
          next.extendedReceived = true;
          next.pendingUnavailableCore = false;
          next.pendingUnavailableCoreReceivedAtMs = 0;
          next.transportUnavailable = true;
          commitExtendedState(next, generation);
          return ApplyResult::Applied;
        }

        // The predecessor relay encoded current-all-unavailable and stale as
        // the same generation-zero pair. Treat the pair conservatively as a
        // current unavailable snapshot for one freshness window: clear values
        // instead of showing retained speed as live, and require a later
        // populated core/extended update to refresh core freshness.
        clearCoreMetrics(next);
        next.lastCoreReceivedAtMs =
            next.pendingUnavailableCoreReceivedAtMs;
      } else if (generation != 0) {
        return ApplyResult::RejectedFlags;
      } else if (allNumericsUnavailable && !legacyHasMatchingCore &&
                 next.transportUnavailable) {
        // An empty predecessor heartbeat cannot recover a confirmed loss.
        // Preserve the coherent retained snapshot until a populated/current
        // core or extended frame proves recovery.
        next.lastExtendedReceivedAtMs = receivedAtMs;
        next.extendedReceived = true;
        commitExtendedState(next, generation);
        return ApplyResult::Applied;
      } else if (!allNumericsUnavailable || legacyHasMatchingCore) {
        // Populated legacy extended data proves that the predecessor relay is
        // current. A matching populated core may also carry a valid basic
        // sensor snapshot even when every extended-only metric is unavailable.
        if (next.pendingUnavailableCore || next.transportUnavailable ||
            isStale(next, receivedAtMs)) {
          clearCoreMetrics(next);
        }
        next.lastCoreReceivedAtMs = next.pendingUnavailableCore
                                        ? next.pendingUnavailableCoreReceivedAtMs
                                        : receivedAtMs;
      }
    }

    if (upstreamCurrent && next.pendingUnavailableCore) {
      clearCoreMetrics(next);
      next.lastCoreReceivedAtMs =
          next.pendingUnavailableCoreReceivedAtMs;
    }
    next.pendingUnavailableCore = false;
    next.pendingUnavailableCoreReceivedAtMs = 0;
    next.transportUnavailable = false;
    next.sourceFlags = metricFlags;
    next.averageHeartRateBpm =
        decodeUnsignedMetric(averageHeartRate, UNAVAILABLE_UINT16);
    next.activeEnergyTenthsKilocalorie =
        decodeUnsignedMetric(energy, UNAVAILABLE_UINT16);
    next.cyclingPowerWatts =
        decodeUnsignedMetric(power, UNAVAILABLE_UINT16);
    next.cyclingCadenceTenthsRpm =
        decodeUnsignedMetric(cadence, UNAVAILABLE_UINT16);
    next.currentHeartRateZone =
        zoneValid ? OptionalMetric<uint8_t>{true, currentZone}
                  : OptionalMetric<uint8_t>{};
    next.heartRateZoneCount =
        zoneValid ? OptionalMetric<uint8_t>{true, zoneCount}
                  : OptionalMetric<uint8_t>{};
    next.altitudeMeters = decodeAltitude(altitude);
    next.lastExtendedReceivedAtMs = receivedAtMs;
    next.extendedReceived = true;
    commitExtendedState(next, generation);
    return ApplyResult::Applied;
  }

  ApplyResult applyOrigin(const uint8_t *bytes, uint32_t receivedAtMs) {
    using namespace workout_telemetry_protocol;
    const uint8_t rawPauseOrigin = bytes[1];
    const uint16_t token = readUInt16LE(bytes, 2);
    const uint32_t wallElapsed = readUInt32LE(bytes, 4);
    std::array<uint8_t, SESSION_ID_SIZE> sessionID{};
    for (std::size_t index = 0; index < SESSION_ID_SIZE; ++index)
      sessionID[index] = bytes[8 + index];
    const uint16_t profileVersion = readUInt16LE(bytes, 24);
    const uint8_t rawLastOrigin = bytes[26];
    const uint8_t flags = bytes[27];
    if (token == 0)
      return ApplyResult::RejectedToken;
    if (!state_.coreReceived || state_.sessionToken != token)
      return ApplyResult::IgnoredToken;
    if (rawPauseOrigin > static_cast<uint8_t>(PauseOrigin::Unknown) ||
        rawLastOrigin > static_cast<uint8_t>(PauseOrigin::Unknown) ||
        flags != 0 || !hasSessionID(sessionID))
      return ApplyResult::RejectedMetric;
    const bool paused = state_.sessionState == SessionState::Paused;
    if (!paused && rawPauseOrigin != 0)
      return ApplyResult::RejectedState;
    const bool claimsAutomaticOrigin =
        rawPauseOrigin == static_cast<uint8_t>(PauseOrigin::Automatic) ||
        rawLastOrigin == static_cast<uint8_t>(PauseOrigin::Automatic);
    if (claimsAutomaticOrigin && profileVersion == 0)
      return ApplyResult::RejectedMetric;
    if (wallElapsed != UNAVAILABLE_UINT32 && state_.elapsedSeconds.available &&
        wallElapsed < state_.elapsedSeconds.value)
      return ApplyResult::RejectedMetric;

    state_.originReceived = true;
    state_.lastOriginReceivedAtMs = receivedAtMs;
    state_.wallElapsedSeconds = wallElapsed == UNAVAILABLE_UINT32
                                    ? OptionalMetric<uint32_t>{}
                                    : OptionalMetric<uint32_t>{true,
                                                               wallElapsed};
    state_.sessionID = sessionID;
    state_.detectorProfileVersion = profileVersion;
    state_.pauseOrigin = static_cast<PauseOrigin>(rawPauseOrigin);
    state_.lastTransitionOrigin =
        static_cast<PauseOrigin>(rawLastOrigin);
    return ApplyResult::Applied;
  }

  void commitExtendedState(const State &next, uint8_t generation) {
    state_ = next;
    if (generation != 0) {
      transactionalState_ = State{};
      transactionalCorePending_ = false;
      transactionalGeneration_ = 0;
    } else {
      legacyCoreAwaitingExtended_ = false;
      legacyCoreToken_ = 0;
    }
  }

  State state_{};
  State transactionalState_{};
  bool transactionalCorePending_ = false;
  uint8_t transactionalGeneration_ = 0;
  bool legacyCoreAwaitingExtended_ = false;
  uint16_t legacyCoreToken_ = 0;
};

// Retains the currently displayed snapshot across authentication until the
// iPhone supplies a complete, valid replacement pair. This prevents an auth
// handshake without telemetry (or a disconnect between the two frames) from
// erasing the last live/final snapshot, while still allowing a newer terminal
// token to replace an older one after reconnect.
class AuthenticatedResynchronizer {
public:
  const State &state() const { return active_.state(); }

  bool resynchronizationPending() const { return resynchronizationPending_; }

  void beginResynchronization() {
    staged_.reset();
    stagedCoreAccepted_ = false;
    stagedRequiresCurrentCollisionReplacement_ = false;
    resynchronizationPending_ = true;
  }

  void reset() {
    active_.reset();
    staged_.reset();
    stagedCoreAccepted_ = false;
    stagedRequiresCurrentCollisionReplacement_ = false;
    resynchronizationPending_ = false;
  }

  ApplyResult applyFrame(const uint8_t *bytes, std::size_t length,
                         uint32_t receivedAtMs, bool authenticated) {
    if (!resynchronizationPending_) {
      return active_.applyFrame(bytes, length, receivedAtMs, authenticated);
    }

    if (authenticated && bytes != nullptr &&
        length == workout_telemetry_protocol::FRAME_SIZE &&
        bytes[0] == static_cast<uint8_t>(
                        workout_telemetry_protocol::FrameKind::Core)) {
      const uint16_t token = workout_telemetry_protocol::readUInt16LE(bytes, 2);
      const uint8_t rawState =
          bytes[1] & workout_telemetry_protocol::SESSION_STATE_MASK;
      const uint8_t generation =
          workout_telemetry_protocol::pairGenerationValue(bytes[1]);
      const bool replacesFinishedCollision =
          isValidSessionState(rawState) && generation != 0 &&
          active_.state().coreReceived &&
          active_.state().sessionToken == token &&
          isRetainedCollisionBoundaryState(active_.state().sessionState) &&
          !canTransitionSameToken(
              active_.state().sessionState,
              static_cast<workout_telemetry_protocol::SessionState>(
                  rawState));
      Reducer candidate =
          !replacesFinishedCollision && active_.state().coreReceived &&
                  active_.state().sessionToken == token
              ? Reducer(active_.state())
              : Reducer();
      const ApplyResult result =
          candidate.applyFrame(bytes, length, receivedAtMs, authenticated);
      if (result == ApplyResult::Cleared) {
        active_ = candidate;
        staged_.reset();
        stagedCoreAccepted_ = false;
        stagedRequiresCurrentCollisionReplacement_ = false;
        resynchronizationPending_ = false;
      } else if (result == ApplyResult::Applied) {
        staged_ = candidate;
        stagedCoreAccepted_ = true;
        stagedRequiresCurrentCollisionReplacement_ =
            replacesFinishedCollision;
      }
      return result;
    }

    const ApplyResult result =
        staged_.applyFrame(bytes, length, receivedAtMs, authenticated);
    const bool acceptedIdle = result == ApplyResult::Cleared;
    const bool acceptedExtended =
        stagedCoreAccepted_ && result == ApplyResult::Applied &&
        bytes != nullptr &&
        length == workout_telemetry_protocol::FRAME_SIZE &&
        bytes[0] == static_cast<uint8_t>(
                        workout_telemetry_protocol::FrameKind::Extended);
    if (acceptedExtended && stagedRequiresCurrentCollisionReplacement_ &&
        (bytes[1] & workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT) ==
            0) {
      // A same-token pair that crosses an otherwise-invalid terminal
      // transition can identify a newer colliding workout only at an
      // authenticated resynchronization boundary and only when the complete
      // correlated pair says the snapshot is current. Otherwise a delayed
      // stale pair must not regress a retained final summary.
      staged_.reset();
      stagedCoreAccepted_ = false;
      stagedRequiresCurrentCollisionReplacement_ = false;
      return ApplyResult::IgnoredStateRegression;
    }
    if (acceptedIdle || acceptedExtended) {
      active_ = staged_;
      staged_.reset();
      stagedCoreAccepted_ = false;
      stagedRequiresCurrentCollisionReplacement_ = false;
      resynchronizationPending_ = false;
    }
    return result;
  }

private:
  Reducer active_{};
  Reducer staged_{};
  bool stagedCoreAccepted_ = false;
  bool stagedRequiresCurrentCollisionReplacement_ = false;
  bool resynchronizationPending_ = false;
};

inline const char *applyResultName(ApplyResult result) {
  switch (result) {
  case ApplyResult::Applied:
    return "applied";
  case ApplyResult::Cleared:
    return "cleared";
  case ApplyResult::RejectedUnauthenticated:
    return "unauthenticated";
  case ApplyResult::RejectedLength:
    return "invalid_length";
  case ApplyResult::RejectedKind:
    return "invalid_kind";
  case ApplyResult::RejectedState:
    return "invalid_state";
  case ApplyResult::RejectedToken:
    return "invalid_token";
  case ApplyResult::RejectedFlags:
    return "invalid_flags";
  case ApplyResult::RejectedMetric:
    return "invalid_metric";
  case ApplyResult::IgnoredToken:
    return "token_mismatch";
  case ApplyResult::IgnoredPair:
    return "pair_mismatch";
  case ApplyResult::IgnoredStateRegression:
    return "state_regression";
  }
  return "unknown";
}

} // namespace workout_telemetry
