#pragma once

#include <cstdint>

namespace map_byte_order {

inline uint16_t readLe16(const uint8_t *bytes) {
  return static_cast<uint16_t>(bytes[0]) |
         (static_cast<uint16_t>(bytes[1]) << 8U);
}

inline int16_t readLeI16(const uint8_t *bytes) {
  const uint16_t value = readLe16(bytes);
  return value < 0x8000U
             ? static_cast<int16_t>(value)
             : static_cast<int16_t>(static_cast<int32_t>(value) - 0x10000);
}

} // namespace map_byte_order
