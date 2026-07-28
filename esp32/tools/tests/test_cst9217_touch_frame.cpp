#include "../../lib/waveshare_board/cst9217_touch_frame.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

using namespace waveshare_board::touch;

namespace {

void encodeContact(uint8_t *data, std::size_t offset, uint8_t id,
                   uint8_t status, uint16_t x, uint16_t y) {
  data[offset] = static_cast<uint8_t>((id << 4) | status);
  data[offset + 1] = static_cast<uint8_t>(x >> 4);
  data[offset + 2] = static_cast<uint8_t>(y >> 4);
  data[offset + 3] =
      static_cast<uint8_t>(((x & 0x0F) << 4) | (y & 0x0F));
}

} // namespace

int main() {
  uint8_t packet[CST9217_FRAME_LENGTH] = {};
  packet[6] = CST9217_FRAME_ACK;
  TouchFrame frame;

  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::Ok);
  assert(frame.count == 0);

  packet[5] = 1;
  encodeContact(packet, 0, 1, CST9217_STATUS_PRESSED, 123, 456);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::Ok);
  assert(frame.count == 1);
  assert(frame.contacts[0].id == 1);
  assert(frame.contacts[0].x == 123);
  assert(frame.contacts[0].y == 456);

  packet[5] = 2;
  encodeContact(packet, 0, 1, CST9217_STATUS_CONTINUING, 400, 20);
  encodeContact(packet, 7, 0, CST9217_STATUS_PRESSED, 30, 440);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::Ok);
  assert(frame.count == 2);
  assert(frame.contacts[0].id == 0);
  assert(frame.contacts[0].x == 30);
  assert(frame.contacts[1].id == 1);
  assert(frame.contacts[1].x == 400);

  TouchContact rotated =
      rotateTouchContact(frame.contacts[0], 1, 465, 465);
  assert(rotated.x == 440);
  assert(rotated.y == 435);

  assert(decodeCst9217Frame(packet, sizeof(packet) - 1, 466, 466, frame) ==
         Cst9217DecodeStatus::InvalidLength);
  packet[6] = 0;
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::InvalidAcknowledgement);
  packet[6] = CST9217_FRAME_ACK;
  packet[5] = 3;
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::TooManyContacts);

  packet[5] = 1;
  encodeContact(packet, 0, 2, CST9217_STATUS_PRESSED, 100, 100);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::InvalidContactId);
  encodeContact(packet, 0, 1, 0x05, 100, 100);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::InvalidStatus);
  encodeContact(packet, 0, 1, CST9217_STATUS_PRESSED, 466, 100);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::InvalidCoordinate);

  packet[5] = 2;
  encodeContact(packet, 0, 1, CST9217_STATUS_PRESSED, 10, 10);
  encodeContact(packet, 7, 1, CST9217_STATUS_PRESSED, 20, 20);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::DuplicateContactId);

  std::cout << "CST9217 touch-frame tests passed\n";
  return 0;
}
