#pragma once

#include "route_elevation_config.hpp"
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

#if ROUTE_ELEVATION_SCREEN_ENABLED
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
#else
// Builds without the Elevation screen (production, 2.06-inch) carry no route
// elevation session code or state; production images keep their flash reserve.
inline bool ready() { return false; }
inline bool ingest(const uint8_t *, std::size_t, uint32_t) { return false; }
inline bool takeAcknowledgement(std::array<uint8_t, route_elevation_protocol::ACK_BYTES> &) { return false; }
inline bool snapshotIfChanged(uint32_t, Snapshot &) { return false; }
inline uint32_t revision() { return 0; }
inline void reset() {}
#endif

} // namespace route_elevation_runtime
