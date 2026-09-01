#pragma once

#include "../renderer_tuning/renderer_tuning.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace renderer_diagnostics {

constexpr uint8_t kSchemaVersion = 1;
constexpr size_t kIdentityTextBytes = 49;
constexpr size_t kSha256TextBytes = 65;

template <size_t Capacity> struct BoundedText {
  static_assert(Capacity > 1, "bounded text needs space for a terminator");
  std::array<char, Capacity> bytes{};

  bool assign(const char *value) {
    if (value == nullptr)
      return false;
    const size_t length = std::strlen(value);
    if (length >= Capacity)
      return false;
    bytes.fill(0);
    std::memcpy(bytes.data(), value, length);
    return true;
  }

  const char *c_str() const { return bytes.data(); }
  bool empty() const { return bytes[0] == '\0'; }

  bool operator==(const BoundedText &other) const {
    return bytes == other.bytes;
  }
};

struct BuildIdentity {
  BoundedText<17> deviceId;
  BoundedText<kIdentityTextBytes> firmwareCommit;
  BoundedText<kIdentityTextBytes> board;
  BoundedText<kIdentityTextBytes> buildProfile;
  uint32_t bootId = 0;
  uint32_t resetReason = 0;
};

struct RunIdentity {
  BoundedText<kIdentityTextBytes> runId;
  BoundedText<kIdentityTextBytes> mapFixtureId;
  BoundedText<kSha256TextBytes> mapFixtureSha256;
  BoundedText<kIdentityTextBytes> routeFixtureId;
  BoundedText<kSha256TextBytes> routeFixtureSha256;
  BoundedText<33> routeMode;
  uint16_t repeat = 0;
};

struct MemorySample {
  uint32_t internalFree = 0;
  uint32_t internalMinimumEverFree = 0;
  uint32_t internalLargest = 0;
  uint32_t psramFree = 0;
  uint32_t psramLargest = 0;
  uint32_t dmaFree = 0;
  uint32_t dmaMinimumEverFree = 0;
  uint32_t dmaLargest = 0;
  uint32_t cryptoHeadroomRejections = 0;
  uint32_t cryptoOperationFailures = 0;
};

struct TimingSummary {
  uint32_t count = 0;
  uint32_t lastMs = 0;
  uint32_t p50Ms = 0;
  uint32_t p95Ms = 0;
  uint32_t maximumMs = 0;
};

class TimingHistogram {
public:
  void reset() {
    buckets_.fill(0);
    count_ = 0;
    lastMs_ = 0;
    maximumMs_ = 0;
  }

  void note(uint32_t milliseconds) {
    ++count_;
    lastMs_ = milliseconds;
    maximumMs_ = std::max(maximumMs_, milliseconds);
    for (size_t index = 0; index < kUpperBoundsMs.size(); ++index) {
      if (milliseconds <= kUpperBoundsMs[index]) {
        ++buckets_[index];
        return;
      }
    }
    ++buckets_.back();
  }

  TimingSummary summary() const {
    return {count_, lastMs_, percentile(50), percentile(95), maximumMs_};
  }

private:
  static constexpr std::array<uint32_t, 28> kUpperBoundsMs{{
      1,    2,    4,    8,    12,   16,   24,   32,   48,
      64,   80,   100,  125,  150,  200,  250,  350,  500,
      750,  1000, 1250, 1500, 2000, 3000, 5000, 7500, 10000,
      std::numeric_limits<uint32_t>::max(),
  }};

  uint32_t percentile(uint32_t percent) const {
    if (count_ == 0)
      return 0;
    const uint64_t target =
        (static_cast<uint64_t>(count_) * percent + 99U) / 100U;
    uint64_t cumulative = 0;
    for (size_t index = 0; index < buckets_.size(); ++index) {
      cumulative += buckets_[index];
      if (cumulative >= target) {
        return index + 1U == buckets_.size() ? maximumMs_
                                             : kUpperBoundsMs[index];
      }
    }
    return maximumMs_;
  }

  std::array<uint32_t, kUpperBoundsMs.size()> buckets_{};
  uint32_t count_ = 0;
  uint32_t lastMs_ = 0;
  uint32_t maximumMs_ = 0;
};

enum BuildingLimiter : uint8_t {
  LimiterNone = 0,
  LimiterRecords = 1U << 0,
  LimiterPoints = 1U << 1,
  LimiterProjectedPixels = 1U << 2,
  LimiterExtrudedRecords = 1U << 3,
  LimiterExtrudedPoints = 1U << 4,
  LimiterExtrudedPixels = 1U << 5,
};

struct BuildingPassSample {
  uint32_t candidates = 0;
  uint32_t selected = 0;
  uint32_t extruded = 0;
  uint32_t flat = 0;
  uint32_t deferred = 0;
  uint32_t oversized = 0;
  uint32_t rendered = 0;
  uint32_t extrudedP90DistancePx = 0;
  uint32_t extrudedFarthestDistancePx = 0;
  uint8_t limiterFlags = LimiterNone;
  bool allocationFallback = false;
};

struct RenderSample {
  uint32_t totalMs = 0;
  uint32_t blockLoadMs = 0;
  uint32_t drawMs = 0;
  uint32_t buildingProjectionMs = 0;
  uint32_t buildingDrawMs = 0;
  BuildingPassSample buildings{};
};

struct JobCounters {
  uint32_t requested = 0;
  uint32_t started = 0;
  uint32_t completed = 0;
  uint32_t published = 0;
  uint32_t stale = 0;
  uint32_t cancelled = 0;
  uint32_t invariantFailed = 0;
};

struct RemoteDebugOverhead {
  bool active = false;
  uint32_t snapshotBytes = 0;
  uint32_t captured = 0;
  uint32_t skippedCadence = 0;
  uint32_t skippedLocked = 0;
  uint32_t captureErrors = 0;
  uint32_t lastCopyUs = 0;
  uint32_t maximumCopyUs = 0;
  uint32_t lastHttpResponseMs = 0;
  uint32_t maximumHttpResponseMs = 0;
  uint32_t freeBefore = 0;
  uint32_t largestBefore = 0;
  uint32_t freeAfterAllocate = 0;
  uint32_t largestAfterAllocate = 0;
};

struct RouteMarker {
  std::array<uint8_t, 32> fixtureSha256{};
  uint16_t sampleIndex = 0;
  uint16_t sampleCount = 0;
  uint32_t loop = 0;
  uint32_t receivedAtMs = 0;
  uint32_t accepted = 0;
  uint32_t rejected = 0;
  bool valid = false;
};

struct Snapshot {
  uint8_t schema = kSchemaVersion;
  uint32_t sequence = 0;
  uint32_t timestampMs = 0;
  uint32_t measurementWindowId = 0;
  uint32_t windowStartedAtMs = 0;
  BuildIdentity build{};
  RunIdentity run{};
  renderer_tuning::Profile profile = renderer_tuning::Profile::Current;
  renderer_tuning::Definition tuning = renderer_tuning::kCurrent;
  MemorySample memory{};
  uint32_t windowMinimumInternalFree = 0;
  uint32_t windowMinimumInternalLargest = 0;
  uint32_t windowMinimumPsramFree = 0;
  uint32_t windowMinimumPsramLargest = 0;
  uint32_t windowMinimumDmaFree = 0;
  uint32_t windowMinimumDmaLargest = 0;
  TimingSummary totalRender{};
  TimingSummary blockLoad{};
  TimingSummary draw{};
  TimingSummary buildingProjection{};
  TimingSummary buildingDraw{};
  TimingSummary buildingTotal{};
  TimingSummary displayFlush{};
  BuildingPassSample buildings{};
  std::array<uint32_t, 6> limiterPasses{};
  JobCounters jobs{};
  uint32_t interrupted = 0;
  uint32_t coverageRejected = 0;
  uint32_t maximumUiGapMs = 0;
  uint32_t gpsPackets = 0;
  uint32_t latestGpsPacketGapMs = 0;
  uint32_t maximumGpsPacketGapMs = 0;
  uint32_t predictionGraceEntries = 0;
  uint32_t predictionExhaustionEntries = 0;
  RouteMarker routeMarker{};
  bool routeFixtureMatches = false;
  RemoteDebugOverhead remoteDebug{};
};

class State {
public:
  void configureBuild(const BuildIdentity &identity) { build_ = identity; }

  void beginSession(bool remoteDebugActive) {
    sessionActive_ = true;
    profile_ = renderer_tuning::Profile::Current;
    remoteDebug_ = {};
    remoteDebug_.active = remoteDebugActive;
    resetWindowState();
  }

  void endSession() {
    sessionActive_ = false;
    profile_ = renderer_tuning::Profile::Current;
    remoteDebug_ = {};
    resetWindowState();
  }

  bool sessionActive() const { return sessionActive_; }

  bool beginWindow(uint32_t windowId, const RunIdentity &identity,
                   renderer_tuning::Profile profile, uint32_t nowMs,
                   const JobCounters &currentJobs,
                   uint32_t currentGpsPacketSequence) {
    if (!sessionActive_ || windowId == 0)
      return false;
    resetWindowState();
    measurementWindowId_ = windowId;
    windowStartedAtMs_ = nowMs;
    run_ = identity;
    profile_ = profile;
    jobs_ = currentJobs;
    jobBaseline_ = currentJobs;
    lastGpsPacketSequence_ = currentGpsPacketSequence;
    return true;
  }

  void setProfile(renderer_tuning::Profile profile) { profile_ = profile; }

  renderer_tuning::Profile profile() const { return profile_; }

  uint32_t measurementWindowId() const { return measurementWindowId_; }

  JobCounters currentJobs() const { return jobs_; }

  void noteMemory(const MemorySample &sample) {
    memory_ = sample;
    if (!memoryObserved_) {
      cryptoHeadroomRejectionsBaseline_ = sample.cryptoHeadroomRejections;
      cryptoOperationFailuresBaseline_ = sample.cryptoOperationFailures;
      windowMinimumInternalFree_ = sample.internalFree;
      windowMinimumInternalLargest_ = sample.internalLargest;
      windowMinimumPsramFree_ = sample.psramFree;
      windowMinimumPsramLargest_ = sample.psramLargest;
      windowMinimumDmaFree_ = sample.dmaFree;
      windowMinimumDmaLargest_ = sample.dmaLargest;
      memoryObserved_ = true;
      return;
    }
    windowMinimumInternalFree_ =
        std::min(windowMinimumInternalFree_, sample.internalFree);
    windowMinimumInternalLargest_ =
        std::min(windowMinimumInternalLargest_, sample.internalLargest);
    windowMinimumPsramFree_ =
        std::min(windowMinimumPsramFree_, sample.psramFree);
    windowMinimumPsramLargest_ =
        std::min(windowMinimumPsramLargest_, sample.psramLargest);
    windowMinimumDmaFree_ =
        std::min(windowMinimumDmaFree_, sample.dmaFree);
    windowMinimumDmaLargest_ =
        std::min(windowMinimumDmaLargest_, sample.dmaLargest);
  }

  bool noteRenderForWindow(uint32_t windowId,
                           renderer_tuning::Profile profile,
                           const RenderSample &sample) {
    if (!sessionActive_ || windowId == 0 ||
        windowId != measurementWindowId_ || profile != profile_) {
      return false;
    }
    noteRenderUnchecked(sample);
    return true;
  }

  void noteJobs(const JobCounters &jobs) { jobs_ = jobs; }

  void noteInterrupted() { ++interrupted_; }
  void noteCoverageRejected() { ++coverageRejected_; }

  void noteUiLoopGap(uint32_t milliseconds) {
    maximumUiGapMs_ = std::max(maximumUiGapMs_, milliseconds);
  }

  void noteDisplayFlushUs(uint32_t microseconds) {
    displayFlush_.note((microseconds + 999U) / 1000U);
  }

  void noteGpsPacket(uint32_t packetSequence, uint32_t packetGapMs) {
    if (packetSequence == 0 || packetSequence == lastGpsPacketSequence_)
      return;
    const uint32_t delta = packetSequence - lastGpsPacketSequence_;
    if (delta >= 0x80000000U)
      return;
    lastGpsPacketSequence_ = packetSequence;
    gpsPackets_ += delta;
    latestGpsPacketGapMs_ = packetGapMs;
    maximumGpsPacketGapMs_ = std::max(maximumGpsPacketGapMs_, packetGapMs);
  }

  void notePrediction(bool graceActive, bool exhausted) {
    if (graceActive && !lastPredictionGraceActive_)
      ++predictionGraceEntries_;
    if (exhausted && !lastPredictionExhausted_)
      ++predictionExhaustionEntries_;
    lastPredictionGraceActive_ = graceActive;
    lastPredictionExhausted_ = exhausted;
  }

  bool noteRouteMarker(const uint8_t *fixtureSha256, size_t hashBytes,
                       uint16_t sampleIndex, uint16_t sampleCount,
                       uint32_t loop, uint32_t nowMs) {
    if (fixtureSha256 == nullptr ||
        hashBytes != routeMarker_.fixtureSha256.size() || sampleCount == 0 ||
        sampleIndex >= sampleCount || !routeHashMatches(fixtureSha256)) {
      ++routeMarker_.rejected;
      return false;
    }
    std::copy(fixtureSha256, fixtureSha256 + hashBytes,
              routeMarker_.fixtureSha256.begin());
    routeMarker_.sampleIndex = sampleIndex;
    routeMarker_.sampleCount = sampleCount;
    routeMarker_.loop = loop;
    routeMarker_.receivedAtMs = nowMs;
    ++routeMarker_.accepted;
    routeMarker_.valid = true;
    return true;
  }

  void noteRemoteDebug(const RemoteDebugOverhead &overhead) {
    remoteDebug_ = overhead;
  }

  Snapshot snapshot(uint32_t nowMs) {
    Snapshot result;
    result.sequence = ++snapshotSequence_;
    result.timestampMs = nowMs;
    result.measurementWindowId = measurementWindowId_;
    result.windowStartedAtMs = windowStartedAtMs_;
    result.build = build_;
    result.run = run_;
    result.profile = profile_;
    result.tuning = renderer_tuning::definition(profile_);
    result.memory = memory_;
    result.memory.cryptoHeadroomRejections = subtract(
        memory_.cryptoHeadroomRejections,
        cryptoHeadroomRejectionsBaseline_);
    result.memory.cryptoOperationFailures = subtract(
        memory_.cryptoOperationFailures, cryptoOperationFailuresBaseline_);
    result.windowMinimumInternalFree = windowMinimumInternalFree_;
    result.windowMinimumInternalLargest = windowMinimumInternalLargest_;
    result.windowMinimumPsramFree = windowMinimumPsramFree_;
    result.windowMinimumPsramLargest = windowMinimumPsramLargest_;
    result.windowMinimumDmaFree = windowMinimumDmaFree_;
    result.windowMinimumDmaLargest = windowMinimumDmaLargest_;
    result.totalRender = totalRender_.summary();
    result.blockLoad = blockLoad_.summary();
    result.draw = draw_.summary();
    result.buildingProjection = buildingProjection_.summary();
    result.buildingDraw = buildingDraw_.summary();
    result.buildingTotal = buildingTotal_.summary();
    result.displayFlush = displayFlush_.summary();
    result.buildings = buildings_;
    result.buildings.allocationFallback = allocationFallbackObserved_;
    result.limiterPasses = limiterPasses_;
    result.jobs = subtractJobs(jobs_, jobBaseline_);
    result.interrupted = interrupted_;
    result.coverageRejected = coverageRejected_;
    result.maximumUiGapMs = maximumUiGapMs_;
    result.gpsPackets = gpsPackets_;
    result.latestGpsPacketGapMs = latestGpsPacketGapMs_;
    result.maximumGpsPacketGapMs = maximumGpsPacketGapMs_;
    result.predictionGraceEntries = predictionGraceEntries_;
    result.predictionExhaustionEntries = predictionExhaustionEntries_;
    result.routeMarker = routeMarker_;
    result.routeFixtureMatches = routeHashMatches();
    result.remoteDebug = remoteDebug_;
    return result;
  }

private:
  void noteRenderUnchecked(const RenderSample &sample) {
    totalRender_.note(sample.totalMs);
    blockLoad_.note(sample.blockLoadMs);
    draw_.note(sample.drawMs);
    buildingProjection_.note(sample.buildingProjectionMs);
    buildingDraw_.note(sample.buildingDrawMs);
    buildingTotal_.note(sample.buildingProjectionMs + sample.buildingDrawMs);
    buildings_ = sample.buildings;
    allocationFallbackObserved_ =
        allocationFallbackObserved_ || sample.buildings.allocationFallback;
    for (size_t index = 0; index < limiterPasses_.size(); ++index) {
      if ((sample.buildings.limiterFlags & (1U << index)) != 0)
        ++limiterPasses_[index];
    }
  }

  static uint32_t subtract(uint32_t value, uint32_t baseline) {
    return value >= baseline ? value - baseline : 0;
  }

  static JobCounters subtractJobs(const JobCounters &value,
                                  const JobCounters &baseline) {
    return {
        subtract(value.requested, baseline.requested),
        subtract(value.started, baseline.started),
        subtract(value.completed, baseline.completed),
        subtract(value.published, baseline.published),
        subtract(value.stale, baseline.stale),
        subtract(value.cancelled, baseline.cancelled),
        subtract(value.invariantFailed, baseline.invariantFailed),
    };
  }

  static int hexNibble(char value) {
    if (value >= '0' && value <= '9')
      return value - '0';
    if (value >= 'a' && value <= 'f')
      return value - 'a' + 10;
    if (value >= 'A' && value <= 'F')
      return value - 'A' + 10;
    return -1;
  }

  bool routeHashMatches(const uint8_t *candidate) const {
    if (candidate == nullptr)
      return false;
    const char *expected = run_.routeFixtureSha256.c_str();
    if (std::strlen(expected) != 64)
      return false;
    for (size_t index = 0; index < routeMarker_.fixtureSha256.size(); ++index) {
      const int high = hexNibble(expected[index * 2]);
      const int low = hexNibble(expected[index * 2 + 1]);
      if (high < 0 || low < 0 ||
          candidate[index] != static_cast<uint8_t>((high << 4) | low))
        return false;
    }
    return true;
  }

  bool routeHashMatches() const {
    return routeMarker_.valid &&
           routeHashMatches(routeMarker_.fixtureSha256.data());
  }

  void resetWindowState() {
    measurementWindowId_ = 0;
    windowStartedAtMs_ = 0;
    run_ = {};
    memory_ = {};
    memoryObserved_ = false;
    cryptoHeadroomRejectionsBaseline_ = 0;
    cryptoOperationFailuresBaseline_ = 0;
    windowMinimumInternalFree_ = 0;
    windowMinimumInternalLargest_ = 0;
    windowMinimumPsramFree_ = 0;
    windowMinimumPsramLargest_ = 0;
    windowMinimumDmaFree_ = 0;
    windowMinimumDmaLargest_ = 0;
    totalRender_.reset();
    blockLoad_.reset();
    draw_.reset();
    buildingProjection_.reset();
    buildingDraw_.reset();
    buildingTotal_.reset();
    displayFlush_.reset();
    buildings_ = {};
    allocationFallbackObserved_ = false;
    limiterPasses_.fill(0);
    jobBaseline_ = jobs_;
    interrupted_ = 0;
    coverageRejected_ = 0;
    maximumUiGapMs_ = 0;
    lastGpsPacketSequence_ = 0;
    gpsPackets_ = 0;
    latestGpsPacketGapMs_ = 0;
    maximumGpsPacketGapMs_ = 0;
    predictionGraceEntries_ = 0;
    predictionExhaustionEntries_ = 0;
    lastPredictionGraceActive_ = false;
    lastPredictionExhausted_ = false;
    routeMarker_ = {};
  }

  bool sessionActive_ = false;
  uint32_t snapshotSequence_ = 0;
  uint32_t measurementWindowId_ = 0;
  uint32_t windowStartedAtMs_ = 0;
  BuildIdentity build_{};
  RunIdentity run_{};
  renderer_tuning::Profile profile_ = renderer_tuning::Profile::Current;
  MemorySample memory_{};
  bool memoryObserved_ = false;
  uint32_t cryptoHeadroomRejectionsBaseline_ = 0;
  uint32_t cryptoOperationFailuresBaseline_ = 0;
  uint32_t windowMinimumInternalFree_ = 0;
  uint32_t windowMinimumInternalLargest_ = 0;
  uint32_t windowMinimumPsramFree_ = 0;
  uint32_t windowMinimumPsramLargest_ = 0;
  uint32_t windowMinimumDmaFree_ = 0;
  uint32_t windowMinimumDmaLargest_ = 0;
  TimingHistogram totalRender_{};
  TimingHistogram blockLoad_{};
  TimingHistogram draw_{};
  TimingHistogram buildingProjection_{};
  TimingHistogram buildingDraw_{};
  TimingHistogram buildingTotal_{};
  TimingHistogram displayFlush_{};
  BuildingPassSample buildings_{};
  bool allocationFallbackObserved_ = false;
  std::array<uint32_t, 6> limiterPasses_{};
  JobCounters jobs_{};
  JobCounters jobBaseline_{};
  uint32_t interrupted_ = 0;
  uint32_t coverageRejected_ = 0;
  uint32_t maximumUiGapMs_ = 0;
  uint32_t lastGpsPacketSequence_ = 0;
  uint32_t gpsPackets_ = 0;
  uint32_t latestGpsPacketGapMs_ = 0;
  uint32_t maximumGpsPacketGapMs_ = 0;
  uint32_t predictionGraceEntries_ = 0;
  uint32_t predictionExhaustionEntries_ = 0;
  bool lastPredictionGraceActive_ = false;
  bool lastPredictionExhausted_ = false;
  RouteMarker routeMarker_{};
  RemoteDebugOverhead remoteDebug_{};
};

} // namespace renderer_diagnostics
