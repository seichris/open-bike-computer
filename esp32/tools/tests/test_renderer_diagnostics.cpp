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

JobCounters jobs(uint32_t offset) {
  return {10U + offset, 9U + offset, 8U + offset, 7U + offset,
          6U + offset, 5U + offset, 4U + offset};
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

  State state;
  BuildIdentity build;
  assert(build.deviceId.assign("0123456789abcdef"));
  assert(build.firmwareCommit.assign("c4f09db675d5"));
  assert(build.board.assign("WAVESHARE_AMOLED_175"));
  assert(build.buildProfile.assign("remote-debug"));
  build.bootId = 0x12345678;
  build.resetReason = 1;
  state.configureBuild(build);
  state.noteJobs(jobs(0));
  state.beginSession(true);

  constexpr const char *kRouteHash =
      "000102030405060708090a0b0c0d0e0f"
      "101112131415161718191a1b1c1d1e1f";
  assert(state.beginWindow(41, runIdentity(kRouteHash), Profile::Medium, 1000,
                           jobs(0), 10));
  assert(state.measurementWindowId() == 41);
  assert(!state.noteRenderForWindow(40, Profile::Medium, {}));
  assert(!state.noteRenderForWindow(41, Profile::High, {}));
  state.noteMemory(
      {48000, 41000, 30000, 2800000, 1900000, 24576, 20000, 12288,
       0, 0});
  state.noteMemory(
      {47000, 40000, 29000, 2700000, 1800000, 23552, 19000, 11264,
       1, 2});
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
  state.noteInterrupted();
  state.noteCoverageRejected();

  RenderSample render;
  render.totalMs = 620;
  render.blockLoadMs = 40;
  render.drawMs = 570;
  render.buildingProjectionMs = 120;
  render.buildingDrawMs = 300;
  render.poiGatherMs = 8;
  render.poiLayoutMs = 5;
  render.poiDrawMs = 3;
  render.buildings = {130, 96, 40, 56, 34, 2, 96, 177, 212,
                      static_cast<uint8_t>(LimiterExtrudedRecords |
                                           LimiterExtrudedPixels),
                      false};
  render.pois = {47, 12, 21, 3, 11, 52, 416, {2, 3, 1, 4, 2}};
  assert(state.noteRenderForWindow(41, Profile::Medium, render));
  state.noteJobs(jobs(3));

  uint8_t routeHash[32]{};
  for (size_t index = 0; index < sizeof(routeHash); ++index)
    routeHash[index] = static_cast<uint8_t>(index);
  assert(!state.noteRouteMarker(routeHash, sizeof(routeHash), 90, 90, 1, 2000));
  routeHash[0] = 0xff;
  assert(!state.noteRouteMarker(routeHash, sizeof(routeHash), 12, 90, 1, 2000));
  routeHash[0] = 0;
  assert(state.noteRouteMarker(routeHash, sizeof(routeHash), 12, 90, 1, 2001));
  state.noteRemoteDebug({true, 434312, 7, 1, 2, 0, 1500, 2300, 12, 18,
                         3000000, 2100000, 2550000, 1800000});

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
  assert(snapshot.poiTotal.lastMs == 16);
  assert(snapshot.displayFlush.p95Ms == 125);
  assert(snapshot.maximumUiGapMs == 87);
  assert(snapshot.gpsPackets == 4);
  assert(snapshot.latestGpsPacketGapMs == 1100);
  assert(snapshot.maximumGpsPacketGapMs == 1100);
  assert(snapshot.predictionGraceEntries == 1);
  assert(snapshot.predictionExhaustionEntries == 1);
  assert(snapshot.jobs.requested == 3);
  assert(snapshot.jobs.published == 3);
  assert(snapshot.interrupted == 1);
  assert(snapshot.coverageRejected == 1);
  assert(snapshot.buildings.extruded == 40);
  assert(snapshot.pois.candidates == 47);
  assert(snapshot.pois.accepted == 12);
  assert(snapshot.pois.capacityDeferred == 11);
  assert(snapshot.pois.decodedRecords == 52);
  assert(snapshot.pois.decodedBytes == 416);
  assert(snapshot.pois.acceptedCategories[3] == 4);
  assert(snapshot.limiterPasses[3] == 1);
  assert(snapshot.limiterPasses[5] == 1);
  assert(snapshot.routeMarker.accepted == 1);
  assert(snapshot.routeMarker.rejected == 2);
  assert(snapshot.routeFixtureMatches);
  assert(snapshot.remoteDebug.snapshotBytes == 434312);

  RenderSample allocationFailure;
  allocationFailure.buildings.allocationFallback = true;
  assert(state.noteRenderForWindow(41, Profile::Medium, allocationFailure));
  assert(state.noteRenderForWindow(41, Profile::Medium, RenderSample{}));
  const Snapshot latchedFailure = state.snapshot(2600);
  assert(latchedFailure.buildings.allocationFallback);

  assert(state.beginWindow(42, runIdentity(kRouteHash), Profile::Flat, 3000,
                           jobs(3), 13));
  state.noteMemory({0, 0, 0, 0, 0, 0, 0, 0, 0, 0});
  state.noteMemory({100, 100, 100, 100, 100, 100, 100, 100, 0, 0});
  const Snapshot reset = state.snapshot(3001);
  assert(reset.measurementWindowId == 42);
  assert(reset.sequence == 3);
  assert(reset.totalRender.count == 0);
  assert(reset.jobs.requested == 0);
  assert(reset.maximumUiGapMs == 0);
  assert(reset.routeMarker.accepted == 0);
  assert(reset.pois.accepted == 0);
  assert(reset.windowMinimumInternalFree == 0);
  assert(reset.windowMinimumPsramFree == 0);
  assert(reset.windowMinimumDmaFree == 0);
  assert(!reset.buildings.allocationFallback);
  assert(reset.profile == Profile::Flat);
  assert(reset.remoteDebug.active);

  state.endSession();
  const Snapshot ended = state.snapshot(4000);
  assert(ended.profile == Profile::Current);
  assert(ended.measurementWindowId == 0);
  assert(!ended.remoteDebug.active);
  assert(!state.beginWindow(43, runIdentity(kRouteHash), Profile::High, 4001,
                            jobs(3), 13));
  assert(state.measurementWindowId() == 0);

  BoundedText<5> bounded;
  assert(bounded.assign("four"));
  assert(!bounded.assign("oversized"));
  assert(std::strcmp(bounded.c_str(), "four") == 0);

  std::cout << "renderer diagnostics policy tests passed\n";
  return 0;
}
