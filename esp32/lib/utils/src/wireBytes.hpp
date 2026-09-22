#pragma once

#include <cstdint>

namespace wire_bytes {
// Preconditions: the caller validated a readable/writable span of 2 or 4 bytes.
// Do not reinterpret_cast to integer pointers: BLE buffers need not be aligned.
inline uint16_t readU16(const uint8_t *input) {
  return static_cast<uint16_t>(input[0]) |
         (static_cast<uint16_t>(input[1]) << 8);
}
inline uint32_t readU32(const uint8_t *input) {
  return static_cast<uint32_t>(input[0]) |
         (static_cast<uint32_t>(input[1]) << 8) |
         (static_cast<uint32_t>(input[2]) << 16) |
         (static_cast<uint32_t>(input[3]) << 24);
}
inline void writeU16(uint8_t *output, uint16_t value) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8);
}
inline void writeU32(uint8_t *output, uint32_t value) {
  for (unsigned index = 0; index < 4; ++index)
    output[index] = static_cast<uint8_t>(value >> (index * 8));
}
} // namespace wire_bytes
