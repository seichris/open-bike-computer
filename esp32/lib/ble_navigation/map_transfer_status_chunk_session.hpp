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
// status payloads carry a seven-byte MSTC header. Keep the body portion at or
// below the 128-byte size already used by the generic transfer-status path.
// Some iOS/NimBLE links negotiate a larger ATT MTU but do not reliably deliver
// notifications that consume that exact limit. The conservative ceiling keeps
// headroom while the bounded continuation queue still supports larger status
// snapshots without blocking the NimBLE host task.
constexpr size_t chunkPayloadBytes(uint16_t peerMtu) {
  constexpr size_t kAttNotificationOverhead = 3;
  constexpr size_t kAuthenticatedEnvelopeOverhead = 22;
  constexpr size_t kChunkHeaderBytes = 7;
  constexpr size_t kMaximumChunkPayloadBytes = 128;
  constexpr size_t kTotalOverhead = kAttNotificationOverhead +
                                    kAuthenticatedEnvelopeOverhead +
                                    kChunkHeaderBytes;
  if (peerMtu <= kTotalOverhead) {
    return 0;
  }
  const size_t mtuPayloadBytes = peerMtu - kTotalOverhead;
  return mtuPayloadBytes < kMaximumChunkPayloadBytes
             ? mtuPayloadBytes
             : kMaximumChunkPayloadBytes;
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

// A map-status response can exceed the fixed deferred-notification queue even
// after it is split for the negotiated ATT MTU. Keep the plaintext chunk
// stream on the Arduino owner task and advance it only after each protected
// frame is accepted by that queue. The NimBLE host task can then drain one
// bounded batch before the owner task pumps the next one.
class ChunkTransmission {
public:
  bool begin(const std::string &body, uint8_t transferId,
             size_t chunkPayloadBytes) {
    reset();
    if (body.empty() || chunkPayloadBytes == 0) {
      return false;
    }
    const size_t count =
        (body.size() + chunkPayloadBytes - 1) / chunkPayloadBytes;
    if (count == 0 || count > 255) {
      return false;
    }
    body_ = body;
    transferId_ = transferId;
    chunkPayloadBytes_ = chunkPayloadBytes;
    chunkCount_ = count;
    active_ = true;
    return true;
  }

  bool matches(const std::string &body, uint8_t transferId,
               size_t chunkPayloadBytes) const {
    return active_ && body_ == body && transferId_ == transferId &&
           chunkPayloadBytes_ == chunkPayloadBytes;
  }

  bool active() const { return active_; }
  size_t bodySize() const { return body_.size(); }
  size_t chunkCount() const { return chunkCount_; }
  size_t nextIndex() const { return nextIndex_; }

  std::string nextFrame(const char *prefix = "MSTC") const {
    if (!active_ || nextIndex_ >= chunkCount_ || prefix == nullptr ||
        std::char_traits<char>::length(prefix) != 4) {
      return {};
    }
    const size_t offset = nextIndex_ * chunkPayloadBytes_;
    const size_t remaining = body_.size() - offset;
    const size_t length =
        remaining < chunkPayloadBytes_ ? remaining : chunkPayloadBytes_;
    std::string frame(prefix, 4);
    frame.push_back(static_cast<char>(transferId_));
    frame.push_back(static_cast<char>(nextIndex_));
    frame.push_back(static_cast<char>(chunkCount_));
    frame.append(body_.data() + offset, length);
    return frame;
  }

  void advance() {
    if (!active_) {
      return;
    }
    ++nextIndex_;
    if (nextIndex_ >= chunkCount_) {
      active_ = false;
    }
  }

  void reset() {
    body_.clear();
    transferId_ = 0;
    chunkPayloadBytes_ = 0;
    chunkCount_ = 0;
    nextIndex_ = 0;
    active_ = false;
  }

private:
  std::string body_;
  uint8_t transferId_ = 0;
  size_t chunkPayloadBytes_ = 0;
  size_t chunkCount_ = 0;
  size_t nextIndex_ = 0;
  bool active_ = false;
};

} // namespace map_transfer_status_protocol
