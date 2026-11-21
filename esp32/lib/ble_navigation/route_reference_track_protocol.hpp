#pragma once

/**
 * @file route_reference_track_protocol.hpp
 * @brief RTK1 frames: the saved route drawn under a temporary detour.
 *
 * While the phone guides a saved-route detour, the anchored route window on
 * 2A6F carries the detour. RTK1 carries the original route around the detour
 * as a second, unanchored line so the rider still sees where the saved route
 * runs. The frame is replaceable state (no acknowledgement): the phone resends
 * it after reconnecting, and firmware clears it on disconnect and when the
 * route window is cleared.
 *
 * Layout (little endian): "RTK1", version:u8 = 1, operation:u8.
 * - clear (0): nothing follows.
 * - set (1): start latitude:i32, start longitude:i32 (microdegrees), then
 *   delta latitude:i16, delta longitude:i16 per further point; 2...48 points.
 *
 * Malformed frames leave the previous track in place. An unknown version is
 * ignored as unsupported.
 */

#include "ride_ble_protocol.generated.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace route_reference_track_protocol {

namespace generated = ride_ble_protocol_generated;

constexpr size_t HEADER_BYTES = generated::ROUTE_REFERENCE_TRACK_HEADER_BYTES;
constexpr size_t MINIMUM_POINTS = generated::ROUTE_REFERENCE_TRACK_MINIMUM_POINTS;
constexpr size_t MAXIMUM_POINTS = generated::ROUTE_REFERENCE_TRACK_MAXIMUM_POINTS;
constexpr size_t START_POINT_BYTES = 8;
constexpr size_t DELTA_BYTES = 4;
constexpr size_t MAXIMUM_FRAME_BYTES =
    HEADER_BYTES + START_POINT_BYTES + DELTA_BYTES * (MAXIMUM_POINTS - 1);

static_assert(HEADER_BYTES == 6, "RTK1 v1 header is magic, version, operation");
static_assert(MINIMUM_POINTS >= 2 && MAXIMUM_POINTS <= 64,
              "RTK1 tracks hold 2...64 points");

enum class FrameKind : uint8_t {
  Malformed,
  Unsupported,
  Clear,
  Set,
};

struct Point {
  int32_t lat = 0;
  int32_t lon = 0;
};

struct Frame {
  FrameKind kind = FrameKind::Malformed;
  std::array<Point, MAXIMUM_POINTS> points{};
  uint8_t count = 0;
};

inline bool hasFrameMagic(const uint8_t *data, size_t len) {
  return data != nullptr && len >= 4 &&
         std::memcmp(data, generated::ROUTE_REFERENCE_TRACK_MAGIC, 4) == 0;
}

inline bool validCoordinate(int64_t lat, int64_t lon) {
  return lat >= -90'000'000 && lat <= 90'000'000 && lon >= -180'000'000 &&
         lon <= 180'000'000;
}

inline Frame parse(const uint8_t *data, size_t len) {
  Frame frame;
  if (!hasFrameMagic(data, len) || len < HEADER_BYTES)
    return frame;
  if (data[4] != generated::ROUTE_REFERENCE_TRACK_VERSION) {
    frame.kind = FrameKind::Unsupported;
    return frame;
  }
  const uint8_t operation = data[5];
  const size_t body = len - HEADER_BYTES;
  if (operation ==
      static_cast<uint8_t>(generated::RouteReferenceTrackOperation::Clear)) {
    if (body == 0)
      frame.kind = FrameKind::Clear;
    return frame;
  }
  if (operation !=
          static_cast<uint8_t>(generated::RouteReferenceTrackOperation::Set) ||
      body < START_POINT_BYTES || (body - START_POINT_BYTES) % DELTA_BYTES != 0)
    return frame;
  const size_t count = 1 + (body - START_POINT_BYTES) / DELTA_BYTES;
  if (count < MINIMUM_POINTS || count > MAXIMUM_POINTS)
    return frame;

  const uint8_t *geometry = data + HEADER_BYTES;
  int32_t lat = 0;
  int32_t lon = 0;
  std::memcpy(&lat, geometry, 4);
  std::memcpy(&lon, geometry + 4, 4);
  if (!validCoordinate(lat, lon))
    return frame;
  frame.points[0] = {lat, lon};
  for (size_t index = 1; index < count; ++index) {
    const size_t offset = START_POINT_BYTES + (index - 1) * DELTA_BYTES;
    int16_t dLat = 0;
    int16_t dLon = 0;
    std::memcpy(&dLat, geometry + offset, 2);
    std::memcpy(&dLon, geometry + offset + 2, 2);
    const int64_t nextLat = static_cast<int64_t>(lat) + dLat;
    const int64_t nextLon = static_cast<int64_t>(lon) + dLon;
    if (!validCoordinate(nextLat, nextLon))
      return frame;
    lat = static_cast<int32_t>(nextLat);
    lon = static_cast<int32_t>(nextLon);
    frame.points[index] = {lat, lon};
  }
  frame.count = static_cast<uint8_t>(count);
  frame.kind = FrameKind::Set;
  return frame;
}

} // namespace route_reference_track_protocol
