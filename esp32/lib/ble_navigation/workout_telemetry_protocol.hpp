#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace workout_telemetry_protocol {

constexpr std::size_t FRAME_SIZE = 16;
constexpr std::size_t ORIGIN_FRAME_SIZE = 28;
constexpr std::size_t SESSION_ID_SIZE = 16;
constexpr std::size_t FALLBACK_PREFIX_SIZE = 4;
constexpr std::size_t FALLBACK_FRAME_SIZE =
    FALLBACK_PREFIX_SIZE + FRAME_SIZE;
constexpr char FALLBACK_PREFIX[] = "WTLM";
constexpr uint8_t CAPABILITY_MASK = 1 << 7;
constexpr uint8_t SOURCE_PAIRED_SPEED_SENSOR = 1 << 0;
constexpr uint8_t SOURCE_WATCH_GPS_SPEED = 1 << 1;
constexpr uint8_t SOURCE_HEALTHKIT_DISTANCE = 1 << 2;
constexpr uint8_t SOURCE_WATCH_ALTITUDE = 1 << 3;
constexpr uint8_t SOURCE_LIVE_HEART_RATE_ZONE = 1 << 4;
constexpr uint8_t METRIC_SOURCE_FLAGS_MASK =
    SOURCE_PAIRED_SPEED_SENSOR | SOURCE_WATCH_GPS_SPEED |
    SOURCE_HEALTHKIT_DISTANCE | SOURCE_WATCH_ALTITUDE |
    SOURCE_LIVE_HEART_RATE_ZONE;
constexpr uint8_t SOURCE_CURRENT_SNAPSHOT = 1 << 5;
constexpr uint8_t PAIR_GENERATION_SHIFT = 6;
constexpr uint8_t PAIR_GENERATION_MASK = 0xC0;
constexpr uint8_t SESSION_STATE_MASK = 0x3F;
constexpr uint8_t KNOWN_SOURCE_FLAGS_MASK =
    METRIC_SOURCE_FLAGS_MASK | SOURCE_CURRENT_SNAPSHOT |
    PAIR_GENERATION_MASK;
constexpr uint16_t UNAVAILABLE_UINT16 = UINT16_MAX;
constexpr uint32_t UNAVAILABLE_UINT32 = UINT32_MAX;
constexpr int16_t UNAVAILABLE_ALTITUDE = INT16_MIN;

enum class FrameKind : uint8_t {
  Core = 1,
  Extended = 2,
  Origin = 3,
};

enum class PauseOrigin : uint8_t {
  None = 0,
  Manual = 1,
  Automatic = 2,
  System = 3,
  Unknown = 4,
};

enum class SessionState : uint8_t {
  Idle = 0,
  Starting = 1,
  Running = 2,
  Paused = 3,
  Ending = 4,
  Ended = 5,
  Failed = 6,
};

constexpr uint8_t pairGenerationBits(uint8_t value) {
  return value & PAIR_GENERATION_MASK;
}

constexpr uint8_t pairGenerationValue(uint8_t value) {
  return pairGenerationBits(value) >> PAIR_GENERATION_SHIFT;
}

constexpr uint16_t readUInt16LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint16_t>(bytes[offset]) |
         (static_cast<uint16_t>(bytes[offset + 1]) << 8);
}

constexpr uint32_t readUInt32LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

constexpr int16_t readInt16LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<int16_t>(readUInt16LE(bytes, offset));
}

constexpr bool hasSessionID(
    const std::array<uint8_t, SESSION_ID_SIZE> &sessionID) {
  for (const uint8_t value : sessionID) {
    if (value != 0)
      return true;
  }
  return false;
}

} // namespace workout_telemetry_protocol
