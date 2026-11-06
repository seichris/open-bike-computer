#pragma once

#include <cstddef>
#include <cstdint>

// Read-only view of ESP-IDF 5.5 wear-levelling metadata (WL_State.h,
// WL_Flash::config/init) with CONFIG_WL_SECTOR_SIZE=4096. A mount rewrites
// both state copies and the config sector when neither copy is valid, so
// unknown FFat contents are classified from these bytes before any mount.
namespace wear_levelling_state {

constexpr uint32_t kSectorBytes = 4096;
constexpr uint32_t kStateBytes = 64;      // sizeof(wl_state_t)
constexpr uint32_t kStateCrcBytes = 60;   // offsetof(wl_state_t, crc32)
constexpr uint32_t kVersionOffset = 24;   // offsetof(wl_state_t, version)
constexpr uint32_t kRecordBytes = 16;     // WL_DEFAULT_WRITE_SIZE
constexpr uint32_t kCurrentVersion = 2;   // WL_CURRENT_VERSION

// One state copy: the header plus one position record per sector, rounded up.
constexpr uint32_t stateRegionBytes(uint32_t partitionBytes) {
  const uint32_t needed =
      kStateBytes + (partitionBytes / kSectorBytes) * kRecordBytes;
  return (needed + kSectorBytes - 1) / kSectorBytes * kSectorBytes;
}

// Copy 0 and copy 1 sit below the final configuration sector.
constexpr uint32_t stateOffset(uint32_t partitionBytes, unsigned copy) {
  return partitionBytes - (copy == 0 ? 2U : 1U) * stateRegionBytes(partitionBytes) -
         kSectorBytes;
}

// esp_rom_crc32_le semantics (reflected CRC-32, inverted on entry and exit).
inline uint32_t crc32Le(uint32_t crc, const uint8_t *data, size_t length) {
  crc = ~crc;
  for (size_t index = 0; index < length; ++index) {
    crc ^= data[index];
    for (unsigned bit = 0; bit < 8; ++bit)
      crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
  }
  return ~crc;
}

inline uint32_t littleEndian(const uint8_t *bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         static_cast<uint32_t>(bytes[1]) << 8 |
         static_cast<uint32_t>(bytes[2]) << 16 |
         static_cast<uint32_t>(bytes[3]) << 24;
}

// True when WL_Flash::init would accept this copy without reinitialising.
inline bool stateValid(const uint8_t (&state)[kStateBytes]) {
  return crc32Le(UINT32_MAX, state, kStateCrcBytes) ==
             littleEndian(state + kStateCrcBytes) &&
         littleEndian(state + kVersionOffset) == kCurrentVersion;
}

} // namespace wear_levelling_state
