#pragma once

#include <cstddef>
#include <cstdint>

namespace gps_position_protocol {

struct Packet {
  int32_t latitudeMicrodegrees = 0;
  int32_t longitudeMicrodegrees = 0;
  bool hasHeading = false;
  uint16_t headingDegrees = 0;
  bool hasUnixTime = false;
  uint32_t unixTime = 0;
  bool hasSpeed = false;
  uint16_t speedCentimetersPerSecond = 0;
  bool hasAltitude = false;
  int16_t altitudeMeters = 0;
  bool hasDistance = false;
  uint32_t distanceMeters = 0;
  bool hasElapsed = false;
  uint32_t elapsedSeconds = 0;
  bool hasRouteRemaining = false;
  uint32_t routeRemainingMeters = 0;
  bool hasRideDetectionQuality = false;
  bool fixValid = false;
  bool hasHorizontalAccuracy = false;
  uint16_t horizontalAccuracyDecimeters = 0;
  bool hasSampleAge = false;
  uint16_t sampleAgeMs = 0;
};

constexpr std::size_t LEGACY_PACKET_LENGTH = 30;
constexpr std::size_t QUALITY_V1_PACKET_LENGTH = 36;
constexpr uint8_t QUALITY_V1_SCHEMA = 1;
constexpr uint8_t QUALITY_FIX_VALID = 1U << 0;
constexpr uint8_t QUALITY_ACCURACY_AVAILABLE = 1U << 1;
constexpr uint8_t QUALITY_KNOWN_FLAGS =
    QUALITY_FIX_VALID | QUALITY_ACCURACY_AVAILABLE;

inline uint32_t capturedAtMs(uint32_t arrivalMs, uint16_t sampleAgeMs) {
  return arrivalMs - static_cast<uint32_t>(sampleAgeMs);
}

inline uint16_t readUInt16LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint16_t>(bytes[offset]) |
         (static_cast<uint16_t>(bytes[offset + 1]) << 8);
}

inline uint32_t readUInt32LE(const uint8_t *bytes, std::size_t offset) {
  return static_cast<uint32_t>(bytes[offset]) |
         (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
         (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
         (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

inline bool decode(const uint8_t *bytes, std::size_t length, Packet &packet) {
  if (bytes == nullptr || length < 8) {
    return false;
  }
  // The quality extension is an atomic negotiated schema. Treat truncated or
  // oversized extensions as malformed instead of silently downgrading them to
  // a legacy map packet.
  if (length > LEGACY_PACKET_LENGTH &&
      length != QUALITY_V1_PACKET_LENGTH) {
    return false;
  }

  Packet decoded{};
  decoded.latitudeMicrodegrees =
      static_cast<int32_t>(readUInt32LE(bytes, 0));
  decoded.longitudeMicrodegrees =
      static_cast<int32_t>(readUInt32LE(bytes, 4));
  if (length >= 10) {
    const uint16_t heading = readUInt16LE(bytes, 8);
    decoded.hasHeading = heading < 360U;
    decoded.headingDegrees = decoded.hasHeading ? heading : 0U;
  }
  if (length >= 14) {
    decoded.hasUnixTime = true;
    decoded.unixTime = readUInt32LE(bytes, 10);
  }
  if (length >= 16) {
    const uint16_t speed = readUInt16LE(bytes, 14);
    decoded.hasSpeed = speed != UINT16_MAX;
    decoded.speedCentimetersPerSecond = speed;
  }
  if (length >= 18) {
    decoded.hasAltitude = true;
    decoded.altitudeMeters =
        static_cast<int16_t>(readUInt16LE(bytes, 16));
  }
  if (length >= 22) {
    decoded.hasDistance = true;
    decoded.distanceMeters = readUInt32LE(bytes, 18);
  }
  if (length >= 26) {
    decoded.hasElapsed = true;
    decoded.elapsedSeconds = readUInt32LE(bytes, 22);
  }
  if (length >= 30) {
    const uint32_t remaining = readUInt32LE(bytes, 26);
    decoded.hasRouteRemaining = remaining != UINT32_MAX;
    decoded.routeRemainingMeters = remaining;
  }
  if (length == QUALITY_V1_PACKET_LENGTH) {
    const uint8_t schema = bytes[30];
    const uint8_t flags = bytes[31];
    const uint16_t accuracy = readUInt16LE(bytes, 32);
    const uint16_t sampleAge = readUInt16LE(bytes, 34);
    const bool accuracyAvailable =
        (flags & QUALITY_ACCURACY_AVAILABLE) != 0;
    const bool accuracySentinel = accuracy == UINT16_MAX;
    const bool sampleAgeAvailable = sampleAge != UINT16_MAX;
    const bool validCoordinates =
        decoded.latitudeMicrodegrees >= -90'000'000 &&
        decoded.latitudeMicrodegrees <= 90'000'000 &&
        decoded.longitudeMicrodegrees >= -180'000'000 &&
        decoded.longitudeMicrodegrees <= 180'000'000;
    if (schema != QUALITY_V1_SCHEMA || (flags & ~QUALITY_KNOWN_FLAGS) != 0 ||
        accuracyAvailable == accuracySentinel || !validCoordinates ||
        (((flags & QUALITY_FIX_VALID) != 0) &&
         (!decoded.hasSpeed || !accuracyAvailable || !sampleAgeAvailable))) {
      return false;
    }
    decoded.hasRideDetectionQuality = true;
    decoded.fixValid = (flags & QUALITY_FIX_VALID) != 0;
    decoded.hasHorizontalAccuracy = accuracyAvailable;
    decoded.horizontalAccuracyDecimeters =
        accuracyAvailable ? accuracy : 0U;
    decoded.hasSampleAge = sampleAgeAvailable;
    decoded.sampleAgeMs = sampleAgeAvailable ? sampleAge : 0U;
  }
  packet = decoded;
  return true;
}

template <typename RideData>
inline bool decodeAndApply(const uint8_t *bytes, std::size_t length,
                           RideData &rideData,
                           Packet *decodedPacket = nullptr) {
  Packet packet{};
  if (!decode(bytes, length, packet)) {
    return false;
  }

  rideData.latitude =
      static_cast<double>(packet.latitudeMicrodegrees) / 1000000.0;
  rideData.longitude =
      static_cast<double>(packet.longitudeMicrodegrees) / 1000000.0;
  rideData.fixMode = 3;
  rideData.satellites = 10;
  rideData.speed = 0;
  rideData.altitude = 0;
  rideData.distanceTraveled = 0;
  rideData.elapsedSeconds = 0;
  rideData.routeRemaining = 0;
  rideData.hasRouteRemaining = false;

  rideData.headingValid = packet.hasHeading;
  if (packet.hasHeading) {
    rideData.heading = packet.headingDegrees;
  }
  if (packet.hasSpeed) {
    rideData.speed = static_cast<uint16_t>(
        (packet.speedCentimetersPerSecond * 36U + 500U) / 1000U);
  }
  if (packet.hasAltitude) {
    rideData.altitude = packet.altitudeMeters;
  }
  if (packet.hasDistance) {
    rideData.distanceTraveled = packet.distanceMeters;
  }
  if (packet.hasElapsed) {
    rideData.elapsedSeconds = packet.elapsedSeconds;
  }
  if (packet.hasRouteRemaining) {
    rideData.hasRouteRemaining = true;
    rideData.routeRemaining = packet.routeRemainingMeters;
  }
  if (decodedPacket != nullptr) {
    *decodedPacket = packet;
  }
  return true;
}

} // namespace gps_position_protocol
