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
};

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
