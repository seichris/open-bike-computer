#pragma once
#include "../ble_navigation/ride_ble_protocol.generated.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace spoken_directions {
namespace generated = ride_ble_protocol_generated;
using Phase = generated::SpokenPhase;
using Maneuver = generated::SpokenManeuver;
using ControlAction = generated::SpokenControlAction;
using AssetKey = std::array<uint8_t, 16>;
inline uint16_t read16(const uint8_t *p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
inline uint32_t read32(const uint8_t *p) { return uint32_t(read16(p)) | uint32_t(read16(p + 2)) << 16; }
inline uint64_t read64(const uint8_t *p) { return uint64_t(read32(p)) | uint64_t(read32(p + 4)) << 32; }
inline void write32(uint32_t value, uint8_t *p) {
    for (unsigned i = 0; i < 4; ++i) p[i] = uint8_t(value >> (8 * i));
}
inline void write64(uint64_t value, uint8_t *p) { write32(uint32_t(value), p); write32(uint32_t(value >> 32), p + 4); }
inline bool emptyKey(const AssetKey &key) {
    uint8_t combined = 0;
    for (auto byte : key) combined |= byte;
    return combined == 0;
}

struct Cue {
    uint64_t token = 0;
    uint32_t generation = 0, sequence = 0, stepId = 0, progressRevision = 0;
    Phase phase = Phase::Action;
    Maneuver maneuver = Maneuver::Unknown;
    uint16_t distance = 0, lifetimeMs = 0;
    uint8_t volume = 0;
    AssetKey asset{};
};
struct Control {
    uint64_t token = 0;
    uint32_t generation = 0, revision = 0, stepId = 0, progressRevision = 0;
    ControlAction action = ControlAction::Cancel;
    uint16_t leaseMs = 0;
    uint8_t volume = 0;
    bool enabled = false;
};

inline bool validSemantic(Phase phase, Maneuver maneuver, uint16_t distance) {
    const auto m = static_cast<uint8_t>(maneuver);
    if (maneuver == Maneuver::Arrive) return phase == Phase::Arrival && distance == 0;
    if (maneuver == Maneuver::Rerouting || maneuver == Maneuver::ContinueRoute)
        return phase == Phase::Action && distance == 0;
    if (m < 1 || m > 9) return false;
    return (phase == Phase::Action && distance == 0) ||
        (phase == Phase::Prepare && (distance == 50 || distance == 100 || distance == 200));
}
inline bool valid(const Cue &c) {
    return c.token && c.generation && c.sequence && c.stepId && c.progressRevision && c.volume <= 100 &&
        c.lifetimeMs && c.lifetimeMs <= generated::SPOKEN_MAXIMUM_START_LIFETIME_MS &&
        validSemantic(c.phase, c.maneuver, c.distance) && (c.phase == Phase::Prepare || emptyKey(c.asset));
}
inline bool valid(const Control &c) {
    return c.token && c.generation && c.revision && c.stepId && c.progressRevision && c.volume <= 100 &&
        c.leaseMs && c.leaseMs <= generated::SPOKEN_PROGRESS_LEASE_MS &&
        uint8_t(c.action) >= 1 && uint8_t(c.action) <= 4;
}
inline bool decodeCue(const uint8_t *p, size_t size, Cue &out) {
    if (!p || size != generated::SPOKEN_CUE_BYTES ||
        std::memcmp(p, generated::SPOKEN_CUE_MAGIC, 4) != 0 ||
        p[4] != generated::SPOKEN_VERSION || p[7] > 100 ||
        !read64(p + 8) || !read32(p + 16) || !read32(p + 20) ||
        !read32(p + 24) || !read32(p + 28) || !read16(p + 34) ||
        read16(p + 34) > generated::SPOKEN_MAXIMUM_START_LIFETIME_MS ||
        p[36] != (p[5] == uint8_t(Phase::Arrival) ? 1 : 0) || p[37] || p[38] || p[39]) return false;
    Cue c{};
    c.token = read64(p + 8); c.generation = read32(p + 16); c.sequence = read32(p + 20);
    c.stepId = read32(p + 24); c.progressRevision = read32(p + 28);
    c.phase = static_cast<Phase>(p[5]); c.maneuver = static_cast<Maneuver>(p[6]);
    c.distance = read16(p + 32); c.lifetimeMs = read16(p + 34); c.volume = p[7];
    std::memcpy(c.asset.data(), p + 40, c.asset.size());
    if (!valid(c)) return false;
    out = c;
    return true;
}
inline bool decodeControl(const uint8_t *p, size_t size, Control &out) {
    if (!p || size != generated::SPOKEN_CONTROL_BYTES ||
        std::memcmp(p, generated::SPOKEN_CONTROL_MAGIC, 4) != 0 ||
        p[4] != generated::SPOKEN_VERSION || p[5] < 1 || p[5] > 4 || p[6] > 1 || p[7] > 100 ||
        !read64(p + 8) || !read32(p + 16) || !read32(p + 20) || !read32(p + 24) ||
        !read32(p + 28) || !read16(p + 32) || read16(p + 32) > generated::SPOKEN_PROGRESS_LEASE_MS ||
        p[34] || p[35]) return false;
    out = {read64(p + 8), read32(p + 16), read32(p + 20), read32(p + 24), read32(p + 28),
           static_cast<ControlAction>(p[5]), read16(p + 32), p[7], p[6] == 1};
    return true;
}
} // namespace spoken_directions
