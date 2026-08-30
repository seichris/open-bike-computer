#pragma once

#include "ride_ble_protocol.generated.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace ride_delivery_protocol {

constexpr uint8_t VERSION =
    ride_ble_protocol_generated::APPLICATION_DELIVERY_VERSION;
constexpr std::size_t COMMAND_HEADER_SIZE =
    ride_ble_protocol_generated::APPLICATION_COMMAND_HEADER_BYTES;
constexpr std::size_t ACK_SIZE =
    ride_ble_protocol_generated::APPLICATION_ACK_BYTES;
constexpr uint8_t MAX_GROUP_MEMBERS =
    ride_ble_protocol_generated::MAXIMUM_APPLICATION_GROUP_MEMBERS;
constexpr std::size_t COMPLETED_REPLAY_WINDOW =
    ride_ble_protocol_generated::COMPLETED_APPLICATION_REPLAY_WINDOW;
inline constexpr auto &COMMAND_PREFIX =
    ride_ble_protocol_generated::APPLICATION_COMMAND_MAGIC;
inline constexpr auto &ACK_PREFIX =
    ride_ble_protocol_generated::APPLICATION_ACK_MAGIC;

using CommandType = ride_ble_protocol_generated::ApplicationCommandType;
using Result = ride_ble_protocol_generated::ApplicationResult;

using CommandId = std::array<uint8_t, 16>;

struct CommandMember {
  CommandType type = CommandType::NavigationClear;
  uint8_t memberIndex = 0;
  uint8_t memberCount = 0;
  CommandId commandId{};
  uint32_t stateGeneration = 0;
  const uint8_t *payload = nullptr;
  std::size_t payloadLength = 0;
};

struct Acknowledgement {
  CommandType type = CommandType::NavigationClear;
  Result result = Result::Malformed;
  CommandId commandId{};
  uint32_t stateGeneration = 0;
  uint32_t leaseGeneration = 0;
};

inline uint32_t readUInt32LE(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8U) |
         (static_cast<uint32_t>(data[2]) << 16U) |
         (static_cast<uint32_t>(data[3]) << 24U);
}

inline void writeUInt32LE(uint32_t value, uint8_t *data) {
  for (uint8_t index = 0; index < 4; ++index)
    data[index] = static_cast<uint8_t>(value >> (index * 8U));
}

inline bool validCommandType(uint8_t raw) {
  return raw == static_cast<uint8_t>(CommandType::NavigationClear) ||
         raw == static_cast<uint8_t>(CommandType::WorkoutState);
}

inline bool validResult(uint8_t raw) {
  return raw <= static_cast<uint8_t>(Result::ResourceRejected);
}

inline bool nonzeroCommandId(const uint8_t *data) {
  uint8_t combined = 0;
  for (std::size_t index = 0; index < CommandId{}.size(); ++index)
    combined |= data[index];
  return combined != 0;
}

inline bool decodeCommand(const uint8_t *data, std::size_t length,
                          CommandMember &out) {
  if (data == nullptr || length < COMMAND_HEADER_SIZE ||
      std::memcmp(data, COMMAND_PREFIX, 4) != 0 || data[4] != VERSION ||
      !validCommandType(data[5]) || data[7] == 0 ||
      data[7] > MAX_GROUP_MEMBERS || data[6] >= data[7] ||
      !nonzeroCommandId(data + 8) || readUInt32LE(data + 24) == 0)
    return false;
  out = {};
  out.type = static_cast<CommandType>(data[5]);
  out.memberIndex = data[6];
  out.memberCount = data[7];
  std::memcpy(out.commandId.data(), data + 8, out.commandId.size());
  out.stateGeneration = readUInt32LE(data + 24);
  out.payload = data + COMMAND_HEADER_SIZE;
  out.payloadLength = length - COMMAND_HEADER_SIZE;
  return true;
}

inline std::size_t encodeAcknowledgement(const Acknowledgement &value,
                                         uint8_t *output,
                                         std::size_t capacity) {
  if (output == nullptr || capacity < ACK_SIZE ||
      !validCommandType(static_cast<uint8_t>(value.type)) ||
      !validResult(static_cast<uint8_t>(value.result)) ||
      !nonzeroCommandId(value.commandId.data()) ||
      value.stateGeneration == 0)
    return 0;
  std::memcpy(output, ACK_PREFIX, 4);
  output[4] = VERSION;
  output[5] = static_cast<uint8_t>(value.type);
  output[6] = static_cast<uint8_t>(value.result);
  output[7] = 0;
  std::memcpy(output + 8, value.commandId.data(), value.commandId.size());
  writeUInt32LE(value.stateGeneration, output + 24);
  writeUInt32LE(value.leaseGeneration, output + 28);
  return ACK_SIZE;
}

inline bool decodeAcknowledgement(const uint8_t *data, std::size_t length,
                                  Acknowledgement &out) {
  if (data == nullptr || length != ACK_SIZE ||
      std::memcmp(data, ACK_PREFIX, 4) != 0 || data[4] != VERSION ||
      !validCommandType(data[5]) || !validResult(data[6]) || data[7] != 0 ||
      !nonzeroCommandId(data + 8) || readUInt32LE(data + 24) == 0)
    return false;
  out = {};
  out.type = static_cast<CommandType>(data[5]);
  out.result = static_cast<Result>(data[6]);
  std::memcpy(out.commandId.data(), data + 8, out.commandId.size());
  out.stateGeneration = readUInt32LE(data + 24);
  out.leaseGeneration = readUInt32LE(data + 28);
  return true;
}

enum class TrackingResult : uint8_t {
  Pending,
  Complete,
  DuplicateComplete,
  Immediate,
  Rejected,
};

class GroupTracker {
public:
  TrackingResult note(const CommandMember &member, Result memberResult,
                      uint32_t leaseGeneration, Acknowledgement &out) {
    if (member.memberCount == 0 || member.memberCount > MAX_GROUP_MEMBERS ||
        member.memberIndex >= member.memberCount)
      return TrackingResult::Rejected;

    for (std::size_t index = 0; index < completedCount_; ++index) {
      const Acknowledgement &completed = completed_[index];
      if (completed.type == member.type &&
          completed.commandId == member.commandId &&
          completed.stateGeneration == member.stateGeneration) {
        out = completed;
        return TrackingResult::DuplicateComplete;
      }
    }

    if (pendingValid_ &&
        (pendingType_ != member.type ||
         pendingCommandId_ != member.commandId ||
         pendingStateGeneration_ != member.stateGeneration)) {
      out = {member.type, Result::Busy, member.commandId,
             member.stateGeneration, leaseGeneration};
      return TrackingResult::Immediate;
    }

    if (!pendingValid_) {
      pendingValid_ = true;
      pendingType_ = member.type;
      pendingCommandId_ = member.commandId;
      pendingStateGeneration_ = member.stateGeneration;
      pendingMemberCount_ = member.memberCount;
      pendingMask_ = 0;
      pendingResult_ = Result::Success;
    }
    if (pendingMemberCount_ != member.memberCount) {
      out = {member.type, Result::Malformed, member.commandId,
             member.stateGeneration, leaseGeneration};
      return TrackingResult::Immediate;
    }

    pendingMask_ |= static_cast<uint8_t>(1U << member.memberIndex);
    if (memberResult != Result::Success && pendingResult_ == Result::Success)
      pendingResult_ = memberResult;
    const uint8_t completeMask = static_cast<uint8_t>(
        (1U << pendingMemberCount_) - 1U);
    if (pendingMask_ != completeMask)
      return TrackingResult::Pending;

    const Acknowledgement completed = {
        pendingType_, pendingResult_, pendingCommandId_,
        pendingStateGeneration_, leaseGeneration};
    if (completedCount_ < completed_.size()) {
      completed_[completedCount_++] = completed;
    } else {
      completed_[completedCursor_] = completed;
      completedCursor_ = (completedCursor_ + 1U) % completed_.size();
    }
    pendingValid_ = false;
    out = completed;
    return TrackingResult::Complete;
  }

  void reset() {
    pendingValid_ = false;
    completedCount_ = 0;
    completedCursor_ = 0;
    pendingMask_ = 0;
  }

private:
  bool pendingValid_ = false;
  CommandType pendingType_ = CommandType::NavigationClear;
  CommandId pendingCommandId_{};
  uint32_t pendingStateGeneration_ = 0;
  uint8_t pendingMemberCount_ = 0;
  uint8_t pendingMask_ = 0;
  Result pendingResult_ = Result::Success;
  std::array<Acknowledgement, COMPLETED_REPLAY_WINDOW> completed_{};
  std::size_t completedCount_ = 0;
  std::size_t completedCursor_ = 0;
};

} // namespace ride_delivery_protocol
