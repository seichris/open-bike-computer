#include "../../lib/renderer_diagnostics/renderer_diagnostics_policy.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>

using namespace renderer_diagnostics;

namespace {

RunIdentity runIdentity(const char *routeHash) {
  RunIdentity identity;
  assert(identity.runId.assign("run-20260812-001"));
  assert(identity.mapFixtureId.assign("shanghai-fmb-v4"));
  assert(identity.mapFixtureSha256.assign(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
  assert(identity.routeFixtureId.assign("shanghai-center-v1"));
  assert(identity.routeFixtureSha256.assign(routeHash));
  assert(identity.routeMode.assign("ios-fixture-1hz"));
  identity.repeat = 2;
  return identity;
}

} // namespace

int main() {
  using renderer_tuning::Profile;
  static_assert(renderer_tuning::kCurrent.buildings.maximumRecords == 96);
  static_assert(
      renderer_tuning::kCurrent.buildings.maximumExtrudedRecords == 32);
  static_assert(
      renderer_tuning::kMedium.buildings.maximumExtrudedRecords == 40);
  static_assert(renderer_tuning::kHigh.buildings.maximumExtrudedPoints == 4608);
  static_assert(renderer_tuning::kFlat.buildings.maximumExtrudedPixels == 0);
  static_assert(renderer_tuning::kHigh.buildings.maximumRecords ==
                renderer_tuning::kCurrent.buildings.maximumRecords);
  Profile parsed = Profile::Current;
  assert(renderer_tuning::parse("flat", parsed) && parsed == Profile::Flat);
  assert(renderer_tuning::parse("high", parsed) && parsed == Profile::High);
  assert(!renderer_tuning::parse("custom", parsed));
  assert(renderer_tuning::fingerprint(renderer_tuning::kCurrent) !=
         renderer_tuning::fingerprint(renderer_tuning::kMedium));

  TimingHistogram histogram;
  for (uint32_t sample : {7U, 8U, 9U, 49U, 151U, 501U, 11001U})
    histogram.note(sample);
  const TimingSummary timing = histogram.summary();
  assert(timing.count == 7);
  assert(timing.lastMs == 11001);
  assert(timing.p50Ms == 64);
  assert(timing.p95Ms == 11001);
  assert(timing.maximumMs == 11001);

  TimingHistogram gateAlignedHistogram;
  for (uint32_t index = 0; index < 19; ++index)
    gateAlignedHistogram.note(1249);
  gateAlignedHistogram.note(1300);
  assert(gateAlignedHistogram.summary().p95Ms == 1250);
  TimingHistogram aboveGateHistogram;
  aboveGateHistogram.note(1251);
  assert(aboveGateHistogram.summary().p95Ms == 1500);

  State state;
  BuildIdentity build;
  assert(build.deviceId.assign("0123456789abcdef"));
  assert(build.firmwareCommit.assign("c4f09db675d5"));
  assert(build.board.assign("WAVESHARE_AMOLED_175"));
  assert(build.buildProfile.assign("remote-debug"));
  build.bootId = 0x12345678;
  build.resetReason = 1;
  state.configureBuild(build);
  state.beginSession(true);

  uint8_t preWindowRouteHash[32]{};
  state.noteGpsAuthentication(false, 900);
  state.noteGpsAuthentication(true, 901);
  state.noteReplaySampleDetected(902);
  state.noteReplaySampleDecoded(true, 903);
  state.noteReplayGpsMailbox(true, 904);
  assert(!state.noteRouteMarker(preWindowRouteHash,
                                sizeof(preWindowRouteHash), 1, 90, 0, 905));
  const ReplayTransportDiagnostics preWindowDiagnostics =
      state.replayTransportDiagnostics();
  assert(preWindowDiagnostics.gpsAuthenticationRejected == 1);
  assert(preWindowDiagnostics.gpsAuthenticationAccepted == 1);
  assert(preWindowDiagnostics.rbs1Detected == 1);
  assert(preWindowDiagnostics.rbs1Decoded == 1);
  assert(preWindowDiagnostics.gpsMailboxAccepted == 1);
  assert(preWindowDiagnostics.markerRejectedNoActiveWindow == 1);
  assert(preWindowDiagnostics.lastMarkerResult ==
         ReplayMarkerResult::NoActiveWindow);
  assert(preWindowDiagnostics.lastActiveWindowId == 0);
  assert(preWindowDiagnostics.lastCandidateFixtureTagValid);
  assert(!preWindowDiagnostics.lastExpectedFixtureTagValid);

  constexpr const char *kRouteHash =
      "000102030405060708090a0b0c0d0e0f"
      "101112131415161718191a1b1c1d1e1f";
  assert(state.beginWindow(41, runIdentity(kRouteHash), Profile::Medium, 1000,
                           10));
  assert(state.measurementWindowId() == 41);
  assert(state.replayTransportDiagnostics()
             .markerRejectedNoActiveWindow == 1);
  assert(!state.noteRenderForWindow(40, Profile::Medium, {}));
  assert(!state.noteRenderForWindow(41, Profile::High, {}));
  state.noteMemory(
      {48000, 41000, 30000, 2800000, 1900000, 24576, 20000, 12288,
       7, 11});
  state.noteMemory(
      {47000, 40000, 29000, 2700000, 1800000, 23552, 19000, 11264,
       8, 13});
  state.noteUiLoopGap(87);
  state.noteUiLoopGap(42);
  state.noteDisplayFlushUs(84001);
  state.noteDisplayFlushUs(114000);
  state.noteGpsPacket(11, 0);
  state.noteGpsPacket(13, 1005);
  state.noteGpsPacket(13, 9999);
  state.noteGpsPacket(12, 9999);
  state.noteGpsPacket(14, 1100);
  state.notePrediction(true, false);
  state.notePrediction(true, false);
  state.notePrediction(false, true);
  state.noteInterruptedForWindow(40);
  state.noteCoverageRejectedForWindow(40);
  state.noteInterruptedForWindow(41);
  state.noteCoverageRejectedForWindow(41);

  RenderSample render;
  render.totalMs = 620;
  render.blockLoadMs = 40;
  render.drawMs = 570;
  render.buildingProjectionMs = 120;
  render.buildingDrawMs = 300;
  render.buildings = {130, 96, 40, 56, 34, 2, 96, 177, 212,
                      static_cast<uint8_t>(LimiterExtrudedRecords |
                                           LimiterExtrudedPixels),
                      false};
  assert(state.noteRenderForWindow(41, Profile::Medium, render));
  for (int index = 0; index < 3; ++index) {
    assert(state.noteJobForWindow(41, JobEvent::Requested));
    assert(state.noteJobForWindow(41, JobEvent::Started));
    assert(state.noteJobForWindow(41, JobEvent::Completed));
    assert(state.noteJobForWindow(41, JobEvent::Published));
  }
  assert(!state.noteJobForWindow(40, JobEvent::Requested));

  uint8_t routeHash[32]{};
  for (size_t index = 0; index < sizeof(routeHash); ++index)
    routeHash[index] = static_cast<uint8_t>(index);
  assert(!state.noteRouteMarker(routeHash, sizeof(routeHash), 90, 90, 1, 2000));
  routeHash[0] = 0xff;
  assert(!state.noteRouteMarker(routeHash, sizeof(routeHash), 12, 90, 1, 2000));
  routeHash[0] = 0;
  assert(state.noteRouteMarker(routeHash, sizeof(routeHash), 12, 90, 1, 2001));
  RemoteDebugOverhead remoteDebug;
  remoteDebug.active = true;
  remoteDebug.snapshotBytes = 434312;
  remoteDebug.captured = 7;
  remoteDebug.skippedCadence = 1;
  remoteDebug.skippedLocked = 2;
  remoteDebug.lastCopyUs = 1500;
  remoteDebug.maximumCopyUs = 2300;
  remoteDebug.lastHttpResponseMs = 12;
  remoteDebug.maximumHttpResponseMs = 18;
  remoteDebug.lastFrameSnapshotWaitUs = 110;
  remoteDebug.maximumFrameSnapshotWaitUs = 220;
  remoteDebug.lastFrameCrcUs = 330;
  remoteDebug.maximumFrameCrcUs = 440;
  remoteDebug.lastHttpExpectedBytes = 434344;
  remoteDebug.lastHttpActualBytes = 434344;
  remoteDebug.lastHttpWriteCalls = 215;
  remoteDebug.lastHttpZeroWriteCalls = 4;
  remoteDebug.lastHttpShortWriteCalls = 3;
  remoteDebug.lastHttpActiveTlsWriteUs = 500000;
  remoteDebug.lastHttpNoProgressWaitMs = 1200;
  remoteDebug.lastHttpIntentionalDelayMs = 212;
  remoteDebug.freeBefore = 3000000;
  remoteDebug.largestBefore = 2100000;
  remoteDebug.freeAfterAllocate = 2550000;
  remoteDebug.largestAfterAllocate = 1800000;
  state.noteRemoteDebug(remoteDebug);

  const Snapshot snapshot = state.snapshot(2500);
  assert(snapshot.sequence == 1);
  assert(snapshot.build.bootId == 0x12345678);
  assert(snapshot.build.resetReason == 1);
  assert(snapshot.measurementWindowId == 41);
  assert(snapshot.profile == Profile::Medium);
  assert(snapshot.tuning.buildings.maximumExtrudedRecords == 40);
  assert(snapshot.windowMinimumInternalFree == 47000);
  assert(snapshot.windowMinimumInternalLargest == 29000);
  assert(snapshot.windowMinimumPsramFree == 2700000);
  assert(snapshot.windowMinimumDmaFree == 23552);
  assert(snapshot.windowMinimumDmaLargest == 11264);
  assert(snapshot.memory.cryptoHeadroomRejections == 1);
  assert(snapshot.memory.cryptoOperationFailures == 2);
  assert(snapshot.totalRender.p95Ms == 750);
  assert(snapshot.buildingTotal.lastMs == 420);
  assert(snapshot.displayFlush.p95Ms == 125);
  assert(snapshot.maximumUiGapMs == 87);
  assert(snapshot.gpsPackets == 4);
  assert(snapshot.latestGpsPacketGapMs == 1100);
  assert(snapshot.maximumGpsPacketGapMs == 1100);
  assert(snapshot.predictionGraceEntries == 1);
  assert(snapshot.predictionExhaustionEntries == 1);
  assert(snapshot.jobs.requested == 3);
  assert(snapshot.jobs.started == 3);
  assert(snapshot.jobs.completed == 3);
  assert(snapshot.jobs.published == 3);
  assert(snapshot.interrupted == 1);
  assert(snapshot.coverageRejected == 1);
  assert(snapshot.buildings.extruded == 40);
  assert(snapshot.limiterPasses[3] == 1);
  assert(snapshot.limiterPasses[5] == 1);
  assert(snapshot.routeMarker.accepted == 1);
  assert(snapshot.routeMarker.rejected == 2);
  assert(snapshot.routeFixtureMatches);
  assert(snapshot.replayTransport.markerAccepted == 1);
  assert(snapshot.replayTransport.markerRejectedInvalid == 1);
  assert(snapshot.replayTransport.markerRejectedFixtureMismatch == 1);
  assert(snapshot.replayTransport.markerRejectedNoActiveWindow == 1);
  assert(snapshot.replayTransport.lastMarkerResult ==
         ReplayMarkerResult::Accepted);
  assert(snapshot.replayTransport.lastActiveWindowId == 41);
  assert(snapshot.replayTransport.lastSampleIndex == 12);
  assert(snapshot.replayTransport.lastExpectedFixtureTagValid);
  assert(snapshot.replayTransport.lastCandidateFixtureTagValid);
  assert(snapshot.replayTransport.lastExpectedFixtureTag == 0x00010203U);
  assert(snapshot.replayTransport.lastCandidateFixtureTag == 0x00010203U);
  assert(snapshot.remoteDebug.snapshotBytes == 434312);
  assert(snapshot.remoteDebug.lastHttpExpectedBytes == 434344);
  assert(snapshot.remoteDebug.lastHttpActualBytes == 434344);
  assert(snapshot.remoteDebug.lastHttpZeroWriteCalls == 4);
  assert(snapshot.remoteDebug.lastHttpActiveTlsWriteUs == 500000);

  RenderSample allocationFailure;
  allocationFailure.buildings.allocationFallback = true;
  assert(state.noteRenderForWindow(41, Profile::Medium, allocationFailure));
  assert(state.noteRenderForWindow(41, Profile::Medium, RenderSample{}));
  const Snapshot latchedFailure = state.snapshot(2600);
  assert(latchedFailure.buildings.allocationFallback);

  assert(state.beginWindow(42, runIdentity(kRouteHash), Profile::Flat, 3000,
                           13));
  assert(!state.noteJobForWindow(41, JobEvent::Completed));
  state.noteMemory({0, 0, 0, 0, 0, 0, 0, 0, 8, 13});
  state.noteMemory({100, 100, 100, 100, 100, 100, 100, 100, 9, 15});
  const Snapshot reset = state.snapshot(3001);
  assert(reset.measurementWindowId == 42);
  assert(reset.sequence == 3);
  assert(reset.totalRender.count == 0);
  assert(reset.jobs.requested == 0);
  assert(reset.maximumUiGapMs == 0);
  assert(reset.routeMarker.accepted == 0);
  assert(reset.replayTransport.markerRejectedNoActiveWindow == 1);
  assert(reset.replayTransport.markerAccepted == 1);
  assert(reset.windowMinimumInternalFree == 0);
  assert(reset.windowMinimumPsramFree == 0);
  assert(reset.windowMinimumDmaFree == 0);
  assert(reset.memory.cryptoHeadroomRejections == 1);
  assert(reset.memory.cryptoOperationFailures == 2);
  assert(!reset.buildings.allocationFallback);
  assert(reset.profile == Profile::Flat);
  assert(reset.remoteDebug.active);

  state.endSession();
  const Snapshot ended = state.snapshot(4000);
  assert(ended.profile == Profile::Current);
  assert(ended.measurementWindowId == 0);
  assert(!ended.remoteDebug.active);
  assert(ended.replayTransport.rbs1Detected == 0);
  assert(ended.replayTransport.markerRejectedNoActiveWindow == 0);
  assert(!state.beginWindow(43, runIdentity(kRouteHash), Profile::High, 4001,
                            13));
  assert(state.measurementWindowId() == 0);

  BoundedText<5> bounded;
  assert(bounded.assign("four"));
  assert(!bounded.assign("oversized"));
  assert(std::strcmp(bounded.c_str(), "four") == 0);

  std::cout << "renderer diagnostics policy tests passed\n";
  return 0;
}
