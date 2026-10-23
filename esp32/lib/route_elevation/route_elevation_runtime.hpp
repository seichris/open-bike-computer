#pragma once

#include "route_elevation_protocol.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace route_elevation_runtime {

// Immutable copy for the LVGL task. Revision 0 means "never published".
struct Snapshot {
  uint32_t revision = 0;
  route_elevation_protocol::Session::Binding binding{};
  bool hasProfile = false;
  route_elevation_protocol::Profile profile{};
  bool hasProgress = false;
  route_elevation_protocol::Progress progress{};
};

// Allocates the PSRAM session state; the capability is advertised only after this succeeds.
bool ready();
// Called from the authenticated BLE write path. Returns true when the frame
// was an ELV1 frame (handled or rejected); false leaves it to other parsers.
bool ingest(const uint8_t *data, std::size_t length, uint32_t nowMs);
// Owner task: pop one pending EAK1 acknowledgement.
bool takeAcknowledgement(std::array<uint8_t, route_elevation_protocol::ACK_BYTES> &out);
// LVGL task: copy only when the published revision differs from `known`.
bool snapshotIfChanged(uint32_t known, Snapshot &out);
uint32_t revision();
// Session boundary (disconnect, authentication change): forget all route state.
void reset();

} // namespace route_elevation_runtime
