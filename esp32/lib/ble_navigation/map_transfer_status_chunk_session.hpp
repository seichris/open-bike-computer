#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace map_transfer_status_protocol {

struct ActiveMapPresentation {
  std::string displayName;
  std::array<int32_t, 4> boundsE7 = {};
  bool hasBoundsE7 = false;
};

inline std::string jsonEscape(const std::string &value) {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string output;
  output.reserve(value.size() + 8);
  for (const unsigned char character : value) {
    switch (character) {
    case '"':
      output += "\\\"";
      break;
    case '\\':
      output += "\\\\";
      break;
    case '\b':
      output += "\\b";
      break;
    case '\f':
      output += "\\f";
      break;
    case '\n':
      output += "\\n";
      break;
    case '\r':
      output += "\\r";
      break;
    case '\t':
      output += "\\t";
      break;
    default:
      if (character < 0x20) {
        output += "\\u00";
        output.push_back(kHex[character >> 4]);
        output.push_back(kHex[character & 0x0f]);
      } else {
        output.push_back(static_cast<char>(character));
      }
      break;
    }
  }
  return output;
}

inline void appendActiveMapPresentation(std::string &body,
                                        const ActiveMapPresentation &value) {
  if (!value.displayName.empty()) {
    body += ",\"activeMapDisplayName\":\"" +
            jsonEscape(value.displayName) + "\"";
  }
  if (value.hasBoundsE7) {
    body += ",\"activeMapBoundsE7\":[" +
            std::to_string(value.boundsE7[0]) + "," +
            std::to_string(value.boundsE7[1]) + "," +
            std::to_string(value.boundsE7[2]) + "," +
            std::to_string(value.boundsE7[3]) + "]";
  }
}

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
