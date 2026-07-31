#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace map_setting_packet {

constexpr std::size_t kPacketSize = 5;

struct Packet {
  uint8_t settingId = 0;
  int32_t value = 0;
};

inline bool decode(const uint8_t *data, std::size_t length, Packet &packet) {
  if (data == nullptr || length != kPacketSize) {
    return false;
  }

  packet.settingId = data[0];
  const uint32_t rawValue = static_cast<uint32_t>(data[1]) |
                            (static_cast<uint32_t>(data[2]) << 8) |
                            (static_cast<uint32_t>(data[3]) << 16) |
                            (static_cast<uint32_t>(data[4]) << 24);
  static_assert(sizeof(rawValue) == sizeof(packet.value));
  std::memcpy(&packet.value, &rawValue, sizeof(packet.value));
  return true;
}

} // namespace map_setting_packet
