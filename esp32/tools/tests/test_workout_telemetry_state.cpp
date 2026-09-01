#include "../../lib/ble_navigation/gps_position_protocol.hpp"
#include "../../lib/ble_navigation/workout_telemetry_state.hpp"
#include "../../lib/gui/src/rideTelemetryPresenter.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <limits>

namespace {

using workout_telemetry::ApplyResult;
using workout_telemetry::AuthenticatedResynchronizer;
using workout_telemetry::Reducer;
using workout_telemetry::State;
using workout_telemetry_protocol::SessionState;

struct TestRideData {
  uint8_t satellites = 0;
  uint8_t fixMode = 0;
  int16_t altitude = 0;
  uint16_t speed = 0;
  uint32_t distanceTraveled = 0;
  uint32_t elapsedSeconds = 0;
  uint32_t routeRemaining = 0;
  bool hasRouteRemaining = false;
  double latitude = 0;
  double longitude = 0;
  uint16_t heading = 0;
  bool headingValid = false;
};

void writeUInt16LE(uint8_t *bytes, std::size_t offset, uint16_t value) {
  bytes[offset] = static_cast<uint8_t>(value);
  bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
}

void writeUInt32LE(uint8_t *bytes, std::size_t offset, uint32_t value) {
  bytes[offset] = static_cast<uint8_t>(value);
  bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
  bytes[offset + 2] = static_cast<uint8_t>(value >> 16);
  bytes[offset + 3] = static_cast<uint8_t>(value >> 24);
}

void writeInt16LE(uint8_t *bytes, std::size_t offset, int16_t value) {
  writeUInt16LE(bytes, offset, static_cast<uint16_t>(value));
}

void assertText(const char *actual, const char *expected) {
  assert(std::strcmp(actual, expected) == 0);
}

void assertBottomMetrics(
    const ride_telemetry_presenter::ViewModel &model,
    ride_telemetry_presenter::BottomMetric expectedLeft,
    ride_telemetry_presenter::BottomMetric expectedRight) {
  const auto selection =
      ride_telemetry_presenter::selectBottomMetrics(model);
  assert(selection.left == expectedLeft);
  assert(selection.right == expectedRight);
}

void assertMetricUnavailableFormatting(
    const ride_telemetry_presenter::ViewModel &model) {
  char value[32];
  ride_telemetry_presenter::formatSpeed(model, value, sizeof(value));
  assertText(value, "--");
  ride_telemetry_presenter::formatInteger(model.currentHeartRateBpm, value,
                                          sizeof(value));
  assertText(value, "--");
  ride_telemetry_presenter::formatEnergy(model, value, sizeof(value));
  assertText(value, "--");
  ride_telemetry_presenter::formatCadence(model, value, sizeof(value));
  assertText(value, "--");
}

void assertResultPreservesState(Reducer &reducer, const uint8_t *bytes,
                                std::size_t length, uint32_t receivedAtMs,
                                bool authenticated, ApplyResult expected) {
  const State before = reducer.state();
  assert(reducer.applyFrame(bytes, length, receivedAtMs, authenticated) ==
         expected);
  assert(reducer.state() == before);
}

} // namespace

int main() {
  State activityState;
  const SessionState liveStates[] = {
      SessionState::Starting,
      SessionState::Running,
      SessionState::Paused,
      SessionState::Ending,
  };
  for (const SessionState state : liveStates) {
    activityState.sessionState = state;
    activityState.coreReceived = false;
    assert(!workout_telemetry::isActiveWorkout(activityState));
    activityState.coreReceived = true;
    assert(workout_telemetry::isActiveWorkout(activityState));
  }
  const SessionState inactiveStates[] = {
      SessionState::Idle,
      SessionState::Ended,
      SessionState::Failed,
  };
  for (const SessionState state : inactiveStates) {
    activityState.sessionState = state;
    activityState.coreReceived = true;
    assert(!workout_telemetry::isActiveWorkout(activityState));
  }

  const uint8_t core[workout_telemetry_protocol::FRAME_SIZE] = {
      0x01, 0x02, 0x34, 0x12, 0x4D, 0x0E, 0x00, 0x00,
      0x39, 0x30, 0x00, 0x00, 0xD2, 0x04, 0x9D, 0x00,
  };
  const uint8_t extended[workout_telemetry_protocol::FRAME_SIZE] = {
      0x02, 0x3F, 0x34, 0x12, 0x94, 0x00, 0xD7, 0x11,
      0x41, 0x01, 0x6C, 0x03, 0x04, 0xF4, 0xFF, 0x05,
  };
  const uint8_t origin[workout_telemetry_protocol::ORIGIN_FRAME_SIZE] = {
      0x03, 0x00, 0x34, 0x12, 0xA0, 0x0F, 0x00, 0x00,
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
      0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
      0x01, 0x00, 0x02, 0x00,
  };

  Reducer reducer;
  assertResultPreservesState(reducer, extended, sizeof(extended), 100, true,
                             ApplyResult::IgnoredToken);
  assert(reducer.applyFrame(core, sizeof(core), 200, true) ==
         ApplyResult::Applied);
  assert(reducer.state().coreReceived);
  assert(reducer.state().sessionState == SessionState::Running);
  assert(reducer.state().sessionToken == 0x1234);
  assert(reducer.state().elapsedSeconds.available);
  assert(reducer.state().elapsedSeconds.value == 3661);
  assert(reducer.state().distanceMeters.value == 12345);
  assert(reducer.state().speedCentimetersPerSecond.value == 1234);
  assert(reducer.state().maximumSpeedCentimetersPerSecond.available);
  assert(reducer.state().maximumSpeedCentimetersPerSecond.value == 1234);
  assert(reducer.state().currentHeartRateBpm.value == 157);
  assert(reducer.applyFrame(extended, sizeof(extended), 300, true) ==
         ApplyResult::Applied);
  assert(reducer.state().extendedReceived);
  assert(reducer.state().sourceFlags == 0x1F);
  assert(reducer.state().averageHeartRateBpm.value == 148);
  assert(reducer.state().activeEnergyTenthsKilocalorie.value == 4567);
  assert(reducer.state().cyclingPowerWatts.value == 321);
  assert(reducer.state().cyclingCadenceTenthsRpm.value == 876);
  assert(reducer.state().currentHeartRateZone.value == 4);
  assert(reducer.state().heartRateZoneCount.value == 5);
  assert(reducer.state().altitudeMeters.value == -12);
  uint8_t unavailableWallOrigin[sizeof(origin)];
  std::memcpy(unavailableWallOrigin, origin, sizeof(origin));
  unavailableWallOrigin[4] = unavailableWallOrigin[5] =
      unavailableWallOrigin[6] = unavailableWallOrigin[7] = 0xFF;
  assert(reducer.applyFrame(unavailableWallOrigin,
                            sizeof(unavailableWallOrigin), 349, true) ==
         ApplyResult::Applied);
  assert(reducer.state().originReceived);
  assert(!reducer.state().wallElapsedSeconds.available);
  assert(reducer.applyFrame(origin, sizeof(origin), 350, true) ==
         ApplyResult::Applied);
  assert(reducer.state().originReceived);
  assert(reducer.state().wallElapsedSeconds.value == 4000);
  assert(reducer.state().sessionID ==
         (std::array<uint8_t, workout_telemetry_protocol::SESSION_ID_SIZE>{
             0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
             0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF}));
  assert(reducer.state().lastTransitionOrigin ==
         workout_telemetry_protocol::PauseOrigin::Automatic);

  uint8_t longFrame[17]{};
  uint8_t malformed[sizeof(core)];
  assertResultPreservesState(reducer, core, sizeof(core), 310, false,
                             ApplyResult::RejectedUnauthenticated);
  assertResultPreservesState(reducer, core, sizeof(core) - 1, 310, true,
                             ApplyResult::RejectedLength);
  assertResultPreservesState(reducer, longFrame, sizeof(longFrame), 310, true,
                             ApplyResult::RejectedLength);
  assertResultPreservesState(reducer, nullptr, sizeof(core), 310, true,
                             ApplyResult::RejectedLength);

  std::memcpy(malformed, core, sizeof(core));
  malformed[0] = 4;
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedKind);
  std::memcpy(malformed, core, sizeof(core));
  malformed[1] = 7;
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedState);
  std::memcpy(malformed, core, sizeof(core));
  writeUInt16LE(malformed, 2, 0);
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedToken);
  std::memcpy(malformed, core, sizeof(core));
  writeUInt16LE(malformed, 14, 0);
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedMetric);

  uint8_t invalidIdle[sizeof(core)]{};
  invalidIdle[0] = 1;
  assertResultPreservesState(reducer, invalidIdle, sizeof(invalidIdle), 310,
                             true, ApplyResult::RejectedToken);

  uint8_t mismatchedExtended[sizeof(extended)];
  std::memcpy(mismatchedExtended, extended, sizeof(extended));
  writeUInt16LE(mismatchedExtended, 2, 0x9999);
  assertResultPreservesState(reducer, mismatchedExtended,
                             sizeof(mismatchedExtended), 310, true,
                             ApplyResult::IgnoredToken);

  std::memcpy(malformed, extended, sizeof(extended));
  writeUInt16LE(malformed, 2, 0);
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedToken);
  std::memcpy(malformed, extended, sizeof(extended));
  malformed[1] |= 0x40;
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::IgnoredPair);
  uint8_t legacyExtended[sizeof(extended)];
  std::memcpy(legacyExtended, extended, sizeof(legacyExtended));
  legacyExtended[1] &= static_cast<uint8_t>(
      ~workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT);
  Reducer legacyRelayReducer;
  assert(legacyRelayReducer.applyFrame(core, sizeof(core), 100, true) ==
         ApplyResult::Applied);
  assert(legacyRelayReducer.applyFrame(legacyExtended, sizeof(legacyExtended),
                                       5000, true) == ApplyResult::Applied);
  assert(legacyRelayReducer.state().sourceFlags == 0x1F);
  assert(legacyRelayReducer.state().averageHeartRateBpm.value == 148);
  assert(legacyRelayReducer.state().lastCoreReceivedAtMs == 5000);
  assert(!workout_telemetry::isStale(legacyRelayReducer.state(), 14999));
  assert(workout_telemetry::isStale(legacyRelayReducer.state(), 15000));
  uint8_t legacyEmptyExtended[sizeof(extended)]{};
  legacyEmptyExtended[0] = 2;
  writeUInt16LE(legacyEmptyExtended, 2, 0x1234);
  writeUInt16LE(legacyEmptyExtended, 4, UINT16_MAX);
  writeUInt16LE(legacyEmptyExtended, 6, UINT16_MAX);
  writeUInt16LE(legacyEmptyExtended, 8, UINT16_MAX);
  writeUInt16LE(legacyEmptyExtended, 10, UINT16_MAX);
  writeInt16LE(legacyEmptyExtended, 13, INT16_MIN);
  Reducer legacyBasicSensorReducer;
  assert(legacyBasicSensorReducer.applyFrame(core, sizeof(core), 100, true) ==
         ApplyResult::Applied);
  assert(legacyBasicSensorReducer.applyFrame(
             legacyEmptyExtended, sizeof(legacyEmptyExtended), 5000, true) ==
         ApplyResult::Applied);
  assert(!legacyBasicSensorReducer.state().transportUnavailable);
  assert(legacyBasicSensorReducer.state().currentHeartRateBpm.value == 157);
  assert(legacyBasicSensorReducer.state().lastCoreReceivedAtMs == 5000);
  std::memcpy(malformed, extended, sizeof(extended));
  writeUInt16LE(malformed, 4, 0);
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedMetric);
  std::memcpy(malformed, extended, sizeof(extended));
  malformed[12] = 6;
  malformed[15] = 5;
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedMetric);
  std::memcpy(malformed, extended, sizeof(extended));
  writeInt16LE(malformed, 13,
               workout_telemetry_protocol::UNAVAILABLE_ALTITUDE);
  assertResultPreservesState(reducer, malformed, sizeof(malformed), 310, true,
                             ApplyResult::RejectedFlags);

  uint8_t pausedCore[sizeof(core)];
  std::memcpy(pausedCore, core, sizeof(core));
  pausedCore[1] = static_cast<uint8_t>(SessionState::Paused);
  assert(reducer.applyFrame(pausedCore, sizeof(pausedCore), 400, true) ==
         ApplyResult::Applied);
  assert(!reducer.state().originReceived);
  assert(reducer.state().pauseOrigin ==
         workout_telemetry_protocol::PauseOrigin::None);
  assert(reducer.applyFrame(pausedCore, sizeof(pausedCore), 5000, true) ==
         ApplyResult::Applied);
  assert(reducer.applyFrame(pausedCore, sizeof(pausedCore), 9000, true) ==
         ApplyResult::Applied);
  uint8_t pendingPausedOrigin[sizeof(origin)];
  std::memcpy(pendingPausedOrigin, origin, sizeof(origin));
  pendingPausedOrigin[1] = static_cast<uint8_t>(
      workout_telemetry_protocol::PauseOrigin::None);
  writeUInt16LE(pendingPausedOrigin, 24, 0);
  pendingPausedOrigin[26] = static_cast<uint8_t>(
      workout_telemetry_protocol::PauseOrigin::None);
  assert(reducer.applyFrame(pendingPausedOrigin,
                            sizeof(pendingPausedOrigin), 9001, true) ==
         ApplyResult::Applied);
  assert(reducer.state().originReceived);
  assert(reducer.state().pauseOrigin ==
         workout_telemetry_protocol::PauseOrigin::None);
  uint8_t pausedOrigin[sizeof(origin)];
  std::memcpy(pausedOrigin, origin, sizeof(origin));
  pausedOrigin[1] = static_cast<uint8_t>(
      workout_telemetry_protocol::PauseOrigin::Automatic);
  assert(reducer.applyFrame(pausedOrigin, sizeof(pausedOrigin), 9002, true) ==
         ApplyResult::Applied);
  assert(reducer.state().pauseOrigin ==
         workout_telemetry_protocol::PauseOrigin::Automatic);
  uint8_t systemUnknownOrigin[sizeof(origin)];
  std::memcpy(systemUnknownOrigin, origin, sizeof(origin));
  systemUnknownOrigin[1] = static_cast<uint8_t>(
      workout_telemetry_protocol::PauseOrigin::Unknown);
  systemUnknownOrigin[26] = static_cast<uint8_t>(
      workout_telemetry_protocol::PauseOrigin::System);
  writeUInt16LE(systemUnknownOrigin, 24, 0);
  assert(reducer.applyFrame(systemUnknownOrigin, sizeof(systemUnknownOrigin),
                            9003, true) == ApplyResult::Applied);
  assert(reducer.state().pauseOrigin ==
         workout_telemetry_protocol::PauseOrigin::Unknown);
  assert(reducer.state().lastTransitionOrigin ==
         workout_telemetry_protocol::PauseOrigin::System);
  uint8_t automaticWithoutProfile[sizeof(pausedOrigin)];
  std::memcpy(automaticWithoutProfile, pausedOrigin, sizeof(pausedOrigin));
  writeUInt16LE(automaticWithoutProfile, 24, 0);
  assertResultPreservesState(
      reducer, automaticWithoutProfile, sizeof(automaticWithoutProfile),
      9004, true, ApplyResult::RejectedMetric);
  assert(reducer.applyFrame(pausedOrigin, sizeof(pausedOrigin), 9005, true) ==
         ApplyResult::Applied);
  assert(!workout_telemetry::isStale(reducer.state(), 18999));

  const ride_telemetry_presenter::LegacyRideTelemetry legacy{
      27, 88, 8000, 3723, true, 1500};
  auto pausedModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(reducer.state(), 9001), legacy);
  assert(pausedModel.usesWorkout);
  assert(pausedModel.hasActiveNavigation);
  assertText(ride_telemetry_presenter::statusLabel(pausedModel),
             "AUTO-PAUSED");
  assert(ride_telemetry_presenter::shouldShowStatus(pausedModel));
  auto runningModel = pausedModel;
  runningModel.sessionState = SessionState::Running;
  assertText(ride_telemetry_presenter::statusLabel(runningModel), "LIVE");
  assert(!ride_telemetry_presenter::shouldShowStatus(runningModel));
  char formatted[32];
  ride_telemetry_presenter::formatSpeed(pausedModel, formatted,
                                        sizeof(formatted));
  assertText(formatted, "44.4");
  ride_telemetry_presenter::formatInteger(pausedModel.currentHeartRateBpm,
                                          formatted, sizeof(formatted));
  assertText(formatted, "157");
  ride_telemetry_presenter::formatElapsed(pausedModel.elapsedSeconds,
                                          formatted, sizeof(formatted));
  assertText(formatted, "1:01:01");
  assert(ride_telemetry_presenter::fiveZoneIndex(pausedModel) == 3);
  auto unavailableZoneModel = pausedModel;
  unavailableZoneModel.currentHeartRateZone.available = false;
  assert(ride_telemetry_presenter::fiveZoneIndex(unavailableZoneModel) == -1);
  auto nonFiveZoneModel = pausedModel;
  nonFiveZoneModel.heartRateZoneCount.value = 6;
  assert(ride_telemetry_presenter::fiveZoneIndex(nonFiveZoneModel) == -1);

  Reducer endedReducer;
  assert(endedReducer.applyFrame(core, sizeof(core), 1000, true) ==
         ApplyResult::Applied);
  uint8_t fasterCore[sizeof(core)];
  std::memcpy(fasterCore, core, sizeof(fasterCore));
  writeUInt16LE(fasterCore, 12, 2000);
  assert(endedReducer.applyFrame(fasterCore, sizeof(fasterCore), 1100, true) ==
         ApplyResult::Applied);
  assert(endedReducer.state().maximumSpeedCentimetersPerSecond.value == 2000);
  assert(endedReducer.applyFrame(extended, sizeof(extended), 1200, true) ==
         ApplyResult::Applied);
  uint8_t summaryEndedCore[sizeof(core)];
  std::memcpy(summaryEndedCore, fasterCore, sizeof(summaryEndedCore));
  summaryEndedCore[1] = static_cast<uint8_t>(SessionState::Ended);
  writeUInt16LE(summaryEndedCore, 12,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  assert(endedReducer.applyFrame(summaryEndedCore, sizeof(summaryEndedCore),
                                 1300, true) == ApplyResult::Applied);
  assert(endedReducer.state().sessionState == SessionState::Ended);
  assert(endedReducer.state().maximumSpeedCentimetersPerSecond.value == 2000);
  uint8_t summaryEndedExtended[sizeof(extended)];
  std::memcpy(summaryEndedExtended, extended, sizeof(summaryEndedExtended));
  summaryEndedExtended[1] &= static_cast<uint8_t>(~0x03);
  assert(endedReducer.applyFrame(summaryEndedExtended,
                                 sizeof(summaryEndedExtended), 1400, true) ==
         ApplyResult::Applied);
  const auto summaryEndedModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(endedReducer.state(), 1400),
      ride_telemetry_presenter::LegacyRideTelemetry{});
  assert(summaryEndedModel.sessionState == SessionState::Ended);
  ride_telemetry_presenter::formatAverageSpeed(summaryEndedModel, formatted,
                                                sizeof(formatted));
  assertText(formatted, "12.1");
  ride_telemetry_presenter::formatMaximumSpeed(summaryEndedModel, formatted,
                                                sizeof(formatted));
  assertText(formatted, "72.0");
  assertBottomMetrics(summaryEndedModel,
                      ride_telemetry_presenter::BottomMetric::MaximumSpeed,
                      ride_telemetry_presenter::BottomMetric::Energy);
  assertText(ride_telemetry_presenter::bottomMetricTitle(
                 ride_telemetry_presenter::BottomMetric::MaximumSpeed),
             "Max speed");
  assertText(ride_telemetry_presenter::bottomMetricTitle(
                 ride_telemetry_presenter::BottomMetric::Energy),
             "Calories");
  ride_telemetry_presenter::formatBottomMetric(
      ride_telemetry_presenter::BottomMetric::MaximumSpeed, summaryEndedModel,
      formatted, sizeof(formatted));
  assertText(formatted, "72.0");
  ride_telemetry_presenter::formatBottomMetric(
      ride_telemetry_presenter::BottomMetric::Energy, summaryEndedModel,
      formatted, sizeof(formatted));
  assertText(formatted, "456.7");

  using ride_telemetry_presenter::BottomMetric;
  assertBottomMetrics(pausedModel, BottomMetric::WallElapsed,
                      BottomMetric::Power);
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::WallElapsed, pausedModel, formatted, sizeof(formatted));
  assertText(formatted, "1:06:40");
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::Power, pausedModel, formatted, sizeof(formatted));
  assertText(formatted, "321");
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::Cadence, pausedModel, formatted, sizeof(formatted));
  assertText(formatted, "87.6");

  auto zeroSensorModel = pausedModel;
  zeroSensorModel.cyclingPowerWatts.value = 0;
  zeroSensorModel.cyclingCadenceTenthsRpm.value = 0;
  assertBottomMetrics(zeroSensorModel, BottomMetric::WallElapsed,
                      BottomMetric::Power);
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::Power, zeroSensorModel, formatted, sizeof(formatted));
  assertText(formatted, "0");
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::Cadence, zeroSensorModel, formatted, sizeof(formatted));
  assertText(formatted, "0.0");

  auto noSensorModel = pausedModel;
  noSensorModel.cyclingPowerWatts.available = false;
  noSensorModel.cyclingCadenceTenthsRpm.available = false;
  assertBottomMetrics(noSensorModel, BottomMetric::WallElapsed,
                      BottomMetric::RouteRemaining);
  assertText(ride_telemetry_presenter::bottomMetricTitle(
                 BottomMetric::Altitude),
             "Altitude m");
  assertText(ride_telemetry_presenter::bottomMetricTitle(
                 BottomMetric::RouteRemaining),
             "Route left");
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::Altitude, noSensorModel, formatted, sizeof(formatted));
  assertText(formatted, "-12");
  ride_telemetry_presenter::formatBottomMetric(
      BottomMetric::RouteRemaining, noSensorModel, formatted,
      sizeof(formatted));
  assertText(formatted, "1.5 km");

  auto powerOnlyModel = pausedModel;
  powerOnlyModel.cyclingCadenceTenthsRpm.available = false;
  assertBottomMetrics(powerOnlyModel, BottomMetric::WallElapsed,
                      BottomMetric::Power);

  auto cadenceOnlyModel = pausedModel;
  cadenceOnlyModel.cyclingPowerWatts.available = false;
  assertBottomMetrics(cadenceOnlyModel, BottomMetric::WallElapsed,
                      BottomMetric::Cadence);

  uint8_t unavailableCore[sizeof(core)]{};
  unavailableCore[0] = 1;
  unavailableCore[1] = static_cast<uint8_t>(SessionState::Paused);
  writeUInt16LE(unavailableCore, 2, 0x1234);
  writeUInt32LE(unavailableCore, 4,
                workout_telemetry_protocol::UNAVAILABLE_UINT32);
  writeUInt32LE(unavailableCore, 8,
                workout_telemetry_protocol::UNAVAILABLE_UINT32);
  writeUInt16LE(unavailableCore, 12,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  writeUInt16LE(unavailableCore, 14,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  assert(reducer.applyFrame(unavailableCore, sizeof(unavailableCore), 9500,
                            true) == ApplyResult::Applied);
  assert(reducer.state().pendingUnavailableCore);
  assert(!reducer.state().transportUnavailable);
  assert(reducer.state().lastCoreReceivedAtMs == 9000);
  assert(reducer.state().speedCentimetersPerSecond.value == 1234);
  assert(reducer.state().currentHeartRateBpm.value == 157);
  assert(!workout_telemetry::isStale(reducer.state(), 9500));
  assert(workout_telemetry::isStale(reducer.state(), 19000));

  uint8_t unavailableExtended[sizeof(extended)]{};
  unavailableExtended[0] = 2;
  writeUInt16LE(unavailableExtended, 2, 0x1234);
  writeUInt16LE(unavailableExtended, 4,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  writeUInt16LE(unavailableExtended, 6,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  writeUInt16LE(unavailableExtended, 8,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  writeUInt16LE(unavailableExtended, 10,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  writeInt16LE(unavailableExtended, 13,
               workout_telemetry_protocol::UNAVAILABLE_ALTITUDE);
  assert(reducer.applyFrame(unavailableExtended, sizeof(unavailableExtended),
                            9501, true) == ApplyResult::Applied);
  assert(!reducer.state().pendingUnavailableCore);
  assert(!reducer.state().transportUnavailable);
  assert(!reducer.state().currentHeartRateBpm.available);
  assert(!reducer.state().averageHeartRateBpm.available);
  assert(!reducer.state().activeEnergyTenthsKilocalorie.available);
  assert(!workout_telemetry::isStale(reducer.state(), 19499));
  assert(workout_telemetry::isStale(reducer.state(), 19500));
  const auto ambiguousLegacyModel =
      ride_telemetry_presenter::makeViewModel(
          workout_telemetry::makeSnapshot(reducer.state(), 9501), legacy);
  assert(!ambiguousLegacyModel.stale);
  assertText(ride_telemetry_presenter::statusLabel(ambiguousLegacyModel),
             "AUTO-PAUSED");
  ride_telemetry_presenter::formatSpeed(ambiguousLegacyModel, formatted,
                                        sizeof(formatted));
  assertText(formatted, "--");
  ride_telemetry_presenter::formatInteger(
      ambiguousLegacyModel.currentHeartRateBpm, formatted,
      sizeof(formatted));
  assertText(formatted, "--");
  assertText(
      ride_telemetry_presenter::sourceFreshnessLabel(ambiguousLegacyModel),
      "WATCH / LIVE");

  // The predecessor wire contract cannot distinguish current-all-unavailable
  // from stale. Its extended-only heartbeat must not refresh core freshness,
  // so the conservative grace window eventually becomes stale.
  assert(reducer.applyFrame(unavailableExtended, sizeof(unavailableExtended),
                            9502, true) == ApplyResult::Applied);
  assert(reducer.state().lastCoreReceivedAtMs == 9500);
  assert(workout_telemetry::isStale(reducer.state(), 19500));

  uint8_t recoveredUnavailableExtended[sizeof(unavailableExtended)];
  std::memcpy(recoveredUnavailableExtended, unavailableExtended,
              sizeof(recoveredUnavailableExtended));
  recoveredUnavailableExtended[1] =
      workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT;
  assert(reducer.applyFrame(unavailableCore, sizeof(unavailableCore), 9600,
                            true) == ApplyResult::Applied);
  assert(reducer.state().pendingUnavailableCore);
  assert(!reducer.state().transportUnavailable);
  assert(reducer.applyFrame(recoveredUnavailableExtended,
                            sizeof(recoveredUnavailableExtended), 9601,
                            true) == ApplyResult::Applied);
  assert(!reducer.state().pendingUnavailableCore);
  assert(!reducer.state().transportUnavailable);
  assert(!reducer.state().speedCentimetersPerSecond.available);
  assert(!reducer.state().currentHeartRateBpm.available);
  assert(!reducer.state().averageHeartRateBpm.available);
  assert(!reducer.state().activeEnergyTenthsKilocalorie.available);
  assert(!workout_telemetry::isStale(reducer.state(), 9601));
  const auto recoveredUnavailableModel =
      ride_telemetry_presenter::makeViewModel(
          workout_telemetry::makeSnapshot(reducer.state(), 9601), legacy);
  assertMetricUnavailableFormatting(recoveredUnavailableModel);
  assertText(
      ride_telemetry_presenter::sourceFreshnessLabel(recoveredUnavailableModel),
      "WATCH / LIVE");

  Reducer unavailableReducer;
  uint8_t initialUnavailableCore[sizeof(unavailableCore)];
  std::memcpy(initialUnavailableCore, unavailableCore,
              sizeof(initialUnavailableCore));
  initialUnavailableCore[1] = static_cast<uint8_t>(SessionState::Starting);
  writeUInt16LE(initialUnavailableCore, 2, 0x7777);
  assert(unavailableReducer.applyFrame(initialUnavailableCore,
                                       sizeof(initialUnavailableCore), 100,
                                       true) == ApplyResult::Applied);
  uint8_t initialUnavailableExtended[sizeof(unavailableExtended)];
  std::memcpy(initialUnavailableExtended, unavailableExtended,
              sizeof(initialUnavailableExtended));
  initialUnavailableExtended[1] =
      workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT;
  writeUInt16LE(initialUnavailableExtended, 2, 0x7777);
  assert(unavailableReducer.applyFrame(initialUnavailableExtended,
                                       sizeof(initialUnavailableExtended), 101,
                                       true) == ApplyResult::Applied);
  const auto unavailableModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(unavailableReducer.state(), 102), legacy);
  assert(!unavailableReducer.state().pendingUnavailableCore);
  assert(!unavailableReducer.state().transportUnavailable);
  assert(!workout_telemetry::isStale(unavailableReducer.state(), 102));
  assertMetricUnavailableFormatting(unavailableModel);

  Reducer legacyInitiallyUnavailableReducer;
  uint8_t legacyInitialCore[sizeof(initialUnavailableCore)];
  std::memcpy(legacyInitialCore, initialUnavailableCore,
              sizeof(legacyInitialCore));
  uint8_t legacyInitialExtended[sizeof(initialUnavailableExtended)];
  std::memcpy(legacyInitialExtended, initialUnavailableExtended,
              sizeof(legacyInitialExtended));
  legacyInitialExtended[1] = 0;
  assert(legacyInitiallyUnavailableReducer.applyFrame(
             legacyInitialCore, sizeof(legacyInitialCore), 200, true) ==
         ApplyResult::Applied);
  assert(legacyInitiallyUnavailableReducer.applyFrame(
             legacyInitialExtended, sizeof(legacyInitialExtended), 201,
             true) == ApplyResult::Applied);
  assert(!legacyInitiallyUnavailableReducer.state().transportUnavailable);
  assert(!legacyInitiallyUnavailableReducer.state()
              .speedCentimetersPerSecond.available);
  assert(legacyInitiallyUnavailableReducer.applyFrame(
             legacyInitialExtended, sizeof(legacyInitialExtended), 5200,
             true) == ApplyResult::Applied);
  assert(legacyInitiallyUnavailableReducer.state().lastCoreReceivedAtMs ==
         200);
  assert(!workout_telemetry::isStale(
      legacyInitiallyUnavailableReducer.state(), 10199));
  assert(workout_telemetry::isStale(
      legacyInitiallyUnavailableReducer.state(), 10200));

  Reducer transactionalReducer;
  assert(transactionalReducer.applyFrame(core, sizeof(core), 1000, true) ==
         ApplyResult::Applied);
  assert(transactionalReducer.applyFrame(extended, sizeof(extended), 1001,
                                         true) == ApplyResult::Applied);
  const State coherentBeforePair = transactionalReducer.state();
  uint8_t transactionalCore[sizeof(core)];
  std::memcpy(transactionalCore, core, sizeof(transactionalCore));
  transactionalCore[1] = static_cast<uint8_t>(SessionState::Running) | 0x40;
  writeUInt32LE(transactionalCore, 4, 4000);
  uint8_t transactionalExtended[sizeof(extended)];
  std::memcpy(transactionalExtended, extended, sizeof(transactionalExtended));
  transactionalExtended[1] |= 0x40;
  assert(transactionalReducer.applyFrame(transactionalCore,
                                         sizeof(transactionalCore), 1100,
                                         true) == ApplyResult::Applied);
  assert(transactionalReducer.state() == coherentBeforePair);
  uint8_t wrongGenerationExtended[sizeof(transactionalExtended)];
  std::memcpy(wrongGenerationExtended, transactionalExtended,
              sizeof(wrongGenerationExtended));
  wrongGenerationExtended[1] =
      static_cast<uint8_t>((wrongGenerationExtended[1] & 0x3F) | 0x80);
  assertResultPreservesState(transactionalReducer, wrongGenerationExtended,
                             sizeof(wrongGenerationExtended), 1101, true,
                             ApplyResult::IgnoredPair);
  assert(transactionalReducer.applyFrame(transactionalExtended,
                                         sizeof(transactionalExtended), 1102,
                                         true) == ApplyResult::Applied);
  assert(transactionalReducer.state().elapsedSeconds.value == 4000);

  uint8_t transactionalStaleCore[sizeof(unavailableCore)];
  std::memcpy(transactionalStaleCore, unavailableCore,
              sizeof(transactionalStaleCore));
  transactionalStaleCore[1] =
      static_cast<uint8_t>(SessionState::Paused) | 0x80;
  uint8_t transactionalStaleExtended[sizeof(unavailableExtended)];
  std::memcpy(transactionalStaleExtended, unavailableExtended,
              sizeof(transactionalStaleExtended));
  transactionalStaleExtended[1] = 0x80;
  assert(transactionalReducer.applyFrame(transactionalStaleCore,
                                         sizeof(transactionalStaleCore), 1200,
                                         true) == ApplyResult::Applied);
  assert(transactionalReducer.state().elapsedSeconds.value == 4000);
  assert(transactionalReducer.applyFrame(
             transactionalStaleExtended, sizeof(transactionalStaleExtended),
             1201, true) == ApplyResult::Applied);
  assert(transactionalReducer.state().transportUnavailable);
  assert(transactionalReducer.state().elapsedSeconds.value == 4000);
  const uint32_t confirmedCoreBeforeLegacyHeartbeat =
      transactionalReducer.state().lastCoreReceivedAtMs;
  const uint16_t retainedHeartRateBeforeLegacyHeartbeat =
      transactionalReducer.state().currentHeartRateBpm.value;
  assert(transactionalReducer.applyFrame(
             unavailableExtended, sizeof(unavailableExtended), 1202,
             true) == ApplyResult::Applied);
  assert(transactionalReducer.state().transportUnavailable);
  assert(transactionalReducer.state().lastCoreReceivedAtMs ==
         confirmedCoreBeforeLegacyHeartbeat);
  assert(transactionalReducer.state().currentHeartRateBpm.value ==
         retainedHeartRateBeforeLegacyHeartbeat);
  const State staleBeforeOrphanRecovery = transactionalReducer.state();
  uint8_t orphanRecoveryExtended[sizeof(extended)];
  std::memcpy(orphanRecoveryExtended, extended,
              sizeof(orphanRecoveryExtended));
  orphanRecoveryExtended[1] |= 0xC0;
  assertResultPreservesState(transactionalReducer, orphanRecoveryExtended,
                             sizeof(orphanRecoveryExtended), 1203, true,
                             ApplyResult::IgnoredPair);
  assert(transactionalReducer.state() == staleBeforeOrphanRecovery);

  uint8_t endingUnavailableCore[sizeof(unavailableCore)];
  std::memcpy(endingUnavailableCore, unavailableCore,
              sizeof(endingUnavailableCore));
  endingUnavailableCore[1] =
      static_cast<uint8_t>(SessionState::Ending) | 0x40;
  uint8_t currentEndingExtended[sizeof(unavailableExtended)];
  std::memcpy(currentEndingExtended, unavailableExtended,
              sizeof(currentEndingExtended));
  currentEndingExtended[1] =
      workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT | 0x40;
  Reducer currentEndingReducer;
  assert(currentEndingReducer.applyFrame(core, sizeof(core), 1250, true) ==
         ApplyResult::Applied);
  assert(currentEndingReducer.applyFrame(extended, sizeof(extended), 1251,
                                         true) == ApplyResult::Applied);
  assert(currentEndingReducer.applyFrame(endingUnavailableCore,
                                         sizeof(endingUnavailableCore), 1260,
                                         true) == ApplyResult::Applied);
  assert(currentEndingReducer.applyFrame(currentEndingExtended,
                                         sizeof(currentEndingExtended), 1261,
                                         true) == ApplyResult::Applied);
  assert(currentEndingReducer.state().sessionState == SessionState::Ending);
  assert(!currentEndingReducer.state().transportUnavailable);
  assert(!currentEndingReducer.state().currentHeartRateBpm.available);
  assert(!workout_telemetry::isStale(currentEndingReducer.state(), 1261));

  uint8_t disconnectedEndingExtended[sizeof(unavailableExtended)];
  std::memcpy(disconnectedEndingExtended, unavailableExtended,
              sizeof(disconnectedEndingExtended));
  disconnectedEndingExtended[1] = 0x40;
  Reducer disconnectedEndingReducer;
  assert(disconnectedEndingReducer.applyFrame(core, sizeof(core), 1270,
                                              true) ==
         ApplyResult::Applied);
  assert(disconnectedEndingReducer.applyFrame(extended, sizeof(extended),
                                              1271, true) ==
         ApplyResult::Applied);
  assert(disconnectedEndingReducer.applyFrame(
             endingUnavailableCore, sizeof(endingUnavailableCore), 1280,
             true) == ApplyResult::Applied);
  assert(disconnectedEndingReducer.applyFrame(
             disconnectedEndingExtended,
             sizeof(disconnectedEndingExtended), 1281,
             true) == ApplyResult::Applied);
  assert(disconnectedEndingReducer.state().sessionState ==
         SessionState::Ending);
  assert(disconnectedEndingReducer.state().transportUnavailable);
  assert(disconnectedEndingReducer.state().currentHeartRateBpm.value == 157);
  const auto disconnectedEndingModel =
      ride_telemetry_presenter::makeViewModel(
          workout_telemetry::makeSnapshot(disconnectedEndingReducer.state(),
                                          1281),
          legacy);
  assert(disconnectedEndingModel.stale);
  assertText(
      ride_telemetry_presenter::sourceFreshnessLabel(disconnectedEndingModel),
      "WATCH / LINK LOST");

  uint8_t newerTerminalCore[sizeof(core)];
  std::memcpy(newerTerminalCore, core, sizeof(newerTerminalCore));
  newerTerminalCore[1] = static_cast<uint8_t>(SessionState::Ended) | 0x40;
  writeUInt16LE(newerTerminalCore, 2, 0x4321);
  uint8_t newerTerminalExtended[sizeof(extended)];
  std::memcpy(newerTerminalExtended, extended,
              sizeof(newerTerminalExtended));
  newerTerminalExtended[1] |= 0x40;
  writeUInt16LE(newerTerminalExtended, 2, 0x4321);
  assert(transactionalReducer.applyFrame(newerTerminalCore,
                                         sizeof(newerTerminalCore), 1300,
                                         true) == ApplyResult::Applied);
  assert(transactionalReducer.state().sessionToken == 0x1234);
  assert(transactionalReducer.applyFrame(
             newerTerminalExtended, sizeof(newerTerminalExtended), 1301,
             true) == ApplyResult::Applied);
  assert(transactionalReducer.state().sessionToken == 0x4321);
  assert(transactionalReducer.state().sessionState == SessionState::Ended);

  ride_telemetry_presenter::formatDistance(pausedModel.routeRemainingMeters,
                                           formatted, sizeof(formatted));
  assertText(formatted, "1.5 km");

  Reducer wrapReducer;
  const uint32_t nearWrap = std::numeric_limits<uint32_t>::max() - 5000U;
  assert(wrapReducer.applyFrame(core, sizeof(core), nearWrap, true) ==
         ApplyResult::Applied);
  assert(!workout_telemetry::isStale(wrapReducer.state(), 4998U));
  assert(workout_telemetry::isStale(wrapReducer.state(), 4999U));
  const auto staleModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(wrapReducer.state(), 4999U), legacy);
  assert(staleModel.stale);
  ride_telemetry_presenter::formatSpeed(staleModel, formatted,
                                        sizeof(formatted));
  assertText(formatted, "--");
  ride_telemetry_presenter::formatInteger(staleModel.currentHeartRateBpm,
                                          formatted, sizeof(formatted));
  assertText(formatted, "157");
  assertText(ride_telemetry_presenter::sourceFreshnessLabel(staleModel),
             "WATCH / LINK LOST");
  assertText(ride_telemetry_presenter::statusLabel(staleModel), "LINK LOST");
  assert(ride_telemetry_presenter::shouldShowStatus(staleModel));

  uint8_t endedCore[sizeof(core)];
  std::memcpy(endedCore, core, sizeof(core));
  endedCore[1] = static_cast<uint8_t>(SessionState::Ended);
  assert(wrapReducer.applyFrame(endedCore, sizeof(endedCore), 6000, true) ==
         ApplyResult::Applied);
  const auto endedModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(wrapReducer.state(), 500000), legacy);
  assert(!endedModel.stale);
  assertText(ride_telemetry_presenter::statusLabel(endedModel), "ENDED");
  assertText(ride_telemetry_presenter::sourceFreshnessLabel(endedModel),
             "WATCH / FINAL");
  uint8_t delayedRunning[sizeof(core)];
  std::memcpy(delayedRunning, core, sizeof(core));
  assert(wrapReducer.applyFrame(delayedRunning, sizeof(delayedRunning), 6100,
                                true) ==
         ApplyResult::IgnoredStateRegression);
  assert(wrapReducer.state().sessionState == SessionState::Ended);

  uint8_t nextSession[sizeof(core)];
  std::memcpy(nextSession, core, sizeof(core));
  writeUInt16LE(nextSession, 2, 0x4321);
  assert(wrapReducer.applyFrame(nextSession, sizeof(nextSession), 6200, true) ==
         ApplyResult::Applied);
  assert(wrapReducer.state().sessionToken == 0x4321);
  uint8_t failedCore[sizeof(core)];
  std::memcpy(failedCore, nextSession, sizeof(nextSession));
  failedCore[1] = static_cast<uint8_t>(SessionState::Failed);
  assert(wrapReducer.applyFrame(failedCore, sizeof(failedCore), 6300, true) ==
         ApplyResult::Applied);
  const auto failedModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(wrapReducer.state(), 7000), legacy);
  assertText(ride_telemetry_presenter::statusLabel(failedModel), "FAILED");
  assertText(ride_telemetry_presenter::sourceFreshnessLabel(failedModel),
             "WATCH / FAILED");

  const SessionState stickyTerminalStates[] = {
      SessionState::Ending,
      SessionState::Failed,
  };
  for (SessionState stickyState : stickyTerminalStates) {
    Reducer legacyStickyReducer;
    assert(legacyStickyReducer.applyFrame(core, sizeof(core), 6500, true) ==
           ApplyResult::Applied);
    assert(legacyStickyReducer.applyFrame(extended, sizeof(extended), 6501,
                                          true) == ApplyResult::Applied);
    uint8_t terminalCore[sizeof(core)];
    std::memcpy(terminalCore, core, sizeof(terminalCore));
    terminalCore[1] = static_cast<uint8_t>(stickyState);
    assert(legacyStickyReducer.applyFrame(terminalCore, sizeof(terminalCore),
                                          6502, true) ==
           ApplyResult::Applied);
    assertResultPreservesState(legacyStickyReducer, core, sizeof(core), 6503,
                               true,
                               ApplyResult::IgnoredStateRegression);

    Reducer correlatedStickyReducer;
    assert(correlatedStickyReducer.applyFrame(core, sizeof(core), 6510,
                                              true) ==
           ApplyResult::Applied);
    assert(correlatedStickyReducer.applyFrame(extended, sizeof(extended),
                                              6511, true) ==
           ApplyResult::Applied);
    uint8_t correlatedTerminalCore[sizeof(core)];
    std::memcpy(correlatedTerminalCore, terminalCore,
                sizeof(correlatedTerminalCore));
    correlatedTerminalCore[1] |= 0x40;
    uint8_t correlatedTerminalExtended[sizeof(extended)];
    std::memcpy(correlatedTerminalExtended, extended,
                sizeof(correlatedTerminalExtended));
    correlatedTerminalExtended[1] |= 0x40;
    assert(correlatedStickyReducer.applyFrame(
               correlatedTerminalCore, sizeof(correlatedTerminalCore), 6512,
               true) == ApplyResult::Applied);
    assert(correlatedStickyReducer.applyFrame(
               correlatedTerminalExtended,
               sizeof(correlatedTerminalExtended), 6513,
               true) == ApplyResult::Applied);
    const State stickySnapshot = correlatedStickyReducer.state();
    uint8_t delayedCorrelatedRunning[sizeof(core)];
    std::memcpy(delayedCorrelatedRunning, core,
                sizeof(delayedCorrelatedRunning));
    delayedCorrelatedRunning[1] =
        static_cast<uint8_t>(SessionState::Running) | 0x80;
    assert(correlatedStickyReducer.applyFrame(
               delayedCorrelatedRunning,
               sizeof(delayedCorrelatedRunning), 6514,
               true) == ApplyResult::IgnoredStateRegression);
    assert(correlatedStickyReducer.state() == stickySnapshot);
  }

  uint8_t collisionEndedCore[sizeof(core)];
  std::memcpy(collisionEndedCore, core, sizeof(collisionEndedCore));
  collisionEndedCore[1] = static_cast<uint8_t>(SessionState::Ended);
  uint8_t collisionStartingCore[sizeof(core)];
  std::memcpy(collisionStartingCore, core, sizeof(collisionStartingCore));
  collisionStartingCore[1] = static_cast<uint8_t>(SessionState::Starting);
  Reducer legacyCollisionReducer;
  assert(legacyCollisionReducer.applyFrame(collisionEndedCore,
                                           sizeof(collisionEndedCore), 6520,
                                           true) == ApplyResult::Applied);
  assert(legacyCollisionReducer.applyFrame(collisionStartingCore,
                                           sizeof(collisionStartingCore),
                                           6521, true) ==
         ApplyResult::Applied);
  assert(legacyCollisionReducer.state().sessionState ==
         SessionState::Starting);

  Reducer correlatedCollisionReducer;
  assert(correlatedCollisionReducer.applyFrame(collisionEndedCore,
                                               sizeof(collisionEndedCore),
                                               6530, true) ==
         ApplyResult::Applied);
  uint8_t correlatedCollisionCore[sizeof(collisionStartingCore)];
  std::memcpy(correlatedCollisionCore, collisionStartingCore,
              sizeof(correlatedCollisionCore));
  correlatedCollisionCore[1] |= 0x40;
  uint8_t correlatedCollisionExtended[sizeof(extended)];
  std::memcpy(correlatedCollisionExtended, extended,
              sizeof(correlatedCollisionExtended));
  correlatedCollisionExtended[1] |= 0x40;
  assert(correlatedCollisionReducer.applyFrame(
             correlatedCollisionCore, sizeof(correlatedCollisionCore), 6531,
             true) == ApplyResult::Applied);
  assert(correlatedCollisionReducer.state().sessionState ==
         SessionState::Ended);
  assert(correlatedCollisionReducer.applyFrame(
             correlatedCollisionExtended,
             sizeof(correlatedCollisionExtended), 6532,
             true) == ApplyResult::Applied);
  assert(correlatedCollisionReducer.state().sessionState ==
         SessionState::Starting);

  const SessionState terminalStates[] = {
      SessionState::Ending,
      SessionState::Ended,
      SessionState::Failed,
  };
  for (std::size_t index = 0;
       index < sizeof(terminalStates) / sizeof(terminalStates[0]); ++index) {
    const uint16_t token = static_cast<uint16_t>(0x5000 + index);
    uint8_t terminalCore[sizeof(core)];
    std::memcpy(terminalCore, core, sizeof(terminalCore));
    terminalCore[1] = static_cast<uint8_t>(terminalStates[index]);
    writeUInt16LE(terminalCore, 2, token);
    uint8_t terminalExtended[sizeof(extended)];
    std::memcpy(terminalExtended, extended, sizeof(terminalExtended));
    writeUInt16LE(terminalExtended, 2, token);

    Reducer resynchronized;
    assert(resynchronized.applyFrame(terminalCore, sizeof(terminalCore), 7000,
                                     true) == ApplyResult::Applied);
    assert(resynchronized.state().sessionState == terminalStates[index]);
    assert(resynchronized.state().sessionToken == token);
    assert(resynchronized.applyFrame(terminalExtended,
                                     sizeof(terminalExtended), 7001, true) ==
           ApplyResult::Applied);
    assert(resynchronized.state().extendedReceived);
    assert(resynchronized.state().averageHeartRateBpm.value == 148);
  }

  AuthenticatedResynchronizer authenticationBoundaryReducer;
  uint8_t endedSessionA[sizeof(core)];
  std::memcpy(endedSessionA, core, sizeof(endedSessionA));
  endedSessionA[1] = static_cast<uint8_t>(SessionState::Ended);
  writeUInt16LE(endedSessionA, 2, 0x6001);
  assert(authenticationBoundaryReducer.applyFrame(
             endedSessionA, sizeof(endedSessionA), 7100, true) ==
         ApplyResult::Applied);
  uint8_t endedSessionB[sizeof(core)];
  std::memcpy(endedSessionB, endedSessionA, sizeof(endedSessionB));
  writeUInt16LE(endedSessionB, 2, 0x6002);
  assert(authenticationBoundaryReducer.applyFrame(
             endedSessionB, sizeof(endedSessionB), 7101, true) ==
         ApplyResult::IgnoredToken);
  authenticationBoundaryReducer.beginResynchronization();
  assert(authenticationBoundaryReducer.resynchronizationPending());
  assert(authenticationBoundaryReducer.state().sessionToken == 0x6001);
  assert(authenticationBoundaryReducer.applyFrame(
             endedSessionB, sizeof(endedSessionB), 7102, true) ==
         ApplyResult::Applied);
  assert(authenticationBoundaryReducer.resynchronizationPending());
  assert(authenticationBoundaryReducer.state().sessionToken == 0x6001);
  uint8_t endedSessionBExtended[sizeof(extended)];
  std::memcpy(endedSessionBExtended, extended,
              sizeof(endedSessionBExtended));
  writeUInt16LE(endedSessionBExtended, 2, 0x6002);
  authenticationBoundaryReducer.beginResynchronization();
  assert(authenticationBoundaryReducer.state().sessionToken == 0x6001);
  assert(authenticationBoundaryReducer.applyFrame(
             endedSessionB, sizeof(endedSessionB), 7103, true) ==
         ApplyResult::Applied);
  uint8_t malformedSessionBExtended[sizeof(endedSessionBExtended)];
  std::memcpy(malformedSessionBExtended, endedSessionBExtended,
              sizeof(malformedSessionBExtended));
  malformedSessionBExtended[1] |= 0x40;
  assert(authenticationBoundaryReducer.applyFrame(
             malformedSessionBExtended, sizeof(malformedSessionBExtended),
             7104, true) == ApplyResult::IgnoredPair);
  assert(authenticationBoundaryReducer.resynchronizationPending());
  assert(authenticationBoundaryReducer.state().sessionToken == 0x6001);
  assert(authenticationBoundaryReducer.applyFrame(
             endedSessionBExtended, sizeof(endedSessionBExtended), 7105,
             true) == ApplyResult::Applied);
  assert(!authenticationBoundaryReducer.resynchronizationPending());
  assert(authenticationBoundaryReducer.state().sessionToken == 0x6002);
  assert(authenticationBoundaryReducer.state().sessionState ==
         SessionState::Ended);

  AuthenticatedResynchronizer staleAuthenticationReducer;
  assert(staleAuthenticationReducer.applyFrame(core, sizeof(core), 7200,
                                               true) ==
         ApplyResult::Applied);
  assert(staleAuthenticationReducer.applyFrame(extended, sizeof(extended),
                                               7201, true) ==
         ApplyResult::Applied);
  const State retainedBeforeStaleAuthentication =
      staleAuthenticationReducer.state();
  staleAuthenticationReducer.beginResynchronization();
  uint8_t authenticatedStaleCore[sizeof(unavailableCore)];
  std::memcpy(authenticatedStaleCore, unavailableCore,
              sizeof(authenticatedStaleCore));
  authenticatedStaleCore[1] =
      static_cast<uint8_t>(SessionState::Paused) | 0x40;
  uint8_t authenticatedStaleExtended[sizeof(unavailableExtended)];
  std::memcpy(authenticatedStaleExtended, unavailableExtended,
              sizeof(authenticatedStaleExtended));
  authenticatedStaleExtended[1] = 0x40;
  assert(staleAuthenticationReducer.applyFrame(
             authenticatedStaleCore, sizeof(authenticatedStaleCore), 7202,
             true) == ApplyResult::Applied);
  assert(staleAuthenticationReducer.state() ==
         retainedBeforeStaleAuthentication);
  assert(staleAuthenticationReducer.applyFrame(
             authenticatedStaleExtended,
             sizeof(authenticatedStaleExtended), 7203, true) ==
         ApplyResult::Applied);
  assert(staleAuthenticationReducer.state().transportUnavailable);
  assert(staleAuthenticationReducer.state().currentHeartRateBpm.value == 157);
  assert(staleAuthenticationReducer.state().distanceMeters.value == 12345);

  struct CollidingReconnectCase {
    SessionState retained;
    SessionState incoming;
  };
  const CollidingReconnectCase collidingReconnectCases[] = {
      {SessionState::Ending, SessionState::Starting},
      {SessionState::Ending, SessionState::Running},
      {SessionState::Ending, SessionState::Paused},
      {SessionState::Ended, SessionState::Running},
      {SessionState::Failed, SessionState::Paused},
      {SessionState::Ended, SessionState::Ending},
      {SessionState::Failed, SessionState::Ended},
      {SessionState::Ended, SessionState::Failed},
  };
  for (std::size_t index = 0;
       index < sizeof(collidingReconnectCases) /
                   sizeof(collidingReconnectCases[0]);
       ++index) {
    constexpr uint16_t collidingToken = 0x6A01;
    AuthenticatedResynchronizer collidingReconnectReducer;
    uint8_t retainedEndedCore[sizeof(core)];
    std::memcpy(retainedEndedCore, core, sizeof(retainedEndedCore));
    retainedEndedCore[1] =
        static_cast<uint8_t>(collidingReconnectCases[index].retained);
    writeUInt16LE(retainedEndedCore, 2, collidingToken);
    uint8_t retainedEndedExtended[sizeof(extended)];
    std::memcpy(retainedEndedExtended, extended,
                sizeof(retainedEndedExtended));
    writeUInt16LE(retainedEndedExtended, 2, collidingToken);
    assert(collidingReconnectReducer.applyFrame(
               retainedEndedCore, sizeof(retainedEndedCore), 7300, true) ==
           ApplyResult::Applied);
    assert(collidingReconnectReducer.applyFrame(
               retainedEndedExtended, sizeof(retainedEndedExtended), 7301,
               true) == ApplyResult::Applied);

    collidingReconnectReducer.beginResynchronization();
    uint8_t collidingLiveCore[sizeof(core)];
    std::memcpy(collidingLiveCore, core, sizeof(collidingLiveCore));
    collidingLiveCore[1] =
        static_cast<uint8_t>(collidingReconnectCases[index].incoming) |
        0x40;
    writeUInt16LE(collidingLiveCore, 2, collidingToken);
    uint8_t collidingLiveExtended[sizeof(extended)];
    std::memcpy(collidingLiveExtended, extended,
                sizeof(collidingLiveExtended));
    collidingLiveExtended[1] =
        workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT | 0x40;
    writeUInt16LE(collidingLiveExtended, 2, collidingToken);

    assert(collidingReconnectReducer.applyFrame(
               collidingLiveCore, sizeof(collidingLiveCore), 7310, true) ==
           ApplyResult::Applied);
    assert(collidingReconnectReducer.state().sessionState ==
           collidingReconnectCases[index].retained);
    assert(collidingReconnectReducer.resynchronizationPending());
    assert(collidingReconnectReducer.applyFrame(
               collidingLiveExtended, sizeof(collidingLiveExtended), 7311,
               true) == ApplyResult::Applied);
    assert(!collidingReconnectReducer.resynchronizationPending());
    assert(collidingReconnectReducer.state().sessionState ==
           collidingReconnectCases[index].incoming);
    assert(collidingReconnectReducer.state().sessionToken == collidingToken);
  }

  constexpr uint16_t staleCollisionToken = 0x6A02;
  AuthenticatedResynchronizer staleCollisionReducer;
  uint8_t staleCollisionEndedCore[sizeof(core)];
  std::memcpy(staleCollisionEndedCore, core, sizeof(staleCollisionEndedCore));
  staleCollisionEndedCore[1] = static_cast<uint8_t>(SessionState::Ended);
  writeUInt16LE(staleCollisionEndedCore, 2, staleCollisionToken);
  uint8_t staleCollisionEndedExtended[sizeof(extended)];
  std::memcpy(staleCollisionEndedExtended, extended,
              sizeof(staleCollisionEndedExtended));
  writeUInt16LE(staleCollisionEndedExtended, 2, staleCollisionToken);
  assert(staleCollisionReducer.applyFrame(
             staleCollisionEndedCore, sizeof(staleCollisionEndedCore), 7320,
             true) == ApplyResult::Applied);
  assert(staleCollisionReducer.applyFrame(
             staleCollisionEndedExtended,
             sizeof(staleCollisionEndedExtended), 7321, true) ==
         ApplyResult::Applied);
  const State retainedBeforeStaleCollision = staleCollisionReducer.state();
  staleCollisionReducer.beginResynchronization();
  uint8_t staleCollisionCore[sizeof(unavailableCore)];
  std::memcpy(staleCollisionCore, unavailableCore,
              sizeof(staleCollisionCore));
  staleCollisionCore[1] = static_cast<uint8_t>(SessionState::Running) | 0x80;
  writeUInt16LE(staleCollisionCore, 2, staleCollisionToken);
  uint8_t staleCollisionExtended[sizeof(unavailableExtended)];
  std::memcpy(staleCollisionExtended, unavailableExtended,
              sizeof(staleCollisionExtended));
  staleCollisionExtended[1] = 0x80;
  writeUInt16LE(staleCollisionExtended, 2, staleCollisionToken);
  assert(staleCollisionReducer.applyFrame(
             staleCollisionCore, sizeof(staleCollisionCore), 7330, true) ==
         ApplyResult::Applied);
  assert(staleCollisionReducer.state() == retainedBeforeStaleCollision);
  assert(staleCollisionReducer.applyFrame(
             staleCollisionExtended, sizeof(staleCollisionExtended), 7331,
             true) == ApplyResult::IgnoredStateRegression);
  assert(staleCollisionReducer.state() == retainedBeforeStaleCollision);
  assert(staleCollisionReducer.resynchronizationPending());

  uint8_t saturatedExtended[sizeof(extended)];
  std::memcpy(saturatedExtended, extended, sizeof(extended));
  writeUInt16LE(saturatedExtended, 2, 0x4321);
  saturatedExtended[1] =
      workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT;
  writeUInt16LE(saturatedExtended, 4, UINT16_MAX - 1);
  writeUInt16LE(saturatedExtended, 6, UINT16_MAX - 1);
  writeUInt16LE(saturatedExtended, 8, UINT16_MAX - 1);
  writeUInt16LE(saturatedExtended, 10, UINT16_MAX - 1);
  saturatedExtended[12] = 0;
  writeInt16LE(saturatedExtended, 13, INT16_MAX);
  saturatedExtended[15] = 0;
  assert(wrapReducer.applyFrame(saturatedExtended, sizeof(saturatedExtended),
                                6400, true) == ApplyResult::Applied);
  const auto saturatedModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(wrapReducer.state(), 6500), legacy);
  ride_telemetry_presenter::formatEnergy(saturatedModel, formatted,
                                         sizeof(formatted));
  assertText(formatted, "6553.4");
  ride_telemetry_presenter::formatCadence(saturatedModel, formatted,
                                          sizeof(formatted));
  assertText(formatted, "6553.4");
  ride_telemetry_presenter::formatInteger(saturatedModel.altitudeMeters,
                                          formatted, sizeof(formatted));
  assertText(formatted, "32767");

  uint8_t idleCore[sizeof(core)]{};
  idleCore[0] = 1;
  idleCore[1] = static_cast<uint8_t>(SessionState::Idle);
  writeUInt32LE(idleCore, 4,
                workout_telemetry_protocol::UNAVAILABLE_UINT32);
  writeUInt32LE(idleCore, 8,
                workout_telemetry_protocol::UNAVAILABLE_UINT32);
  writeUInt16LE(idleCore, 12,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  writeUInt16LE(idleCore, 14,
                workout_telemetry_protocol::UNAVAILABLE_UINT16);
  assert(wrapReducer.applyFrame(idleCore, sizeof(idleCore), 6600, true) ==
         ApplyResult::Cleared);
  assert(!wrapReducer.state().coreReceived);
  const auto legacyModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(wrapReducer.state(), 6700), legacy);
  assert(!legacyModel.usesWorkout);
  assert(legacyModel.hasActiveNavigation);
  assertText(ride_telemetry_presenter::statusLabel(legacyModel),
             "LEGACY RIDE");
  assert(!ride_telemetry_presenter::shouldShowStatus(legacyModel));
  ride_telemetry_presenter::formatSpeed(legacyModel, formatted,
                                        sizeof(formatted));
  assertText(formatted, "27.0");
  const ride_telemetry_presenter::LegacyRideTelemetry idleLegacy{
      0, 88, 0, 0, false, 0};
  const auto idleLegacyModel = ride_telemetry_presenter::makeViewModel(
      workout_telemetry::makeSnapshot(wrapReducer.state(), 6700), idleLegacy);
  assert(!idleLegacyModel.usesWorkout);
  assert(!idleLegacyModel.hasActiveNavigation);
  assert(!idleLegacyModel.routeRemainingMeters.available);

  uint8_t gpsPacket[36]{};
  writeUInt32LE(gpsPacket, 0, static_cast<uint32_t>(12345678));
  writeUInt32LE(gpsPacket, 4, static_cast<uint32_t>(-23456789));
  writeUInt16LE(gpsPacket, 8, 270);
  writeUInt32LE(gpsPacket, 10, 1700000000);
  writeUInt16LE(gpsPacket, 14, 1234);
  writeInt16LE(gpsPacket, 16, -12);
  writeUInt32LE(gpsPacket, 18, 12345);
  writeUInt32LE(gpsPacket, 22, 3661);
  writeUInt32LE(gpsPacket, 26, 4321);

  gps_position_protocol::Packet decoded{};
  assert(!gps_position_protocol::decode(gpsPacket, 7, decoded));
  assert(gps_position_protocol::decode(gpsPacket, 8, decoded));
  assert(!decoded.hasHeading && !decoded.hasUnixTime && !decoded.hasSpeed);
  assert(gps_position_protocol::decode(gpsPacket, 10, decoded));
  assert(decoded.hasHeading && decoded.headingDegrees == 270);
  assert(!decoded.hasUnixTime && !decoded.hasSpeed);
  assert(gps_position_protocol::decode(gpsPacket, 14, decoded));
  assert(decoded.hasUnixTime && decoded.unixTime == 1700000000);
  assert(!decoded.hasSpeed);
  assert(gps_position_protocol::decode(gpsPacket, 30, decoded));
  assert(decoded.latitudeMicrodegrees == 12345678);
  assert(decoded.longitudeMicrodegrees == -23456789);
  assert(decoded.hasSpeed && decoded.speedCentimetersPerSecond == 1234);
  assert(decoded.hasAltitude && decoded.altitudeMeters == -12);
  assert(decoded.hasDistance && decoded.distanceMeters == 12345);
  assert(decoded.hasElapsed && decoded.elapsedSeconds == 3661);
  assert(decoded.hasRouteRemaining && decoded.routeRemainingMeters == 4321);

  gpsPacket[30] = gps_position_protocol::QUALITY_V1_SCHEMA;
  gpsPacket[31] = gps_position_protocol::QUALITY_FIX_VALID |
                  gps_position_protocol::QUALITY_ACCURACY_AVAILABLE;
  writeUInt16LE(gpsPacket, 32, 73);
  writeUInt16LE(gpsPacket, 34, 1234);
  assert(gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));
  assert(decoded.hasRideDetectionQuality && decoded.fixValid);
  assert(decoded.hasHorizontalAccuracy &&
         decoded.horizontalAccuracyDecimeters == 73);
  assert(decoded.hasSampleAge && decoded.sampleAgeMs == 1234);

  gpsPacket[30] = 2;
  assert(!gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));
  gpsPacket[30] = gps_position_protocol::QUALITY_V1_SCHEMA;
  gpsPacket[31] |= 1U << 7;
  assert(!gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));
  gpsPacket[31] = gps_position_protocol::QUALITY_FIX_VALID |
                  gps_position_protocol::QUALITY_ACCURACY_AVAILABLE;
  writeUInt16LE(gpsPacket, 32, UINT16_MAX);
  assert(!gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));
  writeUInt16LE(gpsPacket, 32, 73);
  writeUInt16LE(gpsPacket, 34, UINT16_MAX);
  assert(!gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));
  writeUInt16LE(gpsPacket, 34, 1234);
  writeUInt32LE(gpsPacket, 0, static_cast<uint32_t>(91'000'000));
  assert(!gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));
  writeUInt32LE(gpsPacket, 0, static_cast<uint32_t>(12'345'678));
  assert(gps_position_protocol::decode(gpsPacket, sizeof(gpsPacket), decoded));

  Reducer independentReducer;
  assert(independentReducer.applyFrame(core, sizeof(core), 7000, true) ==
         ApplyResult::Applied);
  assert(independentReducer.applyFrame(extended, sizeof(extended), 7001,
                                       true) == ApplyResult::Applied);
  const State workoutBeforeGps = independentReducer.state();
  const std::size_t legacyPacketLengths[] = {8, 10, 14, 30};
  for (std::size_t length : legacyPacketLengths) {
    TestRideData rideData{};
    rideData.heading = 99;
    assert(gps_position_protocol::decodeAndApply(
        gpsPacket, length, rideData, &decoded));
    assert(independentReducer.state() == workoutBeforeGps);
    assert(rideData.latitude == 12.345678);
    assert(rideData.longitude == -23.456789);
    assert(rideData.fixMode == 3);
    assert(rideData.satellites == 10);
    if (length == 8) {
      assert(rideData.heading == 99);
      assert(!rideData.headingValid);
      assert(rideData.speed == 0);
    }
    if (length >= 10) {
      assert(rideData.heading == 270);
      assert(rideData.headingValid);
    }
    if (length == 30) {
      assert(rideData.speed == 44);
      assert(rideData.altitude == -12);
      assert(rideData.distanceTraveled == 12345);
      assert(rideData.elapsedSeconds == 3661);
      assert(rideData.hasRouteRemaining);
      assert(rideData.routeRemaining == 4321);
    }
  }

  writeUInt16LE(gpsPacket, 8, UINT16_MAX);
  assert(gps_position_protocol::decode(gpsPacket, 10, decoded));
  assert(!decoded.hasHeading);
  TestRideData invalidHeadingRide{};
  invalidHeadingRide.heading = 123;
  invalidHeadingRide.headingValid = true;
  assert(gps_position_protocol::decodeAndApply(
      gpsPacket, 10, invalidHeadingRide, &decoded));
  assert(!invalidHeadingRide.headingValid);
  assert(invalidHeadingRide.heading == 123);

  writeUInt16LE(gpsPacket, 8, 360);
  assert(gps_position_protocol::decode(gpsPacket, 10, decoded));
  assert(!decoded.hasHeading);

  return 0;
}
