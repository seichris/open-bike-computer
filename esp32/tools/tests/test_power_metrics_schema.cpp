#include "../../lib/power_metrics/power_metrics_schema.hpp"

#include <cassert>
#include <cstdint>
#include <limits>

int main() {
  using namespace power_metrics;

  static_assert(kSchemaVersion == 1);
  IntervalAccumulator accumulator;

  accumulator.noteLoop(100);
  accumulator.noteLoop(107);
  accumulator.noteLoop(111);
  accumulator.noteLvgl(25);
  accumulator.noteLvgl(75);
  accumulator.noteDisplayFlush(10, 80, 100);
  accumulator.noteDisplayFlush(20, 180, 225);
  accumulator.noteMapRender(
      true, 9'000, 2'000, 5'000, 1'000,
      reasonMask(MapRenderReason::Gps) | reasonMask(MapRenderReason::Heading));
  accumulator.noteMapRender(false, 1'500, 1'000, 0, 0, 0);
  accumulator.noteBlePacket(BlePacketClass::Gps);
  accumulator.noteBlePacket(BlePacketClass::Gps);
  accumulator.noteBlePacket(BlePacketClass::Navigation);
  accumulator.noteBlePacket(BlePacketClass::Transfer);

  const IntervalData first = accumulator.snapshotAndReset();
  assert(first.loopWakeCount == 3);
  assert(first.maxLoopGapMs == 7);
  assert(first.lvgl.count == 2);
  assert(first.lvgl.totalUs == 100);
  assert(first.lvgl.maxUs == 75);
  assert(first.displayFlush.count == 2);
  assert(first.displayFlush.totalUs == 325);
  assert(first.displayFlush.maxUs == 225);
  assert(first.displayRotation.totalUs == 30);
  assert(first.displayQspi.totalUs == 260);
  assert(first.mapRenderCompleted == 1);
  assert(first.mapRenderInterrupted == 1);
  assert(first.mapRender.totalUs == 10'500);
  assert(first.mapReasonCounts[0] == 1); // GPS
  assert(first.mapReasonCounts[3] == 1); // heading
  assert(first.mapReasonCounts[5] == 1); // missing reason becomes other
  assert(first.blePacketCounts[static_cast<std::size_t>(
             BlePacketClass::Gps)] == 2);
  assert(first.blePacketCounts[static_cast<std::size_t>(
             BlePacketClass::Navigation)] == 1);
  assert(first.blePacketCounts[static_cast<std::size_t>(
             BlePacketClass::Transfer)] == 1);
  // An interval reset preserves the prior loop timestamp so the boundary gap
  // remains visible in the following report.
  accumulator.noteLoop(125);
  const IntervalData second = accumulator.snapshotAndReset();
  assert(second.loopWakeCount == 1);
  assert(second.maxLoopGapMs == 14);
  assert(second.lvgl.count == 0);

  // Unsigned subtraction intentionally handles millis() rollover.
  accumulator.resetAll();
  accumulator.noteLoop(std::numeric_limits<uint32_t>::max() - 2);
  accumulator.noteLoop(3);
  const IntervalData rollover = accumulator.snapshotAndReset();
  assert(rollover.maxLoopGapMs == 6);

  return 0;
}
