#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace renderer_diagnostics_ble_protocol {

constexpr char METRICS_REQUEST_PREFIX[] = "RDMS";
constexpr char METRICS_RESPONSE_PREFIX[] = "RDMT";
constexpr char METRICS_CHUNK_PREFIX[] = "RDMC";
constexpr char ROUTE_MARKER_PREFIX[] = "RBM1";
constexpr char WINDOW_REQUEST_PREFIX[] = "RBW1";

constexpr size_t PREFIX_BYTES = 4;
constexpr size_t SHA256_BYTES = 32;
constexpr size_t ROUTE_MARKER_BYTES =
    PREFIX_BYTES + SHA256_BYTES + 2 + 2 + 4;
constexpr size_t WINDOW_ROUTE_ID_MAX_BYTES = 48;
constexpr size_t WINDOW_REQUEST_FIXED_BYTES =
    PREFIX_BYTES + 1 + 1 + 2 + 8 + SHA256_BYTES + 1;
constexpr size_t WINDOW_REQUEST_MAX_BYTES =
    WINDOW_REQUEST_FIXED_BYTES + WINDOW_ROUTE_ID_MAX_BYTES;
constexpr uint8_t CURRENT_PROFILE = 1;

struct RouteMarker {
  uint8_t fixtureSha256[SHA256_BYTES]{};
  uint16_t sampleIndex = 0;
  uint16_t sampleCount = 0;
  uint32_t loop = 0;
};

struct WindowRequest {
  uint8_t profile = 0;
  uint16_t repeat = 0;
  uint64_t runNonce = 0;
  uint8_t routeFixtureSha256[SHA256_BYTES]{};
  char routeFixtureId[WINDOW_ROUTE_ID_MAX_BYTES + 1]{};
};

inline bool isCurrentProfileCleanup(const WindowRequest &request,
                                    uint8_t lastAcceptedProfile) {
  return request.profile == CURRENT_PROFILE &&
         lastAcceptedProfile != CURRENT_PROFILE;
}

inline void writeUInt16LE(uint16_t value, uint8_t *output) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8U);
}

inline void writeUInt32LE(uint32_t value, uint8_t *output) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8U);
  output[2] = static_cast<uint8_t>(value >> 16U);
  output[3] = static_cast<uint8_t>(value >> 24U);
}

inline uint16_t readUInt16LE(const uint8_t *input) {
  return static_cast<uint16_t>(input[0]) |
         (static_cast<uint16_t>(input[1]) << 8U);
}

inline uint32_t readUInt32LE(const uint8_t *input) {
  return static_cast<uint32_t>(input[0]) |
         (static_cast<uint32_t>(input[1]) << 8U) |
         (static_cast<uint32_t>(input[2]) << 16U) |
         (static_cast<uint32_t>(input[3]) << 24U);
}

inline void writeUInt64LE(uint64_t value, uint8_t *output) {
  for (size_t index = 0; index < 8; ++index)
    output[index] = static_cast<uint8_t>(value >> (index * 8U));
}

inline uint64_t readUInt64LE(const uint8_t *input) {
  uint64_t value = 0;
  for (size_t index = 0; index < 8; ++index)
    value |= static_cast<uint64_t>(input[index]) << (index * 8U);
  return value;
}

inline bool validWindowIdentityCharacter(char value) {
  return (value >= 'a' && value <= 'z') ||
         (value >= 'A' && value <= 'Z') ||
         (value >= '0' && value <= '9') || value == '-' || value == '_' ||
         value == '.' || value == ':';
}

inline bool isMetricsRequest(const uint8_t *data, size_t length) {
  return data != nullptr && length == PREFIX_BYTES &&
         std::memcmp(data, METRICS_REQUEST_PREFIX, PREFIX_BYTES) == 0;
}

inline bool hasRouteMarkerPrefix(const uint8_t *data, size_t length) {
  return data != nullptr && length >= PREFIX_BYTES &&
         std::memcmp(data, ROUTE_MARKER_PREFIX, PREFIX_BYTES) == 0;
}

inline bool hasWindowRequestPrefix(const uint8_t *data, size_t length) {
  return data != nullptr && length >= PREFIX_BYTES &&
         std::memcmp(data, WINDOW_REQUEST_PREFIX, PREFIX_BYTES) == 0;
}

inline bool encodeWindowRequest(const WindowRequest &request, uint8_t *output,
                                size_t capacity, size_t &written) {
  written = 0;
  size_t routeIdBytes = 0;
  while (routeIdBytes <= WINDOW_ROUTE_ID_MAX_BYTES &&
         request.routeFixtureId[routeIdBytes] != '\0') {
    if (!validWindowIdentityCharacter(request.routeFixtureId[routeIdBytes]))
      return false;
    ++routeIdBytes;
  }
  const size_t required = WINDOW_REQUEST_FIXED_BYTES + routeIdBytes;
  if (output == nullptr || routeIdBytes == 0 ||
      routeIdBytes > WINDOW_ROUTE_ID_MAX_BYTES || capacity < required ||
      request.profile > 3 || request.repeat == 0 || request.runNonce == 0) {
    return false;
  }
  std::memcpy(output, WINDOW_REQUEST_PREFIX, PREFIX_BYTES);
  output[4] = 1;
  output[5] = request.profile;
  writeUInt16LE(request.repeat, output + 6);
  writeUInt64LE(request.runNonce, output + 8);
  std::memcpy(output + 16, request.routeFixtureSha256, SHA256_BYTES);
  output[48] = static_cast<uint8_t>(routeIdBytes);
  std::memcpy(output + WINDOW_REQUEST_FIXED_BYTES, request.routeFixtureId,
              routeIdBytes);
  written = required;
  return true;
}

inline bool decodeWindowRequest(const uint8_t *data, size_t length,
                                WindowRequest &request) {
  if (!hasWindowRequestPrefix(data, length) ||
      length < WINDOW_REQUEST_FIXED_BYTES || length > WINDOW_REQUEST_MAX_BYTES ||
      data[4] != 1) {
    return false;
  }
  const size_t routeIdBytes = data[48];
  if (routeIdBytes == 0 || routeIdBytes > WINDOW_ROUTE_ID_MAX_BYTES ||
      length != WINDOW_REQUEST_FIXED_BYTES + routeIdBytes) {
    return false;
  }
  WindowRequest decoded;
  decoded.profile = data[5];
  decoded.repeat = readUInt16LE(data + 6);
  decoded.runNonce = readUInt64LE(data + 8);
  std::memcpy(decoded.routeFixtureSha256, data + 16, SHA256_BYTES);
  for (size_t index = 0; index < routeIdBytes; ++index) {
    const char character = static_cast<char>(
        data[WINDOW_REQUEST_FIXED_BYTES + index]);
    if (!validWindowIdentityCharacter(character))
      return false;
    decoded.routeFixtureId[index] = character;
  }
  if (decoded.profile > 3 || decoded.repeat == 0 || decoded.runNonce == 0)
    return false;
  request = decoded;
  return true;
}

inline bool encodeRouteMarker(const RouteMarker &marker, uint8_t *output,
                              size_t capacity) {
  if (output == nullptr || capacity < ROUTE_MARKER_BYTES ||
      marker.sampleCount == 0 || marker.sampleIndex >= marker.sampleCount)
    return false;
  std::memcpy(output, ROUTE_MARKER_PREFIX, PREFIX_BYTES);
  std::memcpy(output + PREFIX_BYTES, marker.fixtureSha256, SHA256_BYTES);
  writeUInt16LE(marker.sampleIndex,
                output + PREFIX_BYTES + SHA256_BYTES);
  writeUInt16LE(marker.sampleCount,
                output + PREFIX_BYTES + SHA256_BYTES + 2);
  writeUInt32LE(marker.loop,
                output + PREFIX_BYTES + SHA256_BYTES + 4);
  return true;
}

inline bool decodeRouteMarker(const uint8_t *data, size_t length,
                              RouteMarker &marker) {
  if (!hasRouteMarkerPrefix(data, length) || length != ROUTE_MARKER_BYTES)
    return false;
  RouteMarker decoded;
  std::memcpy(decoded.fixtureSha256, data + PREFIX_BYTES, SHA256_BYTES);
  decoded.sampleIndex =
      readUInt16LE(data + PREFIX_BYTES + SHA256_BYTES);
  decoded.sampleCount =
      readUInt16LE(data + PREFIX_BYTES + SHA256_BYTES + 2);
  decoded.loop = readUInt32LE(data + PREFIX_BYTES + SHA256_BYTES + 4);
  if (decoded.sampleCount == 0 || decoded.sampleIndex >= decoded.sampleCount)
    return false;
  marker = decoded;
  return true;
}

} // namespace renderer_diagnostics_ble_protocol
