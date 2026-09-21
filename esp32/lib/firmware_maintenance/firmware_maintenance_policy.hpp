#pragma once

#include <cstdint>

namespace firmware_maintenance::policy {

constexpr uint32_t kRequestMagic = 0x4d41544f; // "OTAM" little-endian
constexpr uint16_t kRequestSchema = 1;
constexpr uint32_t kSoftwareResetReason = 3;

struct Request {
  uint32_t magic;
  uint16_t schema;
  uint16_t size;
  uint32_t firmwareFingerprint;
  uint32_t correlation;
  uint32_t checksum;
};

static_assert(sizeof(Request) == 20,
              "maintenance request is an RTC-memory wire format");

constexpr uint32_t mixByte(uint32_t hash, uint8_t value) {
  return (hash ^ value) * 16777619U;
}

constexpr uint32_t mixU16(uint32_t hash, uint16_t value) {
  hash = mixByte(hash, static_cast<uint8_t>(value));
  return mixByte(hash, static_cast<uint8_t>(value >> 8));
}

constexpr uint32_t mixU32(uint32_t hash, uint32_t value) {
  hash = mixU16(hash, static_cast<uint16_t>(value));
  return mixU16(hash, static_cast<uint16_t>(value >> 16));
}

constexpr uint32_t checksum(const Request &request) {
  uint32_t hash = 2166136261U;
  hash = mixU32(hash, request.magic);
  hash = mixU16(hash, request.schema);
  hash = mixU16(hash, request.size);
  hash = mixU32(hash, request.firmwareFingerprint);
  return mixU32(hash, request.correlation);
}

inline Request make(uint32_t firmwareFingerprint, uint32_t correlation) {
  Request request{kRequestMagic, kRequestSchema,
                  static_cast<uint16_t>(sizeof(Request)),
                  firmwareFingerprint,
                  correlation == 0 ? 1U : correlation,
                  0};
  request.checksum = checksum(request);
  return request;
}

constexpr bool valid(const Request &request) {
  return request.magic == kRequestMagic && request.schema == kRequestSchema &&
         request.size == sizeof(Request) && request.firmwareFingerprint != 0 &&
         request.correlation != 0 && request.checksum == checksum(request);
}

inline bool consume(Request &stored, uint32_t firmwareFingerprint,
                    uint32_t resetReason, uint32_t &correlation) {
  const Request candidate = stored;
  stored = {};
  correlation = 0;
  if (resetReason != kSoftwareResetReason || !valid(candidate) ||
      candidate.firmwareFingerprint != firmwareFingerprint) {
    return false;
  }
  correlation = candidate.correlation;
  return true;
}

} // namespace firmware_maintenance::policy
