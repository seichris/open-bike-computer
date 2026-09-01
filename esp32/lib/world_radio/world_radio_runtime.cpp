#include "world_radio_runtime.hpp"

#include <atomic>
#include <cstring>
#include <freertos/FreeRTOS.h>
#include <freertos/portmacro.h>

namespace world_radio_runtime {
namespace {

portMUX_TYPE runtimeMux = portMUX_INITIALIZER_UNLOCKED;
Snapshot runtimeState{};
std::atomic<uint32_t> nextRequest{1};

void advanceRevisionLocked() {
  ++runtimeState.revision;
  if (runtimeState.revision == 0) {
    runtimeState.revision = 1;
  }
}

template <std::size_t Size>
void copyLiteral(char (&destination)[Size], const char *text) {
  static_assert(Size > 0, "text buffers require a terminator");
  std::memset(destination, 0, Size);
  if (text == nullptr) {
    return;
  }
  std::strncpy(destination, text, Size - 1);
}

} // namespace

uint32_t nextRequestId() {
  uint32_t requestId = nextRequest.fetch_add(1, std::memory_order_relaxed);
  if (requestId == 0) {
    requestId = nextRequest.fetch_add(1, std::memory_order_relaxed);
  }
  return requestId;
}

void noteRequest(const world_radio_protocol::Request &request) {
  portENTER_CRITICAL(&runtimeMux);
  runtimeState.request = request;
  runtimeState.status.requestId = request.requestId;
  switch (request.command) {
  case world_radio_protocol::Command::SelectLocation:
  case world_radio_protocol::Command::RandomStation:
    runtimeState.status = {};
    runtimeState.status.requestId = request.requestId;
    runtimeState.status.state = world_radio_protocol::PlaybackState::Searching;
    copyLiteral(runtimeState.status.message, "Finding stations");
    break;
  case world_radio_protocol::Command::Stop:
    runtimeState.status.state = world_radio_protocol::PlaybackState::Idle;
    copyLiteral(runtimeState.status.message, "Stopped");
    break;
  case world_radio_protocol::Command::PlayPause:
  case world_radio_protocol::Command::PreviousStation:
  case world_radio_protocol::Command::NextStation:
    break;
  }
  advanceRevisionLocked();
  portEXIT_CRITICAL(&runtimeMux);
}

void noteTransportUnavailable(const world_radio_protocol::Request &request) {
  portENTER_CRITICAL(&runtimeMux);
  runtimeState.request = request;
  runtimeState.status.requestId = request.requestId;
  runtimeState.status.state = world_radio_protocol::PlaybackState::Error;
  copyLiteral(runtimeState.status.message, "Connect iPhone");
  advanceRevisionLocked();
  portEXIT_CRITICAL(&runtimeMux);
}

bool ingestStatus(const uint8_t *data, std::size_t length) {
  world_radio_protocol::Status decoded{};
  if (!world_radio_protocol::decodeStatus(data, length, decoded)) {
    return false;
  }

  portENTER_CRITICAL(&runtimeMux);
  if (runtimeState.request.requestId != 0 &&
      decoded.requestId != runtimeState.request.requestId) {
    portEXIT_CRITICAL(&runtimeMux);
    return false;
  }
  runtimeState.status = decoded;
  advanceRevisionLocked();
  portEXIT_CRITICAL(&runtimeMux);
  return true;
}

Snapshot snapshot() {
  portENTER_CRITICAL(&runtimeMux);
  const Snapshot copy = runtimeState;
  portEXIT_CRITICAL(&runtimeMux);
  return copy;
}

void reset() {
  portENTER_CRITICAL(&runtimeMux);
  runtimeState = {};
  advanceRevisionLocked();
  portEXIT_CRITICAL(&runtimeMux);
}

} // namespace world_radio_runtime
