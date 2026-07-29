#include "../../lib/gui/src/uiUpdatePolicy.hpp"

#include <cassert>
#include <cstdint>

using namespace ui_update_policy;

int main() {
  SourceSignatures signatures;
  ChangeTracker tracker;
  assert(tracker.observe(signatures) == kAllSources);
  assert(tracker.take(kAllSources) == kAllSources);

  // A static screen must not request any more widget mutations or flushes.
  uint32_t widgetMutationRequests = 0;
  uint32_t displayFlushRequests = 0;
  for (uint32_t tick = 0; tick < 10000; ++tick) {
    const uint32_t changed = tracker.observe(signatures);
    if (changed != 0) {
      ++widgetMutationRequests;
      ++displayFlushRequests;
    }
  }
  assert(widgetMutationRequests == 0);
  assert(displayFlushRequests == 0);
  assert(tracker.pending() == 0);

  signatures[Source::Navigation] = 1;
  assert(tracker.observe(signatures) == sourceMask(Source::Navigation));
  signatures[Source::Gps] = 2;
  assert(tracker.observe(signatures) == sourceMask(Source::Gps));
  assert(tracker.take(Source::Navigation));
  assert(!tracker.take(Source::Navigation));
  assert(tracker.take(Source::Gps));

  tracker.mark(Source::Workout);
  assert(tracker.take(Source::Workout));

  uint32_t lastRunMs = 0;
  assert(cadenceDue(100, lastRunMs, kRideStatsPeriodMs));
  assert(!cadenceDue(1099, lastRunMs, kRideStatsPeriodMs));
  assert(cadenceDue(1100, lastRunMs, kRideStatsPeriodMs));
  lastRunMs = UINT32_MAX - 100;
  assert(cadenceDue(1000, lastRunMs, kRideStatsPeriodMs));

  static_assert(nextMinuteDelayMs(0) == 60000);
  static_assert(nextMinuteDelayMs(1) == 59000);
  static_assert(nextMinuteDelayMs(59, 999) == 1);

  constexpr StatusSnapshot initial{};
  static_assert(statusMutations(initial, initial) == StatusNone);
  StatusSnapshot changed = initial;
  changed.satellites = 7;
  changed.fixed = true;
  changed.sdLoaded = true;
  assert(statusMutations(initial, changed) ==
         (StatusGpsCount | StatusGpsFix | StatusSd));
  return 0;
}
