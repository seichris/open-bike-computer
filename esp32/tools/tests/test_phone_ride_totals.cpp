// Host test: phone-fed ride totals keep their own freshness, independent of
// the position source (GNSS bench, 2026-11-18).
//
//   g++ -std=c++17 -Wall -Wextra -Werror tools/tests/test_phone_ride_totals.cpp
#include "../../lib/ble_navigation/gps_position_protocol.hpp"
#include "../../lib/ble_navigation/phone_ride_totals.hpp"
#include "../../lib/gui/src/rideTelemetryPresenter.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>

namespace {

using phone_ride_totals::fresh;
using phone_ride_totals::kFreshMs;
using phone_ride_totals::received;
using phone_ride_totals::Stamp;
using ride_telemetry_presenter::LegacyRideTelemetry;
using ride_telemetry_presenter::makeViewModel;
using ride_telemetry_presenter::ViewModel;

// The GPSDATA fields gps_position_protocol::apply() writes.
struct RideData {
  double latitude = 0;
  double longitude = 0;
  uint8_t fixMode = 0;
  uint8_t satellites = 0;
  uint16_t speed = 0;
  int16_t altitude = 0;
  bool headingValid = false;
  uint16_t heading = 0;
  uint32_t distanceTraveled = 0;
  uint32_t elapsedSeconds = 0;
  uint32_t routeRemaining = 0;
  bool hasRouteRemaining = false;
};

gps_position_protocol::Packet navigatingPacket(uint32_t distance,
                                               uint32_t elapsed,
                                               uint32_t routeRemaining) {
  gps_position_protocol::Packet packet;
  packet.latitudeMicrodegrees = 1'305'000;
  packet.longitudeMicrodegrees = 103'855'000;
  packet.hasSpeed = true;
  packet.speedCentimetersPerSecond = 500;
  packet.hasDistance = true;
  packet.distanceMeters = distance;
  packet.hasElapsed = true;
  packet.elapsedSeconds = elapsed;
  packet.hasRouteRemaining = true;
  packet.routeRemainingMeters = routeRemaining;
  return packet;
}

gps_position_protocol::Packet idlePacket() {
  gps_position_protocol::Packet packet;
  packet.latitudeMicrodegrees = 1'305'000;
  packet.longitudeMicrodegrees = 103'855'000;
  return packet;
}

// The legacy telemetry rideTelemetryScr.cpp builds, with the board's own
// receiver keeping the position fresh throughout.
LegacyRideTelemetry legacyFrom(const RideData &data, bool totalsFresh) {
  LegacyRideTelemetry legacy;
  legacy.speedKilometersPerHour = 18;
  legacy.altitudeMeters = data.altitude;
  legacy.distanceMeters = data.distanceTraveled;
  legacy.elapsedSeconds = data.elapsedSeconds;
  legacy.hasRouteRemaining = data.hasRouteRemaining;
  legacy.routeRemainingMeters = data.routeRemaining;
  legacy.gpsFresh = true;
  legacy.speedAvailable = true;
  legacy.totalsFresh = totalsFresh;
  return legacy;
}

std::string formattedDistance(const ViewModel &model) {
  char text[24] = {};
  ride_telemetry_presenter::formatDistance(model.distanceMeters, text,
                                           sizeof(text));
  return text;
}

std::string formattedElapsed(const ViewModel &model) {
  char text[24] = {};
  ride_telemetry_presenter::formatElapsed(model.elapsedSeconds, text,
                                          sizeof(text));
  return text;
}

ViewModel present(const RideData &data, const Stamp &stamp, uint32_t nowMs,
                  uint32_t generation) {
  return makeViewModel(workout_telemetry::Snapshot{},
                       legacyFrom(data, fresh(stamp, nowMs, generation)));
}

void testStampFreshness() {
  const Stamp none{};
  assert(!fresh(none, 0, 1));
  assert(!fresh(none, 1'000, 1));

  const Stamp stamp = received(5'000, 7);
  assert(fresh(stamp, 5'000, 7));
  assert(fresh(stamp, 5'000 + kFreshMs - 1, 7));
  assert(!fresh(stamp, 5'000 + kFreshMs, 7));
  // The session ended: stale at once, however recent the packet.
  assert(!fresh(stamp, 5'001, 8));
  // Wrap-safe ages.
  const Stamp wrapped = received(UINT32_MAX - 1'000, 3);
  assert(fresh(wrapped, 2'000, 3));
  assert(!fresh(wrapped, kFreshMs, 3));
}

void testPresenterHidesStaleTotals() {
  RideData data;
  data.distanceTraveled = 1'200;
  data.elapsedSeconds = 300;
  data.hasRouteRemaining = true;
  data.routeRemaining = 16'000;

  const ViewModel live = makeViewModel(workout_telemetry::Snapshot{},
                                       legacyFrom(data, true));
  assert(!live.usesWorkout);
  assert(live.hasActiveNavigation);
  assert(live.distanceMeters.available && live.distanceMeters.value == 1'200);
  assert(live.elapsedSeconds.available && live.elapsedSeconds.value == 300);
  assert(live.routeRemainingMeters.available &&
         live.routeRemainingMeters.value == 16'000);
  assert(formattedElapsed(live) == "05:00");

  const ViewModel stale = makeViewModel(workout_telemetry::Snapshot{},
                                        legacyFrom(data, false));
  assert(!stale.hasActiveNavigation);
  assert(!stale.distanceMeters.available);
  assert(!stale.elapsedSeconds.available);
  assert(!stale.routeRemainingMeters.available);
  assert(formattedDistance(stale) == "--");
  assert(formattedElapsed(stale) == "--");
  // The receiver keeps speed and position live; only the phone totals go.
  assert(!stale.stale);
  assert(stale.speedTenthsKmh.available);
  assert(stale.altitudeMeters.available);
}

void testWorkoutTelemetryIsPreserved() {
  workout_telemetry::Snapshot workout;
  workout.state.coreReceived = true;
  workout.state.sessionState = workout_telemetry_protocol::SessionState::Running;
  workout.state.distanceMeters = {true, 5'000};
  workout.state.elapsedSeconds = {true, 900};

  RideData data;
  data.hasRouteRemaining = true;
  data.routeRemaining = 4'000;
  for (const bool totalsFresh : {true, false}) {
    const ViewModel model = makeViewModel(workout, legacyFrom(data, totalsFresh));
    assert(model.usesWorkout);
    assert(model.distanceMeters.available && model.distanceMeters.value == 5'000);
    assert(model.elapsedSeconds.available && model.elapsedSeconds.value == 900);
    // Route Left still comes from the phone's GPS packets.
    assert(model.hasActiveNavigation == totalsFresh);
    assert(model.routeRemainingMeters.available == totalsFresh);
  }
}

// Navigation-only ride on a GNSS board: the phone drops, stops navigation
// while away, and reconnects. The old route totals must never come back.
void testStopWhileDisconnectedNeverRevivesRouteTotals() {
  RideData data;
  uint32_t generation = 7;
  Stamp stamp{};
  uint32_t now = 100'000;

  // Connected and navigating; the board's receiver owns the position.
  gps_position_protocol::apply(navigatingPacket(1'200, 300, 16'000), false,
                               data);
  stamp = received(now, generation);
  ViewModel model = present(data, stamp, now, generation);
  assert(model.hasActiveNavigation && model.routeRemainingMeters.value == 16'000);
  assert(model.distanceMeters.available && model.elapsedSeconds.available);
  // The receiver-owned position was not overwritten by the phone packet.
  assert(data.latitude == 0 && data.longitude == 0);

  // Totals keep advancing while packets arrive.
  now += 1'000;
  gps_position_protocol::apply(navigatingPacket(1'205, 301, 15'995), false,
                               data);
  stamp = received(now, generation);
  model = present(data, stamp, now, generation);
  assert(model.distanceMeters.value == 1'205);
  assert(model.elapsedSeconds.value == 301);

  // The link drops (reason 12, 06:26:23): the ride payload generation
  // advances and every phone total is withdrawn at once.
  ++generation;
  now += 500;
  model = present(data, stamp, now, generation);
  assert(!model.hasActiveNavigation);
  assert(!model.routeRemainingMeters.available);
  assert(!model.distanceMeters.available && !model.elapsedSeconds.available);

  // Two minutes pass; the phone stops navigation while away.
  now += 120'000;
  model = present(data, stamp, now, generation);
  assert(!model.hasActiveNavigation && !model.distanceMeters.available);

  // The phone reconnects (a new lease, so a new generation). Before its
  // first packet nothing revives the old totals.
  ++generation;
  now += 1'000;
  model = present(data, stamp, now, generation);
  assert(!model.hasActiveNavigation);
  assert(!model.routeRemainingMeters.available);
  assert(!model.distanceMeters.available);

  // Its first packet carries no ride totals: navigation is over.
  gps_position_protocol::apply(idlePacket(), false, data);
  stamp = received(now, generation);
  model = present(data, stamp, now, generation);
  assert(!model.hasActiveNavigation);
  assert(!model.routeRemainingMeters.available);
  assert(model.distanceMeters.available && model.distanceMeters.value == 0);
  assert(model.elapsedSeconds.available && model.elapsedSeconds.value == 0);
}

void testReconnectWhileNavigatingResumesFromNewPackets() {
  RideData data;
  uint32_t generation = 20;
  uint32_t now = 1'000;
  gps_position_protocol::apply(navigatingPacket(3'000, 600, 9'000), true, data);
  Stamp stamp = received(now, generation);
  assert(present(data, stamp, now, generation).hasActiveNavigation);

  ++generation; // link lost
  now += 4'000;
  assert(!present(data, stamp, now, generation).hasActiveNavigation);

  ++generation; // reconnected, still navigating on the phone
  now += 2'000;
  assert(!present(data, stamp, now, generation).distanceMeters.available);
  gps_position_protocol::apply(navigatingPacket(3'050, 606, 8'950), true, data);
  stamp = received(now, generation);
  const ViewModel model = present(data, stamp, now, generation);
  assert(model.hasActiveNavigation && model.routeRemainingMeters.value == 8'950);
  assert(model.distanceMeters.value == 3'050);
}

void testConnectedExpiry() {
  RideData data;
  const uint32_t generation = 4;
  gps_position_protocol::apply(navigatingPacket(800, 120, 2'000), false, data);
  const Stamp stamp = received(50'000, generation);
  assert(present(data, stamp, 50'000 + kFreshMs - 1, generation)
             .hasActiveNavigation);
  // The phone stays connected but stops sending: expire, do not freeze.
  const ViewModel expired = present(data, stamp, 50'000 + kFreshMs, generation);
  assert(!expired.hasActiveNavigation);
  assert(!expired.distanceMeters.available);
  assert(!expired.elapsedSeconds.available);
}

void testLegacyInitializerKeepsConnectedBehavior() {
  // Existing positional initializers (and the default) still mean live.
  const LegacyRideTelemetry legacy{27, 88, 8'000, 3'723, true, 1'500};
  const ViewModel model =
      makeViewModel(workout_telemetry::Snapshot{}, legacy);
  assert(model.hasActiveNavigation);
  assert(model.distanceMeters.available && model.elapsedSeconds.available);
}

} // namespace

int main() {
  testStampFreshness();
  testPresenterHidesStaleTotals();
  testWorkoutTelemetryIsPreserved();
  testStopWhileDisconnectedNeverRevivesRouteTotals();
  testReconnectWhileNavigatingResumesFromNewPackets();
  testConnectedExpiry();
  testLegacyInitializerKeepsConnectedBehavior();
  return 0;
}
