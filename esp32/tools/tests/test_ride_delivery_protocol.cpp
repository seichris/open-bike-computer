#include "../../lib/ble_navigation/ride_delivery_protocol.hpp"

#include <array>
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <iomanip>
#include <sstream>
#include <string>

template <std::size_t N>
static std::string hexadecimal(const std::array<uint8_t, N> &bytes) {
  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const uint8_t byte : bytes)
    output << std::setw(2) << static_cast<unsigned>(byte);
  return output.str();
}

int main() {
  using namespace ride_delivery_protocol;
  const std::array<uint8_t, 30> command = {
      'R',  'C',  'M',  '1', 1,    2,    1,    3,
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
      0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
      0x78, 0x56, 0x34, 0x12, 0xaa, 0xbb,
  };
  CommandMember decoded{};
  assert(decodeCommand(command.data(), command.size(), decoded));
  assert(decoded.type == CommandType::WorkoutState);
  assert(decoded.memberIndex == 1 && decoded.memberCount == 3);
  assert(decoded.stateGeneration == 0x12345678U);
  assert(decoded.payloadLength == 2 && decoded.payload[0] == 0xaa &&
         decoded.payload[1] == 0xbb);
  assert(hexadecimal(command) ==
         ride_ble_protocol_generated::APPLICATION_COMMAND_GOLDEN_HEX);
  assert(!decodeCommand(command.data(), COMMAND_HEADER_SIZE - 1, decoded));
  auto zeroGeneration = command;
  std::fill(zeroGeneration.begin() + 24, zeroGeneration.begin() + 28, 0);
  assert(!decodeCommand(zeroGeneration.data(), zeroGeneration.size(), decoded));
  auto zeroCommandId = command;
  std::fill(zeroCommandId.begin() + 8, zeroCommandId.begin() + 24, 0);
  assert(!decodeCommand(zeroCommandId.data(), zeroCommandId.size(), decoded));
  auto tooManyMembers = command;
  tooManyMembers[7] = static_cast<uint8_t>(MAX_GROUP_MEMBERS + 1);
  assert(!decodeCommand(tooManyMembers.data(), tooManyMembers.size(), decoded));

  Acknowledgement acknowledgement{CommandType::WorkoutState, Result::Success,
                                  decoded.commandId, 0x12345678U, 9};
  std::array<uint8_t, ACK_SIZE> encoded{};
  assert(encodeAcknowledgement(acknowledgement, encoded.data(),
                               encoded.size()) == ACK_SIZE);
  const std::array<uint8_t, ACK_SIZE> golden = {
      'R',  'A',  'K',  '1', 1,    2,    0,    0,
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
      0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
      0x78, 0x56, 0x34, 0x12, 0x09, 0x00, 0x00, 0x00,
  };
  assert(encoded == golden);
  assert(hexadecimal(encoded) ==
         ride_ble_protocol_generated::APPLICATION_ACK_GOLDEN_HEX);
  Acknowledgement decodedAck{};
  assert(decodeAcknowledgement(encoded.data(), encoded.size(), decodedAck));
  assert(decodedAck.commandId == acknowledgement.commandId &&
         decodedAck.leaseGeneration == 9);
  auto invalidAck = acknowledgement;
  invalidAck.commandId.fill(0);
  assert(encodeAcknowledgement(invalidAck, encoded.data(), encoded.size()) ==
         0);
  invalidAck = acknowledgement;
  invalidAck.stateGeneration = 0;
  assert(encodeAcknowledgement(invalidAck, encoded.data(), encoded.size()) ==
         0);
  auto zeroAckCommandId = golden;
  std::fill(zeroAckCommandId.begin() + 8, zeroAckCommandId.begin() + 24, 0);
  assert(!decodeAcknowledgement(zeroAckCommandId.data(),
                                zeroAckCommandId.size(), decodedAck));
  auto zeroAckGeneration = golden;
  std::fill(zeroAckGeneration.begin() + 24, zeroAckGeneration.begin() + 28,
            0);
  assert(!decodeAcknowledgement(zeroAckGeneration.data(),
                                zeroAckGeneration.size(), decodedAck));

  GroupTracker tracker;
  Acknowledgement completed{};
  for (uint8_t index = 0; index < 3; ++index) {
    CommandMember member = decoded;
    member.memberIndex = index;
    assert(tracker.note(member, Result::Success, 9, completed) ==
           (index == 2 ? TrackingResult::Complete
                       : TrackingResult::Pending));
  }
  assert(completed.result == Result::Success &&
         completed.leaseGeneration == 9);
  assert(tracker.note(decoded, Result::Success, 10, completed) ==
         TrackingResult::DuplicateComplete);
  assert(completed.leaseGeneration == 9);

  tracker.reset();
  CommandMember first = decoded;
  first.memberIndex = 0;
  assert(tracker.note(first, Result::Success, 11, completed) ==
         TrackingResult::Pending);
  CommandMember second = decoded;
  second.memberIndex = 1;
  assert(tracker.note(second, Result::ResourceRejected, 11, completed) ==
         TrackingResult::Pending);
  CommandMember third = decoded;
  third.memberIndex = 2;
  assert(tracker.note(third, Result::Success, 11, completed) ==
         TrackingResult::Complete);
  assert(completed.result == Result::ResourceRejected);

  tracker.reset();
  assert(tracker.note(first, Result::Success, 12, completed) ==
         TrackingResult::Pending);
  CommandMember interleaved = decoded;
  interleaved.memberIndex = 0;
  interleaved.memberCount = 1;
  interleaved.commandId[15] ^= 0x80;
  interleaved.stateGeneration += 1;
  assert(tracker.note(interleaved, Result::Success, 12, completed) ==
         TrackingResult::Immediate);
  assert(completed.commandId == interleaved.commandId &&
         completed.result == Result::Busy &&
         completed.leaseGeneration == 12);
  assert(tracker.note(second, Result::Success, 12, completed) ==
         TrackingResult::Pending);
  assert(tracker.note(third, Result::Success, 12, completed) ==
         TrackingResult::Complete);
  assert(completed.commandId == decoded.commandId &&
         completed.result == Result::Success);

  tracker.reset();
  assert(tracker.note(first, Result::Success, 13, completed) ==
         TrackingResult::Pending);
  CommandMember mismatchedCount = second;
  mismatchedCount.memberCount = 2;
  assert(tracker.note(mismatchedCount, Result::Success, 13, completed) ==
         TrackingResult::Immediate);
  assert(completed.commandId == decoded.commandId &&
         completed.result == Result::Malformed);
  assert(tracker.note(second, Result::Success, 13, completed) ==
         TrackingResult::Pending);
  assert(tracker.note(third, Result::Success, 13, completed) ==
         TrackingResult::Complete);

  tracker.reset();
  std::array<CommandMember, COMPLETED_REPLAY_WINDOW> retained{};
  for (std::size_t index = 0; index < retained.size(); ++index) {
    retained[index] = decoded;
    retained[index].memberIndex = 0;
    retained[index].memberCount = 1;
    retained[index].commandId[15] = static_cast<uint8_t>(index + 1);
    retained[index].stateGeneration = static_cast<uint32_t>(index + 1);
    assert(tracker.note(retained[index], Result::Success,
                        static_cast<uint32_t>(20 + index), completed) ==
           TrackingResult::Complete);
  }
  assert(tracker.note(retained.front(), Result::Success, 99, completed) ==
         TrackingResult::DuplicateComplete);
  assert(completed.leaseGeneration == 20);

  std::cout << "ride delivery protocol tests passed\n";
  return 0;
}
