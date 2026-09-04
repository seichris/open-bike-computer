#pragma once

#include "renderer_diagnostics_policy.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 1
#endif

namespace renderer_diagnostics {

#if FIRMWARE_DIAGNOSTICS
void configureBuildIdentity(const char *deviceId, const char *firmwareCommit,
                            const char *board, const char *buildProfile,
                            uint32_t bootId, uint32_t resetReason);
void beginSession(bool remoteDebugActive, uint32_t nowMs);
void endSession(uint32_t nowMs);
bool sessionActive();
bool beginWindow(uint32_t windowId, const RunIdentity &identity,
                 renderer_tuning::Profile profile, uint32_t nowMs,
                 uint32_t currentGpsPacketSequence);
void setProfile(renderer_tuning::Profile profile);
renderer_tuning::Profile currentProfile();
uint32_t currentWindowId();
void noteLoop(uint32_t nowMs, uint32_t gapMs);
void noteDisplayFlushUs(uint32_t microseconds);
bool noteRenderForWindow(uint32_t windowId,
                         renderer_tuning::Profile profile,
                         const RenderSample &sample);
bool noteJobForWindow(uint32_t windowId, JobEvent event);
void noteInterruptedForWindow(uint32_t windowId);
void noteCoverageRejectedForWindow(uint32_t windowId);
void noteGpsPacket(uint32_t packetSequence, uint32_t packetGapMs);
void notePrediction(bool graceActive, bool exhausted);
void noteGpsAuthentication(bool accepted, uint32_t nowMs);
void noteReplaySampleDetected(uint32_t nowMs);
void noteReplaySampleDecoded(bool accepted, uint32_t nowMs);
void noteReplaySampleUnnegotiated(uint32_t nowMs);
void noteReplayGpsMailbox(bool accepted, uint32_t nowMs);
bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
                     uint16_t sampleIndex, uint16_t sampleCount, uint32_t loop,
                     uint32_t nowMs);
void noteRemoteDebug(const RemoteDebugOverhead &overhead);
void setFrameTransferActive(bool active);
Snapshot snapshot();
std::string toJson(const Snapshot &snapshot);
#else
inline void configureBuildIdentity(const char *, const char *, const char *,
                                   const char *, uint32_t, uint32_t) {}
inline void beginSession(bool, uint32_t) {}
inline void endSession(uint32_t) {}
inline bool sessionActive() { return false; }
inline bool beginWindow(uint32_t, const RunIdentity &,
                        renderer_tuning::Profile, uint32_t,
                        uint32_t) {
  return false;
}
inline void setProfile(renderer_tuning::Profile) {}
inline renderer_tuning::Profile currentProfile() {
  return renderer_tuning::Profile::Current;
}
inline uint32_t currentWindowId() { return 0; }
inline void noteLoop(uint32_t, uint32_t) {}
inline void noteDisplayFlushUs(uint32_t) {}
inline bool noteRenderForWindow(uint32_t, renderer_tuning::Profile,
                                const RenderSample &) {
  return false;
}
inline bool noteJobForWindow(uint32_t, JobEvent) { return false; }
inline void noteInterruptedForWindow(uint32_t) {}
inline void noteCoverageRejectedForWindow(uint32_t) {}
inline void noteGpsPacket(uint32_t, uint32_t) {}
inline void notePrediction(bool, bool) {}
inline void noteGpsAuthentication(bool, uint32_t) {}
inline void noteReplaySampleDetected(uint32_t) {}
inline void noteReplaySampleDecoded(bool, uint32_t) {}
inline void noteReplaySampleUnnegotiated(uint32_t) {}
inline void noteReplayGpsMailbox(bool, uint32_t) {}
inline bool noteRouteMarker(const uint8_t *, size_t, uint16_t, uint16_t,
                            uint32_t, uint32_t) {
  return false;
}
inline void noteRemoteDebug(const RemoteDebugOverhead &) {}
inline void setFrameTransferActive(bool) {}
inline Snapshot snapshot() { return {}; }
inline std::string toJson(const Snapshot &) { return "{}"; }
#endif

} // namespace renderer_diagnostics
