#pragma once

#include "gps_position_protocol.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace gps_input_freshness {

/** Arrival timing retained by the latest-state GPS mailbox.
 *
 * The payload itself may be replaced while the UI task is busy, but every
 * valid authenticated packet still contributes to transport cadence. Keeping
 * this summary beside the newest payload lets the UI apply only the latest fix
 * without confusing mailbox delay with a missing BLE heartbeat.
 */
struct ArrivalBatch {
  uint32_t packetCount = 0;
  uint32_t firstPacketMs = 0;
  uint32_t lastPacketMs = 0;
  uint32_t lastGapMs = 0;
  uint32_t maximumGapMs = 0;

  void observe(uint32_t receivedAtMs) {
    if (packetCount == 0) {
      firstPacketMs = receivedAtMs;
    } else {
      lastGapMs = receivedAtMs - lastPacketMs;
      maximumGapMs = std::max(maximumGapMs, lastGapMs);
    }
    lastPacketMs = receivedAtMs;
    ++packetCount;
  }
};

/** Validate at BLE ingress without mutating renderer-owned GPS state. */
inline bool acceptsPayload(const uint8_t *data, std::size_t length) {
  gps_position_protocol::Packet packet{};
  return gps_position_protocol::decode(data, length, packet);
}

/** Cumulative accepted-packet timing, updated when a mailbox batch drains. */
struct State {
  bool hasPacket = false;
  uint32_t packetCount = 0;
  uint32_t lastPacketMs = 0;
  uint32_t lastGapMs = 0;
  uint32_t maximumGapMs = 0;

  void accept(const ArrivalBatch &batch) {
    if (batch.packetCount == 0)
      return;

    const bool hadPacket = hasPacket;
    const uint32_t boundaryGapMs =
        hadPacket ? batch.firstPacketMs - lastPacketMs : 0U;
    if (hadPacket)
      maximumGapMs = std::max(maximumGapMs, boundaryGapMs);
    maximumGapMs = std::max(maximumGapMs, batch.maximumGapMs);

    if (batch.packetCount > 1) {
      lastGapMs = batch.lastGapMs;
    } else {
      lastGapMs = hadPacket ? boundaryGapMs : 0U;
    }
    packetCount += batch.packetCount;
    lastPacketMs = batch.lastPacketMs;
    hasPacket = true;
  }
};

} // namespace gps_input_freshness
