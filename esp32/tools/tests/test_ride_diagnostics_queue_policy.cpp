#include "../../lib/ride_diagnostics/ride_diagnostics_queue_policy.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics.hpp"

#include <cassert>
#include <iostream>

int main() {
  using ride_diagnostics::queue_policy::Selection;
  using ride_diagnostics::queue_policy::CriticalOverflow;
  using ride_diagnostics::queue_policy::criticalOverflow;
  using ride_diagnostics::queue_policy::readyToSeal;
  using ride_diagnostics::queue_policy::select;

  assert(select(false, 0, false, 0) == Selection::None);
  assert(select(true, 4, false, 0) == Selection::Normal);
  assert(select(false, 0, true, 4) == Selection::Critical);
  assert(select(true, 4, true, 5) == Selection::Normal);
  assert(select(true, 6, true, 5) == Selection::Critical);
  assert(!readyToSeal(true, 9, 10));
  assert(readyToSeal(true, 10, 10));
  assert(readyToSeal(false, 0, 10));
  assert(criticalOverflow(true, 6, 2) == CriticalOverflow::UseNormal);
  assert(criticalOverflow(true, 0, 0) == CriticalOverflow::UseNormal);
  assert(criticalOverflow(false, 6, 2) == CriticalOverflow::EvictNormal);
  assert(criticalOverflow(false, 6, 6) == CriticalOverflow::Drop);
  assert(criticalOverflow(false, 0, 0) == CriticalOverflow::Drop);

  constexpr uint64_t now = 1'800'000'000ULL;
  constexpr uint64_t day = 24ULL * 60ULL * 60ULL;
  assert(ride_diagnostics::retention_policy::expiredByWallClock(
      now, now - 15ULL * day, 14));
  assert(!ride_diagnostics::retention_policy::expiredByWallClock(
      now, now - 14ULL * day, 14));
  assert(!ride_diagnostics::retention_policy::expiredByWallClock(
      now, 315'532'800ULL, 14));
  assert(!ride_diagnostics::retention_policy::expiredByWallClock(
      315'532'800ULL, 315'532'700ULL, 14));
  assert(ride_diagnostics::retention_policy::snapshotLeaseActive(100, 200));
  assert(!ride_diagnostics::retention_policy::snapshotLeaseActive(200, 200));
  assert(!ride_diagnostics::retention_policy::snapshotLeaseActive(100, 0));
  assert(ride_diagnostics::retention_policy::snapshotLeaseActive(
      0xfffffff0U, 0x00000020U));
  assert(!ride_diagnostics::retention_policy::snapshotLeaseActive(
      0x00000020U, 0x00000020U));
  assert(ride_diagnostics::retention_policy::shouldPruneAfterWrite(1, false));
  assert(!ride_diagnostics::retention_policy::shouldPruneAfterWrite(1, true));
  assert(ride_diagnostics::retention_policy::shouldPruneAfterWrite(16, true));

  using namespace ride_diagnostics::capture_policy;
  constexpr uint32_t wrapToZeroStart =
      0U - kDetailedCaptureDurationMs;
  const uint32_t normalizedDeadline =
      detailedCaptureDeadline(wrapToZeroStart);
  assert(normalizedDeadline == 1);
  assert(!detailedCaptureExpired(0, normalizedDeadline));
  assert(detailedCaptureExpired(1, normalizedDeadline));
  const uint32_t wrappedDeadline = detailedCaptureDeadline(0xfffffff0U);
  assert(wrappedDeadline != 0);
  assert(!detailedCaptureExpired(0xfffffff0U, wrappedDeadline));
  assert(detailedCaptureExpired(wrappedDeadline, wrappedDeadline));
  constexpr uint32_t existingDeadline = 123456U;
  assert(detailedCaptureDeadlineAfterBinding(
             100U, existingDeadline, false, true) == existingDeadline);
  assert(detailedCaptureDeadlineAfterBinding(
             100U, existingDeadline, true, true) ==
         detailedCaptureDeadline(100U));
  assert(detailedCaptureDeadlineAfterBinding(
             100U, existingDeadline, true, false) == 0);
  assert(detailedCaptureLeaseMatches(
      "capture-a", 4, 900, "capture-a", 4, 900));
  assert(!detailedCaptureLeaseMatches(
      "capture-a", 5, 900, "capture-a", 4, 900));
  assert(!detailedCaptureLeaseMatches(
      "capture-a", 4, 901, "capture-a", 4, 900));
  assert(!detailedCaptureLeaseMatches(
      "capture-b", 4, 900, "capture-a", 4, 900));

  std::cout << "ride diagnostics queue policy tests passed\n";
  return 0;
}
