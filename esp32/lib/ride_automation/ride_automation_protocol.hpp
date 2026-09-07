#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include "../ble_navigation/ride_ble_protocol.generated.hpp"

namespace ride_automation_protocol {

constexpr uint8_t PROTOCOL_VERSION = 2;
constexpr std::size_t FRAME_SIZE = 52;
constexpr std::size_t SESSION_ID_SIZE = 16;
constexpr uint16_t SOURCE_HEALTH_MASK = ride_ble_protocol_generated::SOURCE_HEALTH_MASK;
constexpr char FALLBACK_PREFIX[] = "RAUT";
constexpr std::size_t FALLBACK_PREFIX_SIZE = 4;

enum class Kind : uint8_t {
  Decision = 1,
  Acknowledgement = 2,
  Confirmation = 3,
  Configuration = 4,
  ConfigurationAcknowledgement = 5,
  Resynchronize = 6,
  PromptResponse = 7,
  Cancellation = 8,
};

enum class Transition : uint8_t { None = 0, Start = 1, Pause = 2, Resume = 3 };
enum class Origin : uint8_t { Unknown = 0, Manual = 1, Automatic = 2 };
enum class Result : uint8_t {
  None = 0,
  Accepted = 1,
  Rejected = 2,
  WatchUnavailable = 3,
  Stale = 4,
  SessionMismatch = 5,
};

struct Frame {
  Kind kind = Kind::Decision;
  Transition transition = Transition::None;
  Origin origin = Origin::Unknown;
  Result result = Result::None;
  uint32_t rideGeneration = 0;
  uint32_t decisionSequence = 0;
  uint16_t evidenceMask = 0;
  uint16_t profileVersion = 0;
  std::array<uint8_t, SESSION_ID_SIZE> sessionID{};
  uint32_t watermarkOrConfigGeneration = 0;
  uint8_t startMode = 0;
  bool autoPauseEnabled = false;
  uint8_t alertMode = 0;
  uint32_t candidateBeganSeconds = 0;
  uint32_t monotonicSeconds = 0;
  uint16_t sourceHealthMask = 0;
  uint8_t acknowledgedKind = 0;
};

constexpr bool validKind(uint8_t raw) {
  return raw >= static_cast<uint8_t>(Kind::Decision) &&
         raw <= static_cast<uint8_t>(Kind::Cancellation);
}

constexpr bool validTransition(uint8_t raw) {
  return raw <= static_cast<uint8_t>(Transition::Resume);
}

constexpr bool validOrigin(uint8_t raw) {
  return raw <= static_cast<uint8_t>(Origin::Automatic);
}

constexpr bool validResult(uint8_t raw) {
  return raw <= static_cast<uint8_t>(Result::SessionMismatch);
}

// RFC 1982-style comparison for persisted uint32 generations. A zero delta is
// equal; exactly half the serial space is intentionally unordered.
constexpr bool serialNumberNewer(uint32_t candidate, uint32_t current) {
  const uint32_t delta = candidate - current;
  return delta != 0 && delta < 0x80000000U;
}

constexpr bool hasSessionID(
    const std::array<uint8_t, SESSION_ID_SIZE> &sessionID) {
  for (const uint8_t value : sessionID) {
    if (value != 0)
      return true;
  }
  return false;
}

struct PromptResponseResolution {
  bool accepted = false;
  Result acknowledgement = Result::Rejected;
  bool shouldSnooze = true;
};

constexpr PromptResponseResolution resolvePromptResponse(
    bool alreadyResponded, bool existingAccepted, Result incoming) {
  const bool incomingAccepted = incoming == Result::Accepted;
  const bool conflictsWithNotNow =
      alreadyResponded && !existingAccepted && incomingAccepted;
  return {
      !conflictsWithNotNow && incomingAccepted,
      conflictsWithNotNow ? Result::Rejected : Result::Accepted,
      conflictsWithNotNow || !incomingAccepted,
  };
}

constexpr bool semanticallyValid(const Frame &frame) {
  switch (frame.kind) {
  case Kind::Decision:
    return frame.transition != Transition::None &&
           frame.origin == Origin::Automatic && frame.result == Result::None &&
           frame.acknowledgedKind == 0;
  case Kind::Acknowledgement:
    return frame.transition != Transition::None &&
           frame.origin == Origin::Automatic && frame.result != Result::None &&
           (frame.acknowledgedKind == static_cast<uint8_t>(Kind::Decision) ||
            (frame.acknowledgedKind ==
                 static_cast<uint8_t>(Kind::PromptResponse) &&
             frame.transition == Transition::Start));
  case Kind::Confirmation:
    return frame.transition != Transition::None &&
           frame.origin == Origin::Automatic && frame.result != Result::None &&
           frame.acknowledgedKind == 0;
  case Kind::Configuration:
    return frame.transition == Transition::None &&
           frame.origin == Origin::Unknown && frame.result == Result::None &&
           frame.decisionSequence == 0 &&
           frame.watermarkOrConfigGeneration != 0 &&
           frame.acknowledgedKind == 0;
  case Kind::ConfigurationAcknowledgement:
    return frame.transition == Transition::None &&
           frame.origin == Origin::Unknown &&
           (frame.result == Result::Accepted ||
            frame.result == Result::Rejected) &&
           frame.decisionSequence == 0 && frame.acknowledgedKind == 0;
  case Kind::Resynchronize:
    return frame.transition == Transition::None &&
           frame.origin == Origin::Unknown && frame.result == Result::None &&
           frame.decisionSequence == 0 && frame.acknowledgedKind == 0;
  case Kind::PromptResponse:
    return frame.transition == Transition::Start &&
           frame.origin == Origin::Automatic &&
           (frame.result == Result::Accepted ||
            frame.result == Result::Rejected) && frame.acknowledgedKind == 0;
  case Kind::Cancellation:
    return frame.transition != Transition::None &&
           frame.origin == Origin::Automatic &&
           frame.result == Result::Stale && frame.acknowledgedKind == 0;
  }
  return false;
}

inline void writeUInt16(uint8_t *bytes, std::size_t offset, uint16_t value) {
  bytes[offset] = static_cast<uint8_t>(value);
  bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
}

inline void writeUInt32(uint8_t *bytes, std::size_t offset, uint32_t value) {
  for (uint8_t index = 0; index < 4; ++index)
    bytes[offset + index] = static_cast<uint8_t>(value >> (index * 8U));
}

constexpr uint16_t readUInt16(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint16_t>(bytes[offset]) |
         static_cast<uint16_t>(bytes[offset + 1]) << 8;
}

constexpr uint32_t readUInt32(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         static_cast<uint32_t>(bytes[offset + 1]) << 8 |
         static_cast<uint32_t>(bytes[offset + 2]) << 16 |
         static_cast<uint32_t>(bytes[offset + 3]) << 24;
}

inline bool encode(const Frame &frame, uint8_t *output, std::size_t capacity) {
  const bool decisionNeedsSequence =
      frame.kind == Kind::Decision || frame.kind == Kind::Acknowledgement ||
      frame.kind == Kind::Confirmation ||
      frame.kind == Kind::PromptResponse ||
      frame.kind == Kind::Cancellation;
  if (output == nullptr || capacity < FRAME_SIZE ||
      !validKind(static_cast<uint8_t>(frame.kind)) ||
      !validTransition(static_cast<uint8_t>(frame.transition)) ||
      !validOrigin(static_cast<uint8_t>(frame.origin)) ||
      !validResult(static_cast<uint8_t>(frame.result)) ||
      frame.rideGeneration == 0 ||
      frame.profileVersion == 0 || frame.startMode > 2 ||
      frame.alertMode > 2 ||
      (frame.sourceHealthMask & ~SOURCE_HEALTH_MASK) != 0 ||
      (decisionNeedsSequence && frame.decisionSequence == 0) ||
      !semanticallyValid(frame))
    return false;
  for (std::size_t index = 0; index < FRAME_SIZE; ++index)
    output[index] = 0;
  output[0] = PROTOCOL_VERSION;
  output[1] = static_cast<uint8_t>(frame.kind);
  output[2] = static_cast<uint8_t>(frame.transition);
  output[3] = static_cast<uint8_t>(frame.origin);
  output[4] = static_cast<uint8_t>(frame.result);
  output[5] = frame.startMode;
  output[6] = frame.autoPauseEnabled ? 1 : 0;
  output[7] = frame.alertMode;
  writeUInt32(output, 8, frame.rideGeneration);
  writeUInt32(output, 12, frame.decisionSequence);
  writeUInt16(output, 16, frame.evidenceMask);
  writeUInt16(output, 18, frame.profileVersion);
  for (std::size_t index = 0; index < SESSION_ID_SIZE; ++index)
    output[20 + index] = frame.sessionID[index];
  writeUInt32(output, 36, frame.watermarkOrConfigGeneration);
  writeUInt32(output, 40, frame.candidateBeganSeconds);
  writeUInt32(output, 44, frame.monotonicSeconds);
  writeUInt16(output, 48, frame.sourceHealthMask);
  output[50] = frame.acknowledgedKind;
  return true;
}

inline bool decode(const uint8_t *bytes, std::size_t length, Frame &frame) {
  if (bytes == nullptr || length != FRAME_SIZE ||
      bytes[0] != PROTOCOL_VERSION ||
      !validKind(bytes[1]) || !validTransition(bytes[2]) ||
      !validOrigin(bytes[3]) || !validResult(bytes[4]) || bytes[5] > 2 ||
      bytes[6] > 1 || bytes[7] > 2 || bytes[51] != 0)
    return false;
  Frame parsed;
  parsed.kind = static_cast<Kind>(bytes[1]);
  parsed.transition = static_cast<Transition>(bytes[2]);
  parsed.origin = static_cast<Origin>(bytes[3]);
  parsed.result = static_cast<Result>(bytes[4]);
  parsed.startMode = bytes[5];
  parsed.autoPauseEnabled = bytes[6] == 1;
  parsed.alertMode = bytes[7];
  parsed.rideGeneration = readUInt32(bytes, 8);
  parsed.decisionSequence = readUInt32(bytes, 12);
  parsed.evidenceMask = readUInt16(bytes, 16);
  parsed.profileVersion = readUInt16(bytes, 18);
  for (std::size_t index = 0; index < SESSION_ID_SIZE; ++index)
    parsed.sessionID[index] = bytes[20 + index];
  parsed.watermarkOrConfigGeneration = readUInt32(bytes, 36);
  parsed.candidateBeganSeconds = readUInt32(bytes, 40);
  parsed.monotonicSeconds = readUInt32(bytes, 44);
  parsed.sourceHealthMask = readUInt16(bytes, 48);
  parsed.acknowledgedKind = bytes[50];
  if (parsed.rideGeneration == 0 || parsed.profileVersion == 0 ||
      (parsed.sourceHealthMask & ~SOURCE_HEALTH_MASK) != 0)
    return false;
  const bool decisionNeedsSequence =
      parsed.kind == Kind::Decision || parsed.kind == Kind::Acknowledgement ||
      parsed.kind == Kind::Confirmation ||
      parsed.kind == Kind::PromptResponse ||
      parsed.kind == Kind::Cancellation;
  if (decisionNeedsSequence && parsed.decisionSequence == 0)
    return false;
  if (!semanticallyValid(parsed))
    return false;
  frame = parsed;
  return true;
}

inline bool matchesOutstandingResponse(bool hasOutstanding,
                                       const Frame &outstanding,
                                       const Frame &response) {
  if (!hasOutstanding ||
      response.rideGeneration != outstanding.rideGeneration ||
      response.decisionSequence != outstanding.decisionSequence ||
      response.transition != outstanding.transition ||
      response.origin != Origin::Automatic ||
      response.profileVersion != outstanding.profileVersion) {
    return false;
  }
  if (outstanding.transition != Transition::Start &&
      hasSessionID(outstanding.sessionID) &&
      response.sessionID != outstanding.sessionID) {
    return false;
  }
  return true;
}

inline bool isDuplicateOrOutOfOrderInbound(bool hasPrevious,
                                           const Frame &previous,
                                           const Frame &candidate) {
  return hasPrevious && candidate.kind == previous.kind &&
         candidate.rideGeneration == previous.rideGeneration &&
         candidate.decisionSequence != 0 &&
         !serialNumberNewer(candidate.decisionSequence,
                            previous.decisionSequence) &&
         candidate.kind != Kind::PromptResponse &&
         candidate.acknowledgedKind == previous.acknowledgedKind;
}

constexpr uint32_t outstandingDecisionWatermark(bool hasOutstanding,
                                                const Frame &outstanding) {
  return hasOutstanding ? outstanding.decisionSequence : 0;
}

} // namespace ride_automation_protocol
