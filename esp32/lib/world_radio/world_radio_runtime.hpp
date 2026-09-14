#pragma once

#include "world_radio_protocol.hpp"

#include <cstddef>
#include <cstdint>

namespace world_radio_runtime {

struct Snapshot {
  uint32_t revision = 0;
  world_radio_protocol::Request request{};
  world_radio_protocol::Status status{};
};

uint32_t nextRequestId();
void noteRequest(const world_radio_protocol::Request &request);
void noteTransportUnavailable(const world_radio_protocol::Request &request);
bool ingestStatus(const uint8_t *data, std::size_t length);
Snapshot snapshot();
void reset();

} // namespace world_radio_runtime
