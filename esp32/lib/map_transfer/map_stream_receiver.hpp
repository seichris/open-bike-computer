#pragma once

#include "map_stream_install.hpp"

#include <memory>
#include <string>

namespace map_transfer {

struct MapStreamReceiveResult {
  bool ok = false;
  int httpStatus = 500;
  std::string code;
  std::string message;
};

// Transport-independent owner for one HTTP body. Networking feeds arbitrary
// chunks; this object owns the SHA context, parser, and durable inactive-root
// writer until exact end-of-body confirmation.
class MapStreamReceiver final {
public:
  MapStreamReceiver(const MapStreamTrustStore &trustStore,
                    std::string storageRoot, std::string sessionId,
                    uint64_t contentLength, std::string firmwareVersion,
                    size_t maximumWorkingBytes,
                    MapStreamCheckpointPolicy checkpointPolicy = {},
                    MapStreamNowCallback now = {},
                    std::shared_ptr<MapStreamStorage> storage = {},
                    MapStreamStatusCallback onStatus = {},
                    std::string operationID = {});

  bool feed(const uint8_t *data, size_t size);
  bool readyToFinish() const;
  MapStreamReceiveResult abort();
  MapStreamReceiveResult finish();
  const MapStreamInstallSnapshot &snapshot() const;
  uint64_t receivedBytes() const;
  bool failed() const;

private:
  MbedTlsMapStreamSha256 hasher_;
  MapStreamInstallSession installer_;
  MapStreamIncrementalParser parser_;

  MapStreamReceiveResult result() const;
};

} // namespace map_transfer
