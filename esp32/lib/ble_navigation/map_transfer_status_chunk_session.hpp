#pragma once

#include <cstdint>
#include <string>

namespace map_transfer_status_protocol {

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
