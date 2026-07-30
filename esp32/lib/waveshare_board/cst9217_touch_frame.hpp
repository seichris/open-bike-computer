/**
 * @file cst9217_touch_frame.hpp
 * @brief Pure CST9217 two-contact packet decoding and touch-frame values.
 *
 * The packet layout follows Waveshare's MIT-licensed TouchDrvCST92xx reference:
 * https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75/blob/main/examples/arduino/libraries/SensorLib/src/touch/TouchDrvCST92xx.cpp
 * This header intentionally has no Arduino, Wire, or LVGL dependencies so
 * malformed controller frames can be covered by host tests.
 */

#pragma once

#include <cstddef>
#include <cstdint>

namespace waveshare_board::touch {

constexpr std::size_t CST9217_MAX_CONTACTS = 2;
constexpr std::size_t CST9217_FRAME_LENGTH =
    (CST9217_MAX_CONTACTS * 5) + 5;
constexpr uint8_t CST9217_FRAME_ACK = 0xAB;
constexpr uint8_t CST9217_STATUS_RELEASED = 0x00;
constexpr uint8_t CST9217_STATUS_PRESSED = 0x06;

struct TouchContact {
  uint8_t id = 0;
  uint16_t x = 0;
  uint16_t y = 0;
  uint8_t status = 0;
};

struct TouchFrame {
  uint32_t sequence = 0;
  uint32_t sampledAtMs = 0;
  uint8_t count = 0;
  TouchContact contacts[CST9217_MAX_CONTACTS] = {};
};

enum class Cst9217DecodeStatus : uint8_t {
  Ok = 0,
  InvalidLength,
  InvalidAcknowledgement,
  TooManyContacts,
  InvalidContactId,
  InvalidStatus,
  InvalidCoordinate,
  DuplicateContactId,
};

inline bool isCst9217ContactStatus(uint8_t status) {
  return status == CST9217_STATUS_RELEASED ||
         status == CST9217_STATUS_PRESSED;
}

inline bool hasCst9217FrameAcknowledgement(const uint8_t *data,
                                           std::size_t length) {
  return data != nullptr && length >= CST9217_FRAME_LENGTH &&
         data[6] == CST9217_FRAME_ACK;
}

inline TouchFrame activeCst9217Contacts(const TouchFrame &decoded) {
  TouchFrame active;
  for (uint8_t index = 0; index < decoded.count; ++index) {
    if (decoded.contacts[index].status != CST9217_STATUS_PRESSED)
      continue;
    active.contacts[active.count++] = decoded.contacts[index];
  }
  return active;
}

inline Cst9217DecodeStatus
decodeCst9217Frame(const uint8_t *data, std::size_t length,
                   uint16_t activeWidth, uint16_t activeHeight,
                   TouchFrame &frame) {
  frame.count = 0;
  if (data == nullptr || length < CST9217_FRAME_LENGTH) {
    return Cst9217DecodeStatus::InvalidLength;
  }
  if (!hasCst9217FrameAcknowledgement(data, length)) {
    return Cst9217DecodeStatus::InvalidAcknowledgement;
  }

  const uint8_t count = data[5] & 0x7F;
  if (count > CST9217_MAX_CONTACTS) {
    return Cst9217DecodeStatus::TooManyContacts;
  }

  TouchContact decoded[CST9217_MAX_CONTACTS] = {};
  for (uint8_t index = 0; index < count; ++index) {
    // The first contact begins at byte 0. Two metadata bytes between the first
    // and second records place the second contact at byte 7.
    const std::size_t offset = (index == 0) ? 0 : 7;
    const uint8_t id = data[offset] >> 4;
    const uint8_t status = data[offset] & 0x0F;
    const uint16_t x = static_cast<uint16_t>(data[offset + 1] << 4) |
                       static_cast<uint16_t>(data[offset + 3] >> 4);
    const uint16_t y = static_cast<uint16_t>(data[offset + 2] << 4) |
                       static_cast<uint16_t>(data[offset + 3] & 0x0F);

    if (id >= CST9217_MAX_CONTACTS) {
      return Cst9217DecodeStatus::InvalidContactId;
    }
    if (!isCst9217ContactStatus(status)) {
      return Cst9217DecodeStatus::InvalidStatus;
    }
    if (x >= activeWidth || y >= activeHeight) {
      return Cst9217DecodeStatus::InvalidCoordinate;
    }
    if (index == 1 && decoded[0].id == id) {
      return Cst9217DecodeStatus::DuplicateContactId;
    }
    decoded[index] = {id, x, y, status};
  }

  // Stable ID ordering prevents record-order changes from reversing a pinch.
  if (count == 2 && decoded[1].id < decoded[0].id) {
    const TouchContact swap = decoded[0];
    decoded[0] = decoded[1];
    decoded[1] = swap;
  }
  frame.count = count;
  for (uint8_t index = 0; index < count; ++index) {
    frame.contacts[index] = decoded[index];
  }
  return Cst9217DecodeStatus::Ok;
}

inline TouchContact rotateTouchContact(const TouchContact &raw,
                                       uint8_t rotation, uint16_t maxX,
                                       uint16_t maxY) {
  TouchContact rotated = raw;
  switch (rotation & 0x03) {
  case 1:
    rotated.x = raw.y;
    rotated.y = maxY - raw.x;
    break;
  case 2:
    rotated.x = maxX - raw.x;
    rotated.y = maxY - raw.y;
    break;
  case 3:
    rotated.x = maxX - raw.y;
    rotated.y = raw.x;
    break;
  default:
    break;
  }
  return rotated;
}

} // namespace waveshare_board::touch
