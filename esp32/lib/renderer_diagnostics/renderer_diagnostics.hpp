#pragma once

#include "renderer_diagnostics_policy.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 0
#endif

namespace renderer_diagnostics {

#if FIRMWARE_DIAGNOSTICS
void configureBuildIdentity(const char *deviceId, const char *firmwareCommit,
                            const char *board, const char *buildProfile,
                            uint32_t bootId, uint32_t resetReason);
void beginSession(bool remoteDebugActive, uint32_t nowMs);
void endSession(uint32_t nowMs);
bool sessionActive();
void beginWindow(uint32_t windowId, const RunIdentity &identity,
                 renderer_tuning::Profile profile, uint32_t nowMs,
                 const JobCounters &currentJobs);
void setProfile(renderer_tuning::Profile profile);
renderer_tuning::Profile currentProfile();
void noteLoop(uint32_t nowMs, uint32_t gapMs);
void noteDisplayFlushUs(uint32_t microseconds);
void noteRender(const RenderSample &sample);
void noteJobs(const JobCounters &jobs);
void noteInterrupted();
void noteCoverageRejected();
void noteGpsPacket(uint32_t packetSequence, uint32_t packetGapMs);
void notePrediction(bool graceActive, bool exhausted);
bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
                     uint16_t sampleIndex, uint16_t sampleCount, uint32_t loop,
                     uint32_t nowMs);
void noteRemoteDebug(const RemoteDebugOverhead &overhead);
Snapshot snapshot(uint32_t nowMs);
std::string toJson(const Snapshot &snapshot);
#else
inline void configureBuildIdentity(const char *, const char *, const char *,
                                   const char *, uint32_t, uint32_t) {}
inline void beginSession(bool, uint32_t) {}
inline void endSession(uint32_t) {}
inline bool sessionActive() { return false; }
inline void beginWindow(uint32_t, const RunIdentity &,
                        renderer_tuning::Profile, uint32_t,
                        const JobCounters &) {}
inline void setProfile(renderer_tuning::Profile) {}
inline renderer_tuning::Profile currentProfile() {
  return renderer_tuning::Profile::Current;
}
inline void noteLoop(uint32_t, uint32_t) {}
inline void noteDisplayFlushUs(uint32_t) {}
inline void noteRender(const RenderSample &) {}
inline void noteJobs(const JobCounters &) {}
inline void noteInterrupted() {}
inline void noteCoverageRejected() {}
inline void noteGpsPacket(uint32_t, uint32_t) {}
inline void notePrediction(bool, bool) {}
inline bool noteRouteMarker(const uint8_t *, size_t, uint16_t, uint16_t,
                            uint32_t, uint32_t) {
  return false;
}
inline void noteRemoteDebug(const RemoteDebugOverhead &) {}
inline Snapshot snapshot(uint32_t nowMs) {
  Snapshot value;
  value.timestampMs = nowMs;
  return value;
}
inline std::string toJson(const Snapshot &) { return "{}"; }
#endif

} // namespace renderer_diagnostics
