#pragma once

#include "workout_zone_wire.generated.hpp"
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace workout_zones {
using namespace workout_zone_wire;

// Internal profiles only until both physical board/Watch qualification gates
// pass. Older/production peers never advertise the capability or accept frames.
#if defined(FIRMWARE_DIAGNOSTICS) && FIRMWARE_DIAGNOSTICS
inline constexpr bool ENABLED = true;
#else
inline constexpr bool ENABLED = false;
#endif

struct Metric {
  bool received = false;
  uint8_t source = 0;
  uint8_t flags = 0;
  uint8_t count = 0;
  uint8_t current = 0; // one-based; zero is unavailable, never zone zero
  uint32_t sequence = 0;
  uint32_t receivedAtMs = 0;
  uint16_t sampleAgeMs = UINT16_MAX;
  std::array<double, MAXIMUM_ZONES - 1> boundaries{};
  std::array<uint32_t, MAXIMUM_ZONES> milliseconds{};

  bool final() const { return (flags & FLAG_FINAL) != 0; }
  bool durations() const { return (flags & FLAG_DURATIONS) != 0; }
  bool native() const { return source != SOURCE_BICINO; }
};
inline bool operator==(const Metric &a, const Metric &b) {
  return a.received == b.received && a.source == b.source && a.flags == b.flags &&
         a.count == b.count && a.current == b.current && a.sequence == b.sequence &&
         a.receivedAtMs == b.receivedAtMs && a.sampleAgeMs == b.sampleAgeMs &&
         a.boundaries == b.boundaries && a.milliseconds == b.milliseconds;
}
struct State {
  std::array<uint8_t, 16> sessionID{};
  Metric heartRate{};
  Metric power{};
};
inline bool operator==(const State &a, const State &b) {
  return a.sessionID == b.sessionID && a.heartRate == b.heartRate && a.power == b.power;
}

struct Packet {
  uint8_t metric = 0;
  uint8_t state = 0;
  uint8_t pairGeneration = 0;
  uint16_t token = 0;
  std::array<uint8_t, 16> sessionID{};
  Metric value{};
};
inline uint64_t readLE(const uint8_t *p, std::size_t bytes) {
  uint64_t value = 0;
  for (std::size_t i = 0; i < bytes; ++i) value |= uint64_t(p[i]) << (i * 8);
  return value;
}
inline bool decode(const uint8_t *data, std::size_t size, Packet &out) {
  static_assert(sizeof(double) == 8 && std::numeric_limits<double>::is_iec559,
                "zone thresholds require IEEE-754 binary64");
  if (!data || size < HEADER_BYTES || size > MAXIMUM_FRAME_BYTES ||
      data[0] != FRAME_KIND || data[1] != ZONE_WIRE_VERSION ||
      (data[2] != METRIC_HEART_RATE && data[2] != METRIC_CYCLING_POWER) ||
      data[3] > SOURCE_HEALTHKIT_UNKNOWN || (data[4] & ~uint8_t(7)) != 0 ||
      (data[7] & 0x3F) == 0 || (data[7] & 0x3F) > 6) return false;
  const uint8_t count = data[5];
  if (count != 0 && (count < MINIMUM_ZONES || count > MAXIMUM_ZONES)) return false;
  const std::size_t expected = HEADER_BYTES + (count ? (count - 1) * 8 + count * 4 : 0);
  if (size != expected || data[6] > count || readLE(data + 8, 2) == 0 ||
      readLE(data + 12, 4) == 0) return false;
  Packet candidate{};
  candidate.metric = data[2];
  candidate.state = data[7] & 0x3F;
  candidate.pairGeneration = data[7] >> 6;
  candidate.token = uint16_t(readLE(data + 8, 2));
  std::memcpy(candidate.sessionID.data(), data + 16, 16);
  bool nonzero = false;
  for (auto b : candidate.sessionID) nonzero |= b != 0;
  if (!nonzero) return false;
  Metric &value = candidate.value;
  value.received = true;
  value.source = data[3]; value.flags = data[4]; value.count = count; value.current = data[6];
  value.sampleAgeMs = uint16_t(readLE(data + 10, 2));
  value.sequence = uint32_t(readLE(data + 12, 4));
  if (!count && (value.flags || value.current || value.sampleAgeMs != UINT16_MAX)) return false;
  if ((value.current == 0) != (value.sampleAgeMs == UINT16_MAX)) return false;
  if (value.final() && (candidate.state != 5 || value.current || !value.durations())) return false;
  if (value.current && (candidate.state != 2 || value.final())) return false;
  // Never represent a non-final populated group as a saved-workout summary.
  if (count && candidate.state == 5 && !value.final()) return false;
  if (count && (candidate.state == 4 || candidate.state == 6)) return false;
  if (value.source == SOURCE_BICINO && count &&
      (candidate.metric != METRIC_HEART_RATE || count != 5)) return false;
  const uint32_t maximumAge = candidate.metric == METRIC_HEART_RATE
      ? HEART_RATE_MAXIMUM_AGE_MS : POWER_MAXIMUM_AGE_MS;
  if (value.current && value.sampleAgeMs >= maximumAge) return false;
  std::size_t offset = HEADER_BYTES;
  for (uint8_t i = 0; i + 1 < count; ++i) {
    const uint64_t bits = readLE(data + offset, 8);
    double boundary;
    std::memcpy(&boundary, &bits, 8);
    if (!std::isfinite(boundary) || boundary <= 0 ||
        (i && boundary <= value.boundaries[i - 1])) return false;
    value.boundaries[i] = boundary;
    offset += 8;
  }
  for (uint8_t i = 0; i < count; ++i) {
    value.milliseconds[i] = uint32_t(readLE(data + offset, 4));
    if (value.durations() == (value.milliseconds[i] == UINT32_MAX)) return false;
    offset += 4;
  }
  out = candidate; // invalid packets never partially mutate retained state
  return true;
}

inline uint64_t totalMilliseconds(const Metric &value) {
  uint64_t total = 0;
  if (value.durations()) for (uint8_t i = 0; i < value.count; ++i) total += value.milliseconds[i];
  return total;
}
inline void expire(Metric &value, bool running, bool linkStale, uint32_t now, uint32_t maximumAge) {
  if (value.final()) return;
  const uint32_t residence = now - value.receivedAtMs; // millis wrap-safe
  if (!running || linkStale || residence >= STREAM_MAXIMUM_AGE_MS ||
      uint64_t(value.sampleAgeMs) + residence >= maximumAge) value.current = 0;
}
inline void expire(State &state, bool running, bool linkStale, uint32_t now) {
  expire(state.heartRate, running, linkStale, now, HEART_RATE_MAXIMUM_AGE_MS);
  expire(state.power, running, linkStale, now, POWER_MAXIMUM_AGE_MS);
}
} // namespace workout_zones
