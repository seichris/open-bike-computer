#pragma once
#include "spoken_protocol.hpp"
#include <limits>

namespace spoken_directions {
enum class Admission { accepted, stale, unauthorized, unavailable, malformed };

/// Single-owner policy used by the speech manager. Cross-task callers must
/// enqueue or hold the manager's bounded lock; this class is not a mutex.
class Session {
public:
    Admission control(const Control &c, uint32_t now, bool owner) {
        if (!owner) return Admission::unauthorized;
        if (!valid(c)) return Admission::malformed;
        if (exhausted_) return Admission::unavailable;
        if (c.action == ControlAction::Activate) {
            if (c.revision <= controlRevision_ || c.token == token_) return Admission::stale;
            invalidate();
            if (exhausted_) return Admission::unavailable;
            token_ = c.token; generation_ = c.generation;
            controlRevision_ = c.revision;
            step_ = c.stepId; progress_ = c.progressRevision;
            enabled_ = c.enabled; received_ = now; leaseMs_ = c.leaseMs;
            return Admission::accepted;
        }
        if (!token_ || c.token != token_ || c.generation != generation_) return Admission::stale;
        if (c.action == ControlAction::Progress) {
            if (arriving_ || c.revision != controlRevision_ || c.progressRevision <= progress_)
                return Admission::stale;
            if (c.stepId != step_) phaseMask_ = 0;
            if (c.stepId != step_ || !live(now)) { pending_ = false; advanceEpoch(); }
            step_ = c.stepId; progress_ = c.progressRevision;
            if (!c.enabled) { pending_ = false; advanceEpoch(); }
            if (exhausted_) return Admission::unavailable;
            enabled_ = c.enabled; received_ = now; leaseMs_ = c.leaseMs;
            return Admission::accepted;
        }
        if (c.revision <= controlRevision_) return Admission::stale;
        if (c.action == ControlAction::Arrived && (arriving_ || !live(now))) return Admission::stale;
        controlRevision_ = c.revision;
        if (c.action == ControlAction::Arrived) {
            arriving_ = true; received_ = now; leaseMs_ = 8000;
            if (pending_ && pendingCue_.phase != Phase::Arrival) pending_ = false;
            return Admission::accepted;
        }
        invalidate();
        return Admission::accepted;
    }

    Admission admit(const Cue &c, uint32_t now, bool owner, bool assetAvailable) {
        if (!owner) return Admission::unauthorized;
        if (!valid(c)) return Admission::malformed;
        if (exhausted_) return Admission::unavailable;
        if (!live(now) || arriving_ || c.token != token_ || c.generation != generation_ ||
            c.stepId != step_ || c.progressRevision < progress_ || c.sequence <= sequence_)
            return Admission::stale;
        const auto mask = uint8_t(1U << uint8_t(c.phase));
        if ((phaseMask_ & mask) || (c.phase == Phase::Prepare && (phaseMask_ & (1U << uint8_t(Phase::Action)))))
            return Admission::stale;
        if (!assetAvailable) return Admission::unavailable;
        sequence_ = c.sequence; progress_ = c.progressRevision; phaseMask_ |= mask;
        // One pending slot. Action atomically supersedes unfinished preparation.
        pendingCue_ = c; pending_ = true; admitted_ = now;
        if (c.phase != Phase::Prepare) advanceEpoch();
        return exhausted_ ? Admission::unavailable : Admission::accepted;
    }

    bool take(uint32_t now, Cue &cue) {
        if (!pending_) return false;
        pending_ = false;
        if (!live(now) || uint32_t(now - admitted_) >= pendingCue_.lifetimeMs) return false;
        cue = pendingCue_;
        return true;
    }

    bool live(uint32_t now) const {
        return !exhausted_ && token_ && enabled_ && uint32_t(now - received_) < leaseMs_;
    }
    bool playbackCurrent(const Cue &cue, uint64_t epoch, uint32_t now) const {
        return live(now) && epoch == epoch_ && cue.token == token_ && cue.generation == generation_ &&
            cue.stepId == step_ && (!arriving_ || cue.phase == Phase::Arrival);
    }
    uint64_t epoch() const { return epoch_; }
    uint64_t token() const { return token_; }
    void disconnect() { invalidate(); controlRevision_ = 0; }

private:
    void advanceEpoch() {
        if (epoch_ == std::numeric_limits<uint64_t>::max()) {
            exhausted_ = true; enabled_ = false; pending_ = false; token_ = 0;
        } else { ++epoch_; }
    }
    void invalidate() {
        advanceEpoch(); token_ = 0; generation_ = 0; sequence_ = 0; progress_ = 0;
        step_ = 0; phaseMask_ = 0; enabled_ = false; pending_ = false; arriving_ = false;
    }
    uint64_t token_ = 0, epoch_ = 0;
    uint32_t generation_ = 0, controlRevision_ = 0, step_ = 0, progress_ = 0;
    uint32_t sequence_ = 0, received_ = 0, admitted_ = 0;
    uint16_t leaseMs_ = 0;
    uint8_t phaseMask_ = 0;
    bool enabled_ = false, pending_ = false, arriving_ = false, exhausted_ = false;
    Cue pendingCue_{};
};
} // namespace spoken_directions
