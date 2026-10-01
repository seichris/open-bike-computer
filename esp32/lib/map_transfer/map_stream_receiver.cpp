#include "map_stream_receiver.hpp"

#include <utility>

namespace map_transfer {

MapStreamReceiver::MapStreamReceiver(
    const MapStreamTrustStore &trustStore, std::string storageRoot,
    std::string sessionId, uint64_t contentLength, std::string firmwareVersion,
    size_t maximumWorkingBytes,
    MapStreamCheckpointPolicy checkpointPolicy, MapStreamNowCallback now,
    std::shared_ptr<MapStreamStorage> storage,
    MapStreamStatusCallback onStatus, std::string operationID)
    : installer_(std::move(storageRoot), std::move(sessionId), checkpointPolicy,
                 std::move(now), std::move(storage), std::move(onStatus), std::move(operationID)),
      parser_(trustStore, hasher_, installer_,
              {contentLength, std::move(firmwareVersion),
               maximumWorkingBytes}) {}

bool MapStreamReceiver::feed(const uint8_t *data, size_t size) {
  return parser_.feed(data, size);
}

bool MapStreamReceiver::readyToFinish() const {
  const auto &state = installer_.snapshot();
  return parser_.readyToFinish() && state.completedFiles == state.totalFiles &&
         state.completedPayloadBytes == state.totalPayloadBytes;
}

MapStreamReceiveResult MapStreamReceiver::abort() {
  parser_.abort();
  return result();
}

MapStreamReceiveResult MapStreamReceiver::finish() {
  if (!parser_.failed())
    parser_.finish();
  return result();
}

const MapStreamInstallSnapshot &MapStreamReceiver::snapshot() const {
  return installer_.snapshot();
}

uint64_t MapStreamReceiver::receivedBytes() const {
  return parser_.receivedBytes();
}

bool MapStreamReceiver::failed() const { return parser_.failed(); }

MapStreamReceiveResult MapStreamReceiver::result() const {
  if (parser_.complete())
    return {true, 200, "stream_ready", ""};

  const MapStreamInstallSnapshot &state = installer_.snapshot();
  if (state.state == MapStreamInstallState::Paused) {
    return {false, 408, state.errorCode.empty() ? "stream_paused"
                                                : state.errorCode,
            state.errorMessage};
  }
  if (!state.errorCode.empty() &&
      (parser_.error() == MapStreamParserError::ConsumerRejected ||
       parser_.error() == MapStreamParserError::ResourceUnavailable)) {
    return {false, parser_.error() == MapStreamParserError::ResourceUnavailable
                       ? 503
                       : 500,
            state.errorCode, state.errorMessage};
  }
  const std::string code = parser_.errorCode();
  return {false,
          parser_.error() == MapStreamParserError::ResourceUnavailable ? 503
                                                                        : 400,
          code.empty() ? "stream_invalid" : code,
          "map stream validation failed"};
}

} // namespace map_transfer
