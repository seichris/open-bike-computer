#include "renderer_diagnostics.hpp"

#if FIRMWARE_DIAGNOSTICS

#include "../ble_navigation/device_ownership_crypto_resource.hpp"

#include <esp_heap_caps.h>
#include <freertos/FreeRTOS.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <new>
#include <sstream>

namespace renderer_diagnostics {
namespace {

portMUX_TYPE diagnosticsMux = portMUX_INITIALIZER_UNLOCKED;
State diagnosticsState;
uint32_t lastPeriodicMemorySampleMs = 0;

MemorySample memorySample() {
  constexpr uint32_t kInternalCaps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  const device_ownership::CryptoResourceDiagnostics crypto =
      device_ownership::cryptoResourceDiagnostics();
  return {
      static_cast<uint32_t>(heap_caps_get_free_size(kInternalCaps)),
      static_cast<uint32_t>(heap_caps_get_minimum_free_size(kInternalCaps)),
      static_cast<uint32_t>(heap_caps_get_largest_free_block(kInternalCaps)),
      static_cast<uint32_t>(heap_caps_get_free_size(MALLOC_CAP_SPIRAM)),
      static_cast<uint32_t>(
          heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM)),
      static_cast<uint32_t>(heap_caps_get_free_size(MALLOC_CAP_DMA)),
      static_cast<uint32_t>(
          heap_caps_get_minimum_free_size(MALLOC_CAP_DMA)),
      static_cast<uint32_t>(
          heap_caps_get_largest_free_block(MALLOC_CAP_DMA)),
      crypto.headroomRejections,
      crypto.operationFailures,
  };
}

void noteCurrentMemory() {
  const MemorySample sample = memorySample();
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteMemory(sample);
  portEXIT_CRITICAL(&diagnosticsMux);
}

std::string jsonEscape(const char *value) {
  std::string result;
  if (value == nullptr)
    return result;
  for (const unsigned char character : std::string(value)) {
    switch (character) {
    case '"':
      result += "\\\"";
      break;
    case '\\':
      result += "\\\\";
      break;
    case '\b':
      result += "\\b";
      break;
    case '\f':
      result += "\\f";
      break;
    case '\n':
      result += "\\n";
      break;
    case '\r':
      result += "\\r";
      break;
    case '\t':
      result += "\\t";
      break;
    default:
      if (character < 0x20) {
        char escaped[7] = {};
        std::snprintf(escaped, sizeof(escaped), "\\u%04x", character);
        result += escaped;
      } else {
        result.push_back(static_cast<char>(character));
      }
      break;
    }
  }
  return result;
}

void appendTiming(std::ostringstream &body, const TimingSummary &value) {
  body << "{\"count\":" << value.count << ",\"lastMs\":" << value.lastMs
       << ",\"p50Ms\":" << value.p50Ms << ",\"p95Ms\":" << value.p95Ms
       << ",\"maximumMs\":" << value.maximumMs << "}";
}

std::string routeMarkerHash(const RouteMarker &marker) {
  if (!marker.valid)
    return "";
  static constexpr char kHex[] = "0123456789abcdef";
  std::string value(marker.fixtureSha256.size() * 2U, '0');
  for (size_t index = 0; index < marker.fixtureSha256.size(); ++index) {
    value[index * 2] = kHex[marker.fixtureSha256[index] >> 4U];
    value[index * 2 + 1] = kHex[marker.fixtureSha256[index] & 0x0fU];
  }
  return value;
}

} // namespace

void configureBuildIdentity(const char *deviceId, const char *firmwareCommit,
                            const char *board, const char *buildProfile,
                            uint32_t bootId, uint32_t resetReason) {
  BuildIdentity identity;
  if (!identity.deviceId.assign(deviceId) ||
      !identity.firmwareCommit.assign(firmwareCommit) ||
      !identity.board.assign(board) ||
      !identity.buildProfile.assign(buildProfile)) {
    return;
  }
  identity.bootId = bootId;
  identity.resetReason = resetReason;
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.configureBuild(identity);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void beginSession(bool remoteDebugActive, uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.beginSession(remoteDebugActive);
  lastPeriodicMemorySampleMs = nowMs;
  portEXIT_CRITICAL(&diagnosticsMux);
  noteCurrentMemory();
}

void endSession(uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.endSession();
  lastPeriodicMemorySampleMs = nowMs;
  portEXIT_CRITICAL(&diagnosticsMux);
  noteCurrentMemory();
}

bool sessionActive() {
  portENTER_CRITICAL(&diagnosticsMux);
  const bool active = diagnosticsState.sessionActive();
  portEXIT_CRITICAL(&diagnosticsMux);
  return active;
}

bool beginWindow(uint32_t windowId, const RunIdentity &identity,
                 renderer_tuning::Profile profile, uint32_t nowMs,
                 const JobCounters &currentJobs,
                 uint32_t currentGpsPacketSequence) {
  portENTER_CRITICAL(&diagnosticsMux);
  const bool accepted = diagnosticsState.beginWindow(
      windowId, identity, profile, nowMs, currentJobs,
      currentGpsPacketSequence);
  if (accepted)
    lastPeriodicMemorySampleMs = nowMs;
  portEXIT_CRITICAL(&diagnosticsMux);
  if (accepted)
    noteCurrentMemory();
  return accepted;
}

void setProfile(renderer_tuning::Profile profile) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.setProfile(profile);
  portEXIT_CRITICAL(&diagnosticsMux);
}

renderer_tuning::Profile currentProfile() {
  portENTER_CRITICAL(&diagnosticsMux);
  const renderer_tuning::Profile profile = diagnosticsState.profile();
  portEXIT_CRITICAL(&diagnosticsMux);
  return profile;
}

uint32_t currentWindowId() {
  portENTER_CRITICAL(&diagnosticsMux);
  const uint32_t windowId = diagnosticsState.measurementWindowId();
  portEXIT_CRITICAL(&diagnosticsMux);
  return windowId;
}

void noteLoop(uint32_t nowMs, uint32_t gapMs) {
  bool sampleMemory = false;
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteUiLoopGap(gapMs);
  if (lastPeriodicMemorySampleMs == 0 ||
      static_cast<uint32_t>(nowMs - lastPeriodicMemorySampleMs) >= 1000U) {
    lastPeriodicMemorySampleMs = nowMs;
    sampleMemory = true;
  }
  portEXIT_CRITICAL(&diagnosticsMux);
  if (sampleMemory)
    noteCurrentMemory();
}

void noteDisplayFlushUs(uint32_t microseconds) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteDisplayFlushUs(microseconds);
  portEXIT_CRITICAL(&diagnosticsMux);
}

bool noteRenderForWindow(uint32_t windowId,
                         renderer_tuning::Profile profile,
                         const RenderSample &sample) {
  const MemorySample memory = memorySample();
  portENTER_CRITICAL(&diagnosticsMux);
  const bool accepted =
      diagnosticsState.noteRenderForWindow(windowId, profile, sample);
  if (accepted)
    diagnosticsState.noteMemory(memory);
  portEXIT_CRITICAL(&diagnosticsMux);
  return accepted;
}

void noteJobs(const JobCounters &jobs) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteJobs(jobs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteInterrupted() {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteInterrupted();
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteCoverageRejected() {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteCoverageRejected();
  portEXIT_CRITICAL(&diagnosticsMux);
}

void noteGpsPacket(uint32_t packetSequence, uint32_t packetGapMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteGpsPacket(packetSequence, packetGapMs);
  portEXIT_CRITICAL(&diagnosticsMux);
}

void notePrediction(bool graceActive, bool exhausted) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.notePrediction(graceActive, exhausted);
  portEXIT_CRITICAL(&diagnosticsMux);
}

bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
                     uint16_t sampleIndex, uint16_t sampleCount, uint32_t loop,
                     uint32_t nowMs) {
  portENTER_CRITICAL(&diagnosticsMux);
  const bool accepted = diagnosticsState.noteRouteMarker(
      fixtureSha256, hashBytes, sampleIndex, sampleCount, loop, nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
  return accepted;
}

void noteRemoteDebug(const RemoteDebugOverhead &overhead) {
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteRemoteDebug(overhead);
  portEXIT_CRITICAL(&diagnosticsMux);
}

Snapshot snapshot(uint32_t nowMs) {
  const MemorySample memory = memorySample();
  portENTER_CRITICAL(&diagnosticsMux);
  diagnosticsState.noteMemory(memory);
  Snapshot value = diagnosticsState.snapshot(nowMs);
  portEXIT_CRITICAL(&diagnosticsMux);
  return value;
}

std::string toJson(const Snapshot &value) {
  try {
    const renderer_tuning::BuildingQuotas &quotas = value.tuning.buildings;
    std::ostringstream body;
    body << "{\"ok\":true,\"schema\":" << static_cast<unsigned>(value.schema)
       << ",\"sequence\":" << value.sequence
       << ",\"timestampMs\":" << value.timestampMs
       << ",\"window\":{\"id\":" << value.measurementWindowId
       << ",\"startedAtMs\":" << value.windowStartedAtMs
       << ",\"runId\":\"" << jsonEscape(value.run.runId.c_str())
       << "\",\"repeat\":" << value.run.repeat << "}"
       << ",\"identity\":{\"deviceId\":\""
       << jsonEscape(value.build.deviceId.c_str())
       << "\",\"firmwareCommit\":\""
       << jsonEscape(value.build.firmwareCommit.c_str())
       << "\",\"board\":\"" << jsonEscape(value.build.board.c_str())
       << "\",\"buildProfile\":\""
       << jsonEscape(value.build.buildProfile.c_str())
       << "\",\"bootId\":" << value.build.bootId
       << ",\"resetReason\":" << value.build.resetReason
       << ",\"mapFixture\":{\"id\":\""
       << jsonEscape(value.run.mapFixtureId.c_str())
       << "\",\"sha256\":\""
       << jsonEscape(value.run.mapFixtureSha256.c_str())
       << "\"},\"routeFixture\":{\"id\":\""
       << jsonEscape(value.run.routeFixtureId.c_str())
       << "\",\"sha256\":\""
       << jsonEscape(value.run.routeFixtureSha256.c_str())
       << "\",\"mode\":\"" << jsonEscape(value.run.routeMode.c_str())
       << "\"}}"
       << ",\"tuning\":{\"profile\":\""
       << renderer_tuning::name(value.profile)
       << "\",\"fingerprint\":" << renderer_tuning::fingerprint(value.tuning)
       << ",\"minimumExtrusionAreaPx2\":"
       << value.tuning.minimumExtrusionAreaPixels
       << ",\"total\":{\"records\":" << quotas.maximumRecords
       << ",\"points\":" << quotas.maximumPoints
       << ",\"projectedPixels\":" << quotas.maximumProjectedPixels
       << "},\"extrusion\":{\"records\":"
       << quotas.maximumExtrudedRecords << ",\"points\":"
       << quotas.maximumExtrudedPoints << ",\"projectedPixels\":"
       << quotas.maximumExtrudedPixels << "}}"
       << ",\"memory\":{\"internalHeap\":{\"free\":"
       << value.memory.internalFree << ",\"minimumEverFree\":"
       << value.memory.internalMinimumEverFree << ",\"largestBlock\":"
       << value.memory.internalLargest << ",\"windowMinimumFree\":"
       << value.windowMinimumInternalFree
       << ",\"windowMinimumLargestBlock\":"
       << value.windowMinimumInternalLargest
       << "},\"psram\":{\"free\":" << value.memory.psramFree
       << ",\"largestBlock\":" << value.memory.psramLargest
       << ",\"windowMinimumFree\":" << value.windowMinimumPsramFree
       << ",\"windowMinimumLargestBlock\":"
       << value.windowMinimumPsramLargest << "}"
       << ",\"dmaHeap\":{\"free\":" << value.memory.dmaFree
       << ",\"minimumEverFree\":" << value.memory.dmaMinimumEverFree
       << ",\"largestBlock\":" << value.memory.dmaLargest
       << ",\"windowMinimumFree\":" << value.windowMinimumDmaFree
       << ",\"windowMinimumLargestBlock\":"
       << value.windowMinimumDmaLargest
       << ",\"cryptoHeadroomRejections\":"
       << value.memory.cryptoHeadroomRejections
       << ",\"cryptoOperationFailures\":"
       << value.memory.cryptoOperationFailures << "}}"
       << ",\"render\":{\"timings\":{\"total\":";
    appendTiming(body, value.totalRender);
    body << ",\"blockLoad\":";
    appendTiming(body, value.blockLoad);
    body << ",\"draw\":";
    appendTiming(body, value.draw);
    body << ",\"buildingProjection\":";
    appendTiming(body, value.buildingProjection);
    body << ",\"buildingDraw\":";
    appendTiming(body, value.buildingDraw);
    body << ",\"buildingTotal\":";
    appendTiming(body, value.buildingTotal);
    body << "},\"buildings\":{\"candidates\":" << value.buildings.candidates
       << ",\"selected\":" << value.buildings.selected
       << ",\"extruded\":" << value.buildings.extruded
       << ",\"flat\":" << value.buildings.flat
       << ",\"deferred\":" << value.buildings.deferred
       << ",\"oversized\":" << value.buildings.oversized
       << ",\"rendered\":" << value.buildings.rendered
       << ",\"allocationFallback\":"
       << (value.buildings.allocationFallback ? "true" : "false")
       << ",\"extrudedP90DistancePx\":"
       << value.buildings.extrudedP90DistancePx
       << ",\"extrudedFarthestDistancePx\":"
       << value.buildings.extrudedFarthestDistancePx
       << ",\"limiterFlags\":"
       << static_cast<unsigned>(value.buildings.limiterFlags)
       << ",\"limiterPasses\":{\"records\":" << value.limiterPasses[0]
       << ",\"points\":" << value.limiterPasses[1]
       << ",\"projectedPixels\":" << value.limiterPasses[2]
       << ",\"extrudedRecords\":" << value.limiterPasses[3]
       << ",\"extrudedPoints\":" << value.limiterPasses[4]
       << ",\"extrudedPixels\":" << value.limiterPasses[5] << "}}"
       << ",\"jobs\":{\"requested\":" << value.jobs.requested
       << ",\"started\":" << value.jobs.started
       << ",\"completed\":" << value.jobs.completed
       << ",\"published\":" << value.jobs.published
       << ",\"stale\":" << value.jobs.stale
       << ",\"cancelled\":" << value.jobs.cancelled
       << ",\"interrupted\":" << value.interrupted
       << ",\"coverageRejected\":" << value.coverageRejected
       << ",\"invariantFailed\":" << value.jobs.invariantFailed << "}}"
       << ",\"ui\":{\"maximumGapMs\":" << value.maximumUiGapMs << "}"
       << ",\"displayFlush\":";
    appendTiming(body, value.displayFlush);
    body << ",\"gps\":{\"packets\":" << value.gpsPackets
       << ",\"latestPacketGapMs\":" << value.latestGpsPacketGapMs
       << ",\"maximumPacketGapMs\":"
       << value.maximumGpsPacketGapMs << ",\"predictionGraceEntries\":"
       << value.predictionGraceEntries
       << ",\"predictionExhaustionEntries\":"
       << value.predictionExhaustionEntries << "}"
       << ",\"routeReplay\":{\"valid\":"
       << (value.routeMarker.valid ? "true" : "false")
       << ",\"fixtureSha256\":\"" << routeMarkerHash(value.routeMarker)
       << "\",\"fixtureMatches\":"
       << (value.routeFixtureMatches ? "true" : "false")
       << ",\"sampleIndex\":" << value.routeMarker.sampleIndex
       << ",\"sampleCount\":" << value.routeMarker.sampleCount
       << ",\"loop\":" << value.routeMarker.loop
       << ",\"receivedAtMs\":" << value.routeMarker.receivedAtMs
       << ",\"accepted\":" << value.routeMarker.accepted
       << ",\"rejected\":" << value.routeMarker.rejected << "}"
       << ",\"remoteDebug\":{\"active\":"
       << (value.remoteDebug.active ? "true" : "false")
       << ",\"snapshotBytes\":" << value.remoteDebug.snapshotBytes
       << ",\"captured\":" << value.remoteDebug.captured
       << ",\"skippedCadence\":" << value.remoteDebug.skippedCadence
       << ",\"skippedLocked\":" << value.remoteDebug.skippedLocked
       << ",\"captureErrors\":" << value.remoteDebug.captureErrors
       << ",\"lastCopyUs\":" << value.remoteDebug.lastCopyUs
       << ",\"maximumCopyUs\":" << value.remoteDebug.maximumCopyUs
       << ",\"lastHttpResponseMs\":"
       << value.remoteDebug.lastHttpResponseMs
       << ",\"maximumHttpResponseMs\":"
       << value.remoteDebug.maximumHttpResponseMs
       << ",\"freeBefore\":" << value.remoteDebug.freeBefore
       << ",\"largestBefore\":" << value.remoteDebug.largestBefore
       << ",\"freeAfterAllocate\":"
       << value.remoteDebug.freeAfterAllocate
       << ",\"largestAfterAllocate\":"
       << value.remoteDebug.largestAfterAllocate << "}}";
    return body.str();
  } catch (const std::bad_alloc &) {
    return {};
  }
}

} // namespace renderer_diagnostics

#endif // FIRMWARE_DIAGNOSTICS
