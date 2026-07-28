#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace power_metrics {

constexpr uint8_t kSchemaVersion = 1;

enum class MapRenderReason : uint32_t {
  Gps = 1u << 0,
  Route = 1u << 1,
  Settings = 1u << 2,
  Heading = 1u << 3,
  Retry = 1u << 4,
  Other = 1u << 5,
};

constexpr uint32_t reasonMask(MapRenderReason reason) {
  return static_cast<uint32_t>(reason);
}

constexpr std::array<MapRenderReason, 6> kMapRenderReasons = {
    MapRenderReason::Gps,     MapRenderReason::Route,
    MapRenderReason::Settings, MapRenderReason::Heading,
    MapRenderReason::Retry,   MapRenderReason::Other,
};

enum class BlePacketClass : uint8_t {
  Navigation = 0,
  Route,
  Gps,
  Settings,
  Workout,
  Other,
  Count,
};

struct DurationAggregate {
  uint32_t count = 0;
  uint64_t totalUs = 0;
  uint32_t maxUs = 0;

  void add(uint32_t durationUs) {
    count++;
    totalUs += durationUs;
    if (durationUs > maxUs) {
      maxUs = durationUs;
    }
  }
};

struct IntervalData {
  uint64_t loopWakeCount = 0;
  uint32_t maxLoopGapMs = 0;
  DurationAggregate lvgl;
  DurationAggregate displayFlush;
  DurationAggregate displayRotation;
  DurationAggregate displayQspi;
  DurationAggregate mapRender;
  DurationAggregate mapBlocks;
  DurationAggregate mapDraw;
  DurationAggregate mapRoute;
  uint32_t mapRenderCompleted = 0;
  uint32_t mapRenderInterrupted = 0;
  std::array<uint32_t, kMapRenderReasons.size()> mapReasonCounts{};
  std::array<uint32_t,
             static_cast<std::size_t>(BlePacketClass::Count)>
      blePacketCounts{};
};

class IntervalAccumulator {
public:
  void noteLoop(uint32_t nowMs) {
    if (hasLastLoopMs_) {
      const uint32_t gapMs = nowMs - lastLoopMs_;
      if (gapMs > interval_.maxLoopGapMs) {
        interval_.maxLoopGapMs = gapMs;
      }
    }
    lastLoopMs_ = nowMs;
    hasLastLoopMs_ = true;
    interval_.loopWakeCount++;
  }

  void noteLvgl(uint32_t durationUs) { interval_.lvgl.add(durationUs); }

  void noteDisplayFlush(uint32_t rotationUs, uint32_t qspiUs,
                        uint32_t totalUs) {
    interval_.displayRotation.add(rotationUs);
    interval_.displayQspi.add(qspiUs);
    interval_.displayFlush.add(totalUs);
  }

  void noteMapRender(bool completed, uint32_t totalUs, uint32_t blocksUs,
                     uint32_t drawUs, uint32_t routeUs,
                     uint32_t reasons) {
    interval_.mapRender.add(totalUs);
    interval_.mapBlocks.add(blocksUs);
    interval_.mapDraw.add(drawUs);
    interval_.mapRoute.add(routeUs);
    if (completed) {
      interval_.mapRenderCompleted++;
    } else {
      interval_.mapRenderInterrupted++;
    }

    if (reasons == 0) {
      reasons = reasonMask(MapRenderReason::Other);
    }
    for (std::size_t index = 0; index < kMapRenderReasons.size(); index++) {
      if ((reasons & reasonMask(kMapRenderReasons[index])) != 0) {
        interval_.mapReasonCounts[index]++;
      }
    }
  }

  void noteBlePacket(BlePacketClass packetClass) {
    const std::size_t index = static_cast<std::size_t>(packetClass);
    if (index < interval_.blePacketCounts.size()) {
      interval_.blePacketCounts[index]++;
    }
  }

  IntervalData snapshotAndReset() {
    const IntervalData snapshot = interval_;
    interval_ = {};
    return snapshot;
  }

  const IntervalData &current() const { return interval_; }

  void resetAll() {
    interval_ = {};
    hasLastLoopMs_ = false;
    lastLoopMs_ = 0;
  }

private:
  IntervalData interval_{};
  bool hasLastLoopMs_ = false;
  uint32_t lastLoopMs_ = 0;
};

} // namespace power_metrics
