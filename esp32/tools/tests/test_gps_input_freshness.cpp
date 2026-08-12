#include "../../lib/ble_navigation/gps_input_freshness.hpp"
#include "../../lib/gps/gps_ride_observation.hpp"
#include "../../lib/maps/src/mapPresentation.hpp"

#include <cassert>
#include <cstdint>
#include <limits>

int main() {
  using namespace gps_input_freshness;

  const uint8_t validPayload[8] = {};
  const uint8_t shortPayload[7] = {};
  assert(acceptsPayload(validPayload, sizeof(validPayload)));
  assert(!acceptsPayload(shortPayload, sizeof(shortPayload)));
  assert(!acceptsPayload(nullptr, 0));

  // Three healthy packets may be coalesced to one latest-state payload while
  // the UI is busy. Their transport cadence must remain 1 Hz and the latest
  // accepted time must remain 2000 ms regardless of a much later drain.
  ArrivalBatch coalesced;
  coalesced.observe(0);
  coalesced.observe(1000);
  coalesced.observe(2000);
  State state;
  state.accept(coalesced);
  assert(state.hasPacket);
  assert(state.packetCount == 3);
  assert(state.lastPacketMs == 2000);
  assert(state.lastGapMs == 1000);
  assert(state.maximumGapMs == 1000);

  ArrivalBatch delayedHeartbeat;
  delayedHeartbeat.observe(5000);
  state.accept(delayedHeartbeat);
  assert(state.packetCount == 4);
  assert(state.lastPacketMs == 5000);
  assert(state.lastGapMs == 3000);
  assert(state.maximumGapMs == 3000);

  // The presenter consumes the accepted BLE time, not the later UI drain. A
  // latest packet accepted at 5000 and drained at 9000 is already exhausted;
  // it does not receive another 2.5-second motion horizon at drain time.
  map_presentation::Presenter presenter;
  presenter.observe({{0.0, 0.0}, 90.0, true, 10.0, 1.0,
                     state.lastPacketMs},
                    9000);
  const map_presentation::PresentedPose delayedDrain = presenter.present(9000);
  assert(delayedDrain.observationAgeMs == 4000);
  assert(delayedDrain.predictionExhausted);

  // Unsigned monotonic deltas remain valid across the millis() wrap, and an
  // accepted packet at timestamp zero is represented by count, not a sentinel.
  ArrivalBatch beforeWrap;
  beforeWrap.observe(std::numeric_limits<uint32_t>::max() - 500U);
  State wrapState;
  wrapState.accept(beforeWrap);
  ArrivalBatch afterWrap;
  afterWrap.observe(500U);
  wrapState.accept(afterWrap);
  assert(wrapState.packetCount == 2);
  assert(wrapState.lastGapMs == 1001U);
  assert(wrapState.maximumGapMs == 1001U);
  assert(gps_position_protocol::capturedAtMs(500U, 1'000U) ==
         std::numeric_limits<uint32_t>::max() - 499U);

  GpsRideObservation hardware{};
  hardware.source = RidePositionSource::HardwareNmea;
  hardware.fixAvailable = true;
  hardware.fixValid = true;
  hardware.speedAvailable = true;
  hardware.speedMetersPerSecond = 3.0F;
  hardware.locationAvailable = true;
  hardware.latitude = 1.0;
  hardware.longitude = 2.0;
  hardware.horizontalUncertaintyAvailable = true;
  hardware.horizontalUncertaintyMeters = 10.0F;
  hardware.capturedAtMs = 9'000;
  GpsRideObservation phone = hardware;
  phone.source = RidePositionSource::AuthenticatedBle;
  phone.horizontalUncertaintyMeters = 5.0F;
  phone.capturedAtMs = 8'500;
  assert(selectGpsRideObservation(hardware, phone, 10'000, 3'000).source ==
         RidePositionSource::AuthenticatedBle);
  phone.fixValid = false;
  assert(selectGpsRideObservation(hardware, phone, 10'000, 3'000).source ==
         RidePositionSource::HardwareNmea);
  hardware.capturedAtMs = 1'000;
  phone.capturedAtMs = 2'000;
  assert(selectGpsRideObservation(hardware, phone, 10'000, 3'000).source ==
         RidePositionSource::None);

  // Selection returns a complete source sample; fields from the losing slot
  // are never combined with the winner.
  phone = hardware;
  phone.source = RidePositionSource::AuthenticatedBle;
  phone.fixValid = true;
  phone.capturedAtMs = 9'500;
  phone.speedMetersPerSecond = 0.0F;
  phone.horizontalUncertaintyMeters = 4.0F;
  const GpsRideObservation selected =
      selectGpsRideObservation(hardware, phone, 10'000, 3'000);
  assert(selected.source == RidePositionSource::AuthenticatedBle);
  assert(selected.speedMetersPerSecond == 0.0F);
  assert(selected.horizontalUncertaintyMeters == 4.0F);

  return 0;
}
