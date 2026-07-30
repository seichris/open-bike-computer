#include "../../lib/waveshare_board/cst9217_touch_frame.hpp"
#include "../../lib/waveshare_board/touch_sampling_policy.hpp"
#include "../../lib/utils/src/touchInterruptGate.hpp"

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
  using waveshare_board::touch_sampling_policy::shouldAttemptRead;

  assert(shouldAttemptRead(true, false, false, false, 1000, 0));
  assert(!shouldAttemptRead(false, false, false, false, 1000, 0));
  assert(shouldAttemptRead(false, true, false, false, 1000, 0));
  assert(shouldAttemptRead(false, false, true, false, 1000, 0));
  assert(shouldAttemptRead(false, false, false, true, 1000, 0));
  assert(shouldAttemptRead(false, false, false, false, 999, 1000));
  assert(!shouldAttemptRead(false, false, false, false, 1000, 1000));
  assert(shouldAttemptRead(false, false, false, false, UINT32_MAX - 2, 2));
  assert(!shouldAttemptRead(false, false, false, false, 2, UINT32_MAX - 2));

  // Both CST9217 and FT3168 use the same generation gate. A new edge bypasses
  // throttling once, failure on that attempt does not create a busy retry
  // loop, and a later edge can preempt the existing backoff once.
  for (int controllerPath = 0; controllerPath < 2; ++controllerPath) {
    (void)controllerPath;
    uint32_t generated = 10;
    uint32_t attempted = 9;
    assert(touch_interrupt_gate::shouldBypassThrottle(generated, attempted));
    attempted = generated; // init/read attempt begins, then fails before I2C
    assert(!touch_interrupt_gate::shouldBypassThrottle(generated, attempted));
    ++generated;
    assert(touch_interrupt_gate::shouldBypassThrottle(generated, attempted));
  }

  uint8_t packet[CST9217_FRAME_LENGTH] = {};
  assert(!hasCst9217FrameAcknowledgement(packet, sizeof(packet)));
  assert(!hasCst9217FrameAcknowledgement(nullptr, sizeof(packet)));
  assert(!hasCst9217FrameAcknowledgement(packet, sizeof(packet) - 1));
  packet[6] = CST9217_FRAME_ACK;
  assert(hasCst9217FrameAcknowledgement(packet, sizeof(packet)));
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
  encodeContact(packet, 0, 1, CST9217_STATUS_RELEASED, 400, 20);
  encodeContact(packet, 7, 0, CST9217_STATUS_PRESSED, 30, 440);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::Ok);
  assert(frame.count == 2);
  assert(frame.contacts[0].id == 0);
  assert(frame.contacts[0].x == 30);
  assert(frame.contacts[1].id == 1);
  assert(frame.contacts[1].x == 400);

  TouchFrame active = activeCst9217Contacts(frame);
  assert(active.count == 1);
  assert(active.contacts[0].id == 0);
  assert(active.contacts[0].x == 30);

  packet[5] = 1;
  encodeContact(packet, 0, 0, CST9217_STATUS_RELEASED, 30, 440);
  assert(decodeCst9217Frame(packet, sizeof(packet), 466, 466, frame) ==
         Cst9217DecodeStatus::Ok);
  assert(activeCst9217Contacts(frame).count == 0);

  TouchContact rotated = rotateTouchContact(active.contacts[0], 1, 465, 465);
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
