#include "../../lib/ride_diagnostics/ride_diagnostics_queue_policy.hpp"
#include "../../lib/ride_diagnostics/ride_diagnostics.hpp"

#include <cassert>
#include <iostream>

int main() {
  using ride_diagnostics::queue_policy::Selection;
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

  std::cout << "ride diagnostics queue policy tests passed\n";
  return 0;
}
