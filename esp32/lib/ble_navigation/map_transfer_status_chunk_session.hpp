#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace map_transfer_status_protocol {

// ATT notifications reserve three bytes for the protocol header. Each
// authenticated notification then adds a 22-byte envelope, and chunked map
// status payloads carry a seven-byte MSTC header. Size the body portion from
// the peer's negotiated MTU so modern centrals receive a status snapshot in as
// few notifications as possible without exceeding the transport limit.
constexpr size_t chunkPayloadBytes(uint16_t peerMtu) {
  constexpr size_t kAttNotificationOverhead = 3;
  constexpr size_t kAuthenticatedEnvelopeOverhead = 22;
  constexpr size_t kChunkHeaderBytes = 7;
  constexpr size_t kTotalOverhead = kAttNotificationOverhead +
                                    kAuthenticatedEnvelopeOverhead +
                                    kChunkHeaderBytes;
  return peerMtu > kTotalOverhead ? peerMtu - kTotalOverhead : 0;
}

// Repeated status requests must retransmit the same logical chunk stream.
// Keeping the transfer ID stable while the body is unchanged lets a central
// fill gaps from later retransmissions instead of discarding every partial
// response when an ATT notification is lost.
class ChunkSession {
public:
  uint8_t transferIdFor(const std::string &body) {
    if (!hasBody_ || body != body_) {
      body_ = body;
      hasBody_ = true;
      ++transferId_;
    }
    return transferId_;
  }

private:
  std::string body_;
  uint8_t transferId_ = 0;
  bool hasBody_ = false;
};

} // namespace map_transfer_status_protocol
