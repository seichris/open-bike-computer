#pragma once

// Route elevation profile transport (ELV1) and device-side session state.
//
// The phone owns profile retrieval, processing, statistics and route
// matching. The device only stages, validates and atomically activates the
// compact display profile, then positions a marker from the phone's progress
// and shows the phone-computed values. Nothing here derives ascent or grade.
// See docs/route-elevation-profile.md and docs/ble-protocol.md.

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "../ble_navigation/ride_ble_protocol.generated.hpp"
#include "../utils/src/wireBytes.hpp"

namespace route_elevation_protocol {

inline constexpr auto &FRAME_MAGIC = ride_ble_protocol_generated::ROUTE_ELEVATION_MAGIC;
inline constexpr auto &ACK_MAGIC = ride_ble_protocol_generated::ROUTE_ELEVATION_ACK_MAGIC;
inline constexpr uint8_t FRAME_VERSION = 1;
inline constexpr uint8_t BODY_VERSION = 1;
inline constexpr std::size_t FRAME_HEADER_BYTES = 6;
inline constexpr std::size_t STATE_FRAME_BYTES = 14;
inline constexpr std::size_t BEGIN_FRAME_BYTES = 22;
inline constexpr std::size_t CHUNK_HEADER_BYTES = 9;
inline constexpr std::size_t COMMIT_FRAME_BYTES = 8;
inline constexpr std::size_t PROGRESS_FRAME_BYTES = 26;
inline constexpr std::size_t ACK_BYTES = 16;
inline constexpr std::size_t BODY_HEADER_BYTES = 32;
inline constexpr std::size_t POINT_BYTES = 7;
inline constexpr std::size_t MINIMUM_POINTS = 2;
inline constexpr std::size_t MAXIMUM_POINTS = 192;
inline constexpr std::size_t MAXIMUM_BODY_BYTES = BODY_HEADER_BYTES + POINT_BYTES * MAXIMUM_POINTS;
inline constexpr uint8_t MAXIMUM_CHUNKS = 64;
inline constexpr uint32_t TRANSFER_TIMEOUT_MS = 10000;
inline constexpr int16_t UNKNOWN_ELEVATION = INT16_MIN;
inline constexpr int16_t MINIMUM_ELEVATION_M = -500;
inline constexpr int16_t MAXIMUM_ELEVATION_M = 9000;
inline constexpr uint32_t UNKNOWN_PROGRESS = UINT32_MAX;

inline constexpr uint8_t BODY_FLAG_STATS_COMPLETE = 1U << 0;
inline constexpr uint8_t BODY_FLAG_INCLUDES_ESTIMATED = 1U << 1;
inline constexpr uint8_t BODY_FLAG_PARTIAL = 1U << 2;
inline constexpr uint8_t BODY_FLAG_AMBIGUOUS_STRUCTURES = 1U << 3;
inline constexpr uint8_t BODY_FLAG_ASCENT_VALID = 1U << 4;
inline constexpr uint8_t BODY_FLAG_RANGE_VALID = 1U << 5;
inline constexpr uint8_t BODY_FLAGS_KNOWN = 0x3F;

inline constexpr uint8_t POINT_GRADE_BAND_MASK = 0x07;
inline constexpr uint8_t POINT_FLAG_ESTIMATED = 1U << 3;
inline constexpr uint8_t POINT_FLAG_LOW_CONFIDENCE = 1U << 4;
inline constexpr uint8_t POINT_FLAG_STRUCTURE = 1U << 5;
inline constexpr uint8_t POINT_FLAGS_KNOWN = 0x3F;

inline constexpr uint8_t PROGRESS_ON_ROUTE = 1U << 0;
inline constexpr uint8_t PROGRESS_ELEVATION_VALID = 1U << 1;
inline constexpr uint8_t PROGRESS_ELEVATION_ESTIMATED = 1U << 2;
inline constexpr uint8_t PROGRESS_GRADE_VALID = 1U << 3;
inline constexpr uint8_t PROGRESS_GRADE_ESTIMATED = 1U << 4;
inline constexpr uint8_t PROGRESS_ASCENT_REMAINING_VALID = 1U << 5;
inline constexpr uint8_t PROGRESS_ASCENT_REMAINING_LOWER_BOUND = 1U << 6;
inline constexpr uint8_t PROGRESS_FLAGS_KNOWN = 0x7F;

enum class Op : uint8_t { State = 1, Begin = 2, Chunk = 3, Commit = 4, Progress = 5 };

// Wire states 0...3 come from the phone. Ready is internal: a committed profile.
enum class ProfileState : uint8_t { Cleared = 0, Loading = 1, Unavailable = 2, Failed = 3, Ready = 4 };

enum class Reason : uint8_t {
  Unspecified = 0,
  Offline = 1,
  SourceNotPermitted = 2,
  ServiceUnavailable = 3,
  QuotaExhausted = 4,
  NoCoverage = 5,
  TransferFailed = 6,
  RouteTooLong = 7,
};
inline constexpr uint8_t MAXIMUM_REASON = 7;

enum class Result : uint8_t {
  Applied = 0,
  Stale = 1,
  Malformed = 2,
  CrcMismatch = 3,
  Incomplete = 4,
  Unsupported = 5,
};

enum class Source : uint8_t { Unknown = 0, Gpx = 1, HostedTerrain = 2, InternalDem = 3 };

struct Point {
  uint32_t distanceM = 0;
  int16_t elevationM = UNKNOWN_ELEVATION;
  uint8_t flags = 0;
};

struct Profile {
  uint32_t routeToken = 0;
  uint16_t revision = 0;
  uint8_t flags = 0;
  uint8_t source = 0;
  uint8_t pointCount = 0;
  uint16_t coveragePermille = 0;
  uint16_t estimatedPermille = 0;
  uint32_t totalDistanceM = 0;
  uint32_t totalAscentM = 0;
  uint32_t totalDescentM = 0;
  int16_t minimumElevationM = 0;
  int16_t maximumElevationM = 0;
  std::array<Point, MAXIMUM_POINTS> points{};
};

struct Progress {
  uint16_t sequence = 0;
  uint32_t progressM = UNKNOWN_PROGRESS;
  uint8_t flags = 0;
  int16_t elevationM = 0;
  int16_t gradeDeciPercent = 0;
  uint16_t ascentRemainingM = 0;

  bool operator==(const Progress &other) const {
    return sequence == other.sequence && progressM == other.progressM && flags == other.flags &&
           elevationM == other.elevationM && gradeDeciPercent == other.gradeDeciPercent &&
           ascentRemainingM == other.ascentRemainingM;
  }
  bool operator!=(const Progress &other) const { return !(*this == other); }
};

struct Frame {
  Op op = Op::State;
  uint32_t routeToken = 0;
  uint16_t revision = 0;
  ProfileState state = ProfileState::Cleared;
  Reason reason = Reason::Unspecified;
  uint16_t transferId = 0;
  uint16_t bodyLength = 0;
  uint8_t chunkCount = 0;
  uint8_t chunkIndex = 0;
  uint32_t crc32 = 0;
  const uint8_t *payload = nullptr;
  std::size_t payloadLength = 0;
  Progress progress{};
};

inline uint32_t crc32(const uint8_t *data, std::size_t length) {
  uint32_t crc = 0xFFFFFFFFu;
  for (std::size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return crc ^ 0xFFFFFFFFu;
}

inline bool hasFrameMagic(const uint8_t *data, std::size_t length) {
  return data != nullptr && length >= 4 && std::memcmp(data, FRAME_MAGIC, 4) == 0;
}

inline int16_t readI16(const uint8_t *input) {
  return static_cast<int16_t>(wire_bytes::readU16(input));
}

inline bool validElevation(int16_t value) {
  return value == UNKNOWN_ELEVATION || (value >= MINIMUM_ELEVATION_M && value <= MAXIMUM_ELEVATION_M);
}

inline bool decodeFrame(const uint8_t *data, std::size_t length, Frame &out) {
  if (!hasFrameMagic(data, length) || length < FRAME_HEADER_BYTES || data[4] != FRAME_VERSION) {
    return false;
  }
  Frame frame{};
  const uint8_t *body = data + FRAME_HEADER_BYTES;
  switch (data[5]) {
  case static_cast<uint8_t>(Op::State):
    if (length != STATE_FRAME_BYTES || body[6] > static_cast<uint8_t>(ProfileState::Failed) ||
        body[7] > MAXIMUM_REASON) {
      return false;
    }
    frame.op = Op::State;
    frame.routeToken = wire_bytes::readU32(body);
    frame.revision = wire_bytes::readU16(body + 4);
    frame.state = static_cast<ProfileState>(body[6]);
    frame.reason = static_cast<Reason>(body[7]);
    if (frame.state != ProfileState::Cleared && (frame.routeToken == 0 || frame.revision == 0)) {
      return false;
    }
    break;
  case static_cast<uint8_t>(Op::Begin):
    if (length != BEGIN_FRAME_BYTES || body[11] != 0) {
      return false;
    }
    frame.op = Op::Begin;
    frame.routeToken = wire_bytes::readU32(body);
    frame.revision = wire_bytes::readU16(body + 4);
    frame.transferId = wire_bytes::readU16(body + 6);
    frame.bodyLength = wire_bytes::readU16(body + 8);
    frame.chunkCount = body[10];
    frame.crc32 = wire_bytes::readU32(body + 12);
    if (frame.routeToken == 0 || frame.revision == 0 || frame.transferId == 0 ||
        frame.bodyLength < BODY_HEADER_BYTES + POINT_BYTES * MINIMUM_POINTS ||
        frame.bodyLength > MAXIMUM_BODY_BYTES || frame.chunkCount == 0 ||
        frame.chunkCount > MAXIMUM_CHUNKS || frame.chunkCount > frame.bodyLength) {
      return false;
    }
    break;
  case static_cast<uint8_t>(Op::Chunk):
    if (length <= CHUNK_HEADER_BYTES) {
      return false;
    }
    frame.op = Op::Chunk;
    frame.transferId = wire_bytes::readU16(body);
    frame.chunkIndex = body[2];
    frame.payload = data + CHUNK_HEADER_BYTES;
    frame.payloadLength = length - CHUNK_HEADER_BYTES;
    if (frame.transferId == 0) {
      return false;
    }
    break;
  case static_cast<uint8_t>(Op::Commit):
    if (length != COMMIT_FRAME_BYTES) {
      return false;
    }
    frame.op = Op::Commit;
    frame.transferId = wire_bytes::readU16(body);
    if (frame.transferId == 0) {
      return false;
    }
    break;
  case static_cast<uint8_t>(Op::Progress):
    // token u32, revision u16, sequence u16, progress u32, flags u8,
    // reserved u8, elevation i16, grade i16 (0.1 %), ascent remaining u16.
    if (length != PROGRESS_FRAME_BYTES || body[13] != 0 || (body[12] & ~PROGRESS_FLAGS_KNOWN) != 0) {
      return false;
    }
    frame.op = Op::Progress;
    frame.routeToken = wire_bytes::readU32(body);
    frame.revision = wire_bytes::readU16(body + 4);
    frame.progress.sequence = wire_bytes::readU16(body + 6);
    frame.progress.progressM = wire_bytes::readU32(body + 8);
    frame.progress.flags = body[12];
    frame.progress.elevationM = readI16(body + 14);
    frame.progress.gradeDeciPercent = readI16(body + 16);
    frame.progress.ascentRemainingM = wire_bytes::readU16(body + 18);
    if (frame.routeToken == 0 || frame.revision == 0) {
      return false;
    }
    if ((frame.progress.flags & PROGRESS_ELEVATION_VALID) != 0 &&
        (frame.progress.elevationM < MINIMUM_ELEVATION_M || frame.progress.elevationM > MAXIMUM_ELEVATION_M)) {
      return false;
    }
    if ((frame.progress.flags & PROGRESS_GRADE_VALID) != 0 &&
        (frame.progress.gradeDeciPercent < -1000 || frame.progress.gradeDeciPercent > 1000)) {
      return false;
    }
    break;
  default:
    return false;
  }
  out = frame;
  return true;
}

inline bool decodeBody(const uint8_t *data, std::size_t length, Profile &out) {
  if (data == nullptr || length < BODY_HEADER_BYTES || data[0] != BODY_VERSION ||
      (data[1] & ~BODY_FLAGS_KNOWN) != 0) {
    return false;
  }
  const uint8_t count = data[3];
  if (count < MINIMUM_POINTS || count > MAXIMUM_POINTS ||
      length != BODY_HEADER_BYTES + POINT_BYTES * static_cast<std::size_t>(count)) {
    return false;
  }
  Profile profile{};
  profile.flags = data[1];
  profile.source = data[2];
  profile.pointCount = count;
  profile.routeToken = wire_bytes::readU32(data + 4);
  profile.revision = wire_bytes::readU16(data + 8);
  profile.coveragePermille = wire_bytes::readU16(data + 10);
  profile.totalDistanceM = wire_bytes::readU32(data + 12);
  profile.totalAscentM = wire_bytes::readU32(data + 16);
  profile.totalDescentM = wire_bytes::readU32(data + 20);
  profile.minimumElevationM = readI16(data + 24);
  profile.maximumElevationM = readI16(data + 26);
  profile.estimatedPermille = wire_bytes::readU16(data + 28);
  if (profile.routeToken == 0 || profile.revision == 0 || profile.totalDistanceM == 0 ||
      profile.coveragePermille > 1000 || profile.estimatedPermille > 1000 ||
      wire_bytes::readU16(data + 30) != 0) {
    return false;
  }
  if ((profile.flags & BODY_FLAG_RANGE_VALID) != 0 &&
      (profile.minimumElevationM > profile.maximumElevationM ||
       profile.minimumElevationM < MINIMUM_ELEVATION_M ||
       profile.maximumElevationM > MAXIMUM_ELEVATION_M)) {
    return false;
  }
  uint32_t previous = 0;
  for (std::size_t index = 0; index < count; ++index) {
    const uint8_t *point = data + BODY_HEADER_BYTES + index * POINT_BYTES;
    Point decoded{};
    decoded.distanceM = wire_bytes::readU32(point);
    decoded.elevationM = readI16(point + 4);
    decoded.flags = point[6];
    if ((decoded.flags & ~POINT_FLAGS_KNOWN) != 0 || !validElevation(decoded.elevationM) ||
        decoded.distanceM < previous || decoded.distanceM > profile.totalDistanceM) {
      return false;
    }
    previous = decoded.distanceM;
    profile.points[index] = decoded;
  }
  if (profile.points[0].distanceM != 0 || profile.points[count - 1].distanceM != profile.totalDistanceM) {
    return false;
  }
  out = profile;
  return true;
}

inline void encodeAck(Op op, Result result, uint32_t routeToken, uint16_t revision, uint16_t transferId,
                      std::array<uint8_t, ACK_BYTES> &out) {
  out.fill(0);
  std::memcpy(out.data(), ACK_MAGIC, 4);
  out[4] = FRAME_VERSION;
  out[5] = static_cast<uint8_t>(op);
  out[6] = static_cast<uint8_t>(result);
  out[7] = 0;
  wire_bytes::writeU32(out.data() + 8, routeToken);
  wire_bytes::writeU16(out.data() + 12, revision);
  wire_bytes::writeU16(out.data() + 14, transferId);
}

class Session {
public:
  struct Binding {
    uint32_t routeToken = 0;
    uint16_t revision = 0;
    ProfileState state = ProfileState::Cleared;
    Reason reason = Reason::Unspecified;
  };

  struct Outcome {
    bool recognized = false;
    bool changed = false;
    bool hasAck = false;
    std::array<uint8_t, ACK_BYTES> ack{};
  };

  Outcome handle(const uint8_t *data, std::size_t length, uint32_t nowMs) {
    Outcome outcome{};
    if (!hasFrameMagic(data, length)) {
      return outcome;
    }
    outcome.recognized = true;
    expire(nowMs);
    Frame frame{};
    if (!decodeFrame(data, length, frame)) {
      if (length >= FRAME_HEADER_BYTES && data[4] != FRAME_VERSION) {
        outcome.hasAck = true;
        encodeAck(Op::State, Result::Unsupported, binding_.routeToken, binding_.revision, 0, outcome.ack);
      } else if (length >= FRAME_HEADER_BYTES + 2 &&
                 (data[5] == static_cast<uint8_t>(Op::Begin) || data[5] == static_cast<uint8_t>(Op::Commit))) {
        // Tell the sender to stop instead of waiting for its acknowledgement timeout.
        const bool isBegin = data[5] == static_cast<uint8_t>(Op::Begin);
        uint16_t transferId = 0;
        if (!isBegin) {
          transferId = wire_bytes::readU16(data + FRAME_HEADER_BYTES);
        } else if (length >= FRAME_HEADER_BYTES + 8) {
          transferId = wire_bytes::readU16(data + FRAME_HEADER_BYTES + 6);
        }
        if (isBegin) {
          clearStaging();
        }
        outcome.hasAck = true;
        encodeAck(static_cast<Op>(data[5]), Result::Malformed, binding_.routeToken, binding_.revision,
                  transferId, outcome.ack);
      }
      return outcome;
    }
    switch (frame.op) {
    case Op::State:
      outcome.changed = applyState(frame);
      break;
    case Op::Begin:
      outcome.changed = begin(frame, nowMs);
      outcome.hasAck = true;
      encodeAck(Op::Begin, Result::Applied, frame.routeToken, frame.revision, frame.transferId, outcome.ack);
      break;
    case Op::Chunk:
      chunk(frame);
      break;
    case Op::Commit: {
      const Result result = commit(frame);
      outcome.changed = result == Result::Applied;
      outcome.hasAck = true;
      encodeAck(Op::Commit, result, stagedTokenForAck_, stagedRevisionForAck_, frame.transferId, outcome.ack);
      break;
    }
    case Op::Progress:
      outcome.changed = applyProgress(frame);
      break;
    }
    return outcome;
  }

  void expire(uint32_t nowMs) {
    if (staging_ && nowMs - startedMs_ > TRANSFER_TIMEOUT_MS) {
      clearStaging();
    }
  }

  void reset() {
    binding_ = {};
    hasProfile_ = false;
    hasProgress_ = false;
    clearStaging();
  }

  const Binding &binding() const { return binding_; }
  bool hasProfile() const { return hasProfile_; }
  const Profile &profile() const { return profile_; }
  bool hasProgress() const { return hasProgress_; }
  const Progress &progress() const { return progress_; }
  bool staging() const { return staging_; }

private:
  bool sameBinding(uint32_t token, uint16_t revision) const {
    return binding_.routeToken == token && binding_.revision == revision;
  }

  void adoptBinding(uint32_t token, uint16_t revision, ProfileState state, Reason reason) {
    if (!sameBinding(token, revision)) {
      hasProfile_ = false;
      hasProgress_ = false;
      if (staging_ && (stagingToken_ != token || stagingRevision_ != revision)) {
        clearStaging();
      }
    }
    binding_ = {token, revision, state, reason};
  }

  bool applyState(const Frame &frame) {
    const Binding before = binding_;
    const bool hadProfile = hasProfile_;
    if (frame.state == ProfileState::Cleared) {
      reset();
      return before.state != ProfileState::Cleared || hadProfile;
    }
    adoptBinding(frame.routeToken, frame.revision, frame.state, frame.reason);
    // The phone is authoritative: a non-ready state replaces an active profile.
    hasProfile_ = false;
    hasProgress_ = false;
    return before.routeToken != binding_.routeToken || before.revision != binding_.revision ||
           before.state != binding_.state || before.reason != binding_.reason || hadProfile;
  }

  bool begin(const Frame &frame, uint32_t nowMs) {
    bool changed = false;
    if (!sameBinding(frame.routeToken, frame.revision)) {
      adoptBinding(frame.routeToken, frame.revision, ProfileState::Loading, Reason::Unspecified);
      changed = true;
    } else if (binding_.state != ProfileState::Ready) {
      changed = binding_.state != ProfileState::Loading;
      binding_.state = ProfileState::Loading;
      binding_.reason = Reason::Unspecified;
    }
    clearStaging();
    staging_ = true;
    transferId_ = frame.transferId;
    stagingToken_ = frame.routeToken;
    stagingRevision_ = frame.revision;
    bodyLength_ = frame.bodyLength;
    chunkCount_ = frame.chunkCount;
    expectedCrc_ = frame.crc32;
    startedMs_ = nowMs;
    return changed;
  }

  void chunk(const Frame &frame) {
    if (!staging_ || frame.transferId != transferId_ || failed_) {
      return;
    }
    if (frame.chunkIndex != nextChunk_ || nextChunk_ >= chunkCount_) {
      failed_ = true;
      failure_ = Result::Incomplete;
      return;
    }
    if (received_ + frame.payloadLength > bodyLength_) {
      failed_ = true;
      failure_ = Result::Malformed;
      return;
    }
    std::memcpy(buffer_.data() + received_, frame.payload, frame.payloadLength);
    received_ = static_cast<uint16_t>(received_ + frame.payloadLength);
    ++nextChunk_;
  }

  Result commit(const Frame &frame) {
    stagedTokenForAck_ = binding_.routeToken;
    stagedRevisionForAck_ = binding_.revision;
    if (!staging_ || frame.transferId != transferId_) {
      return Result::Stale;
    }
    stagedTokenForAck_ = stagingToken_;
    stagedRevisionForAck_ = stagingRevision_;
    Result result = Result::Applied;
    if (failed_) {
      result = failure_;
    } else if (received_ != bodyLength_ || nextChunk_ != chunkCount_) {
      result = Result::Incomplete;
    } else if (crc32(buffer_.data(), bodyLength_) != expectedCrc_) {
      result = Result::CrcMismatch;
    } else if (!decodeBody(buffer_.data(), bodyLength_, candidate_) ||
               candidate_.routeToken != stagingToken_ || candidate_.revision != stagingRevision_) {
      result = Result::Malformed;
    } else if (!sameBinding(stagingToken_, stagingRevision_)) {
      result = Result::Stale;
    }
    if (result == Result::Applied) {
      profile_ = candidate_;
      hasProfile_ = true;
      hasProgress_ = false;
      binding_.state = ProfileState::Ready;
      binding_.reason = Reason::Unspecified;
    }
    clearStaging();
    return result;
  }

  bool applyProgress(const Frame &frame) {
    if (!hasProfile_ || frame.routeToken != profile_.routeToken || frame.revision != profile_.revision) {
      return false;
    }
    Progress next = frame.progress;
    if (next.progressM != UNKNOWN_PROGRESS && next.progressM > profile_.totalDistanceM) {
      next.progressM = profile_.totalDistanceM;
    }
    if (hasProgress_ && next.sequence == progress_.sequence) {
      return false;
    }
    const bool changed = !hasProgress_ || next != progress_;
    progress_ = next;
    hasProgress_ = true;
    return changed;
  }

  void clearStaging() {
    staging_ = false;
    failed_ = false;
    failure_ = Result::Applied;
    transferId_ = 0;
    stagingToken_ = 0;
    stagingRevision_ = 0;
    bodyLength_ = 0;
    chunkCount_ = 0;
    nextChunk_ = 0;
    received_ = 0;
    expectedCrc_ = 0;
  }

  Binding binding_{};
  bool hasProfile_ = false;
  Profile profile_{};
  bool hasProgress_ = false;
  Progress progress_{};
  Profile candidate_{};

  bool staging_ = false;
  bool failed_ = false;
  Result failure_ = Result::Applied;
  uint16_t transferId_ = 0;
  uint32_t stagingToken_ = 0;
  uint16_t stagingRevision_ = 0;
  uint16_t bodyLength_ = 0;
  uint8_t chunkCount_ = 0;
  uint8_t nextChunk_ = 0;
  uint16_t received_ = 0;
  uint32_t expectedCrc_ = 0;
  uint32_t startedMs_ = 0;
  uint32_t stagedTokenForAck_ = 0;
  uint16_t stagedRevisionForAck_ = 0;
  std::array<uint8_t, MAXIMUM_BODY_BYTES> buffer_{};
};

} // namespace route_elevation_protocol
