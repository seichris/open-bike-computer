#include "../../lib/ble_navigation/workout_telemetry_protocol.hpp"

#include <cassert>
#include <cstring>
#include <limits>

int main() {
  static_assert(workout_telemetry_protocol::FRAME_SIZE == 16);
  static_assert(workout_telemetry_protocol::ORIGIN_FRAME_SIZE == 28);
  static_assert(workout_telemetry_protocol::FALLBACK_PREFIX_SIZE == 4);
  static_assert(workout_telemetry_protocol::FALLBACK_FRAME_SIZE == 20);
  static_assert(workout_telemetry_protocol::CAPABILITY_MASK == 0x80);
  static_assert(workout_telemetry_protocol::METRIC_SOURCE_FLAGS_MASK == 0x1F);
  static_assert(workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT == 0x20);
  static_assert(workout_telemetry_protocol::PAIR_GENERATION_MASK == 0xC0);
  static_assert(workout_telemetry_protocol::SESSION_STATE_MASK == 0x3F);
  static_assert(workout_telemetry_protocol::KNOWN_SOURCE_FLAGS_MASK == 0xFF);
  static_assert(workout_telemetry_protocol::UNAVAILABLE_UINT16 ==
                std::numeric_limits<uint16_t>::max());
  static_assert(workout_telemetry_protocol::UNAVAILABLE_UINT32 ==
                std::numeric_limits<uint32_t>::max());
  static_assert(workout_telemetry_protocol::UNAVAILABLE_ALTITUDE ==
                std::numeric_limits<int16_t>::min());
  assert(std::strcmp(workout_telemetry_protocol::FALLBACK_PREFIX, "WTLM") ==
         0);

  // These are the same exact wire vectors asserted by the iOS builder tests.
  const uint8_t core[workout_telemetry_protocol::FRAME_SIZE] = {
      0x01, 0x02, 0x34, 0x12, 0x4D, 0x0E, 0x00, 0x00,
      0x39, 0x30, 0x00, 0x00, 0xD2, 0x04, 0x9D, 0x00,
  };
  assert(core[0] == static_cast<uint8_t>(
                        workout_telemetry_protocol::FrameKind::Core));
  assert(core[1] == static_cast<uint8_t>(
                        workout_telemetry_protocol::SessionState::Running));
  assert(workout_telemetry_protocol::readUInt16LE(core, 2) == 0x1234);
  assert(workout_telemetry_protocol::readUInt32LE(core, 4) == 3661);
  assert(workout_telemetry_protocol::readUInt32LE(core, 8) == 12345);
  assert(workout_telemetry_protocol::readUInt16LE(core, 12) == 1234);
  assert(workout_telemetry_protocol::readUInt16LE(core, 14) == 157);

  const uint8_t extended[workout_telemetry_protocol::FRAME_SIZE] = {
      0x02, 0x3F, 0x34, 0x12, 0x94, 0x00, 0xD7, 0x11,
      0x41, 0x01, 0x6C, 0x03, 0x04, 0xF4, 0xFF, 0x05,
  };
  assert(extended[0] == static_cast<uint8_t>(
                            workout_telemetry_protocol::FrameKind::Extended));
  assert(extended[1] ==
         (workout_telemetry_protocol::METRIC_SOURCE_FLAGS_MASK |
          workout_telemetry_protocol::SOURCE_CURRENT_SNAPSHOT));
  assert(workout_telemetry_protocol::pairGenerationValue(0x80) == 2);
  assert(workout_telemetry_protocol::readUInt16LE(extended, 2) == 0x1234);
  assert(workout_telemetry_protocol::readUInt16LE(extended, 4) == 148);
  assert(workout_telemetry_protocol::readUInt16LE(extended, 6) == 4567);
  assert(workout_telemetry_protocol::readUInt16LE(extended, 8) == 321);
  assert(workout_telemetry_protocol::readUInt16LE(extended, 10) == 876);
  assert(extended[12] == 4);
  assert(workout_telemetry_protocol::readInt16LE(extended, 13) == -12);
  assert(extended[15] == 5);
  return 0;
}
