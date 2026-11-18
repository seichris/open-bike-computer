// Host test for bounded advertising supervision after a NimBLE host reset.
//
//   g++ -std=c++17 -Wall -Wextra -Werror \
//     tools/tests/test_ble_advertising_recovery_policy.cpp
#include "../../lib/ble_navigation/ble_advertising_recovery_policy.hpp"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <vector>

using namespace ble_advertising_recovery;

namespace {

Observation silent(uint32_t nowMs, bool synced = true) {
  Observation observation;
  observation.nowMs = nowMs;
  observation.hostSynced = synced;
  return observation;
}

Observation advertising(uint32_t nowMs) {
  Observation observation = silent(nowMs);
  observation.advertising = true;
  return observation;
}

Observation connected(uint32_t nowMs) {
  Observation observation = silent(nowMs);
  observation.connected = true;
  return observation;
}

// Steps the supervisor once per 100 ms, as the loop task roughly would, and
// returns the times of every posted attempt.
std::vector<uint32_t> attemptsBetween(Supervisor &supervisor, uint32_t fromMs,
                                      uint32_t toMs, bool synced = true) {
  std::vector<uint32_t> times;
  // Count elapsed time so a window across the 32-bit wrap still steps.
  const uint32_t span = toMs - fromMs;
  for (uint32_t elapsed = 0; elapsed <= span; elapsed += 100) {
    const uint32_t now = fromMs + elapsed;
    if (supervisor.update(silent(now, synced)).action == Action::Attempt)
      times.push_back(now);
  }
  return times;
}

void testRetryDelaysAreBounded() {
  assert(retryDelayMs(0) == 1'000);
  assert(retryDelayMs(1) == 1'000);
  assert(retryDelayMs(2) == 2'000);
  assert(retryDelayMs(3) == 4'000);
  assert(retryDelayMs(5) == 16'000);
  assert(retryDelayMs(kFastAttempts) == kSlowRetryMs);
  assert(retryDelayMs(UINT16_MAX) == kSlowRetryMs);
  for (uint16_t attempts = 0; attempts < 200; ++attempts) {
    const uint32_t delay = retryDelayMs(attempts);
    assert(delay >= kFirstRetryMs && delay <= kSlowRetryMs);
  }
}

void testAdvertisingOrConnectedNeedsNothing() {
  Supervisor supervisor;
  for (uint32_t now = 0; now < 60'000; now += 100) {
    const Decision a = supervisor.update(advertising(now));
    assert(a.action == Action::None && a.report == Report::None);
    const Decision c = supervisor.update(connected(now + 50));
    assert(c.action == Action::None && c.report == Report::None);
  }
  assert(!supervisor.outageActive());
}

void testNormalRestartInsideGraceIsNotTouched() {
  // The disconnect callback restarts advertising within the grace period:
  // no attempt, no report.
  Supervisor supervisor;
  assert(supervisor.update(advertising(1'000)).action == Action::None);
  assert(supervisor.update(silent(1'100)).action == Action::None);
  assert(supervisor.update(silent(1'900)).action == Action::None);
  const Decision restored = supervisor.update(advertising(2'000));
  assert(restored.action == Action::None);
  assert(restored.report == Report::None);
  assert(!supervisor.outageActive());
}

void testHostResetRestoresAfterResync() {
  // 2026-11-18: reason 12 host reset, the library's resync restart fails,
  // and the board would stay silent. The supervisor waits for the sync,
  // gives the library its grace, then posts an attempt.
  Supervisor supervisor;
  const uint32_t reset = 1'771'394;
  assert(supervisor.update(advertising(reset - 100)).action == Action::None);
  const std::vector<uint32_t> whileUnsynced =
      attemptsBetween(supervisor, reset, reset + 3'000, false);
  assert(whileUnsynced.empty());
  const uint32_t synced = reset + 3'100;
  supervisor.noteHostResynced(synced);
  // Still inside the post-sync grace.
  assert(supervisor.update(silent(synced + 500)).action == Action::None);
  const Decision first = supervisor.update(silent(synced + 1'000));
  assert(first.action == Action::Attempt && first.attempt == 1);
  const Decision restored = supervisor.update(advertising(synced + 1'100));
  assert(restored.report == Report::Restored);
  assert(restored.attempt == 1);
  assert(restored.outageMs == synced + 1'100 - reset);
  assert(!supervisor.outageActive());
}

void testFailedAttemptsBackOffThenSlowRetries() {
  Supervisor supervisor;
  const uint32_t start = 10'000;
  std::vector<uint32_t> attempts =
      attemptsBetween(supervisor, start, start + 10 * 60'000);
  // Fast phase: grace, then 1, 2, 4, 8, 16 s later (six attempts).
  assert(attempts.size() >= kFastAttempts);
  const uint32_t expectedFast[] = {1'000, 2'000, 4'000, 8'000, 16'000,
                                   32'000};
  for (uint16_t index = 0; index < kFastAttempts; ++index)
    assert(attempts[index] == start + expectedFast[index]);
  // Slow phase: exactly once a minute, never in a tight loop.
  for (size_t index = kFastAttempts; index < attempts.size(); ++index)
    assert(attempts[index] - attempts[index - 1] == kSlowRetryMs);
  for (size_t index = 1; index < attempts.size(); ++index)
    assert(attempts[index] - attempts[index - 1] >= kFirstRetryMs);
  // Ten minutes produce at most six fast and ten slow attempts.
  assert(attempts.size() <= kFastAttempts + 10U);
}

void testExhaustionIsReportedOnce() {
  Supervisor supervisor;
  int exhausted = 0;
  for (uint32_t now = 0; now <= 20 * 60'000; now += 100) {
    const Decision decision = supervisor.update(silent(now));
    if (decision.report == Report::FastAttemptsExhausted) {
      ++exhausted;
      assert(decision.attempt == kFastAttempts + 1U);
      assert(decision.action == Action::Attempt);
    }
  }
  assert(exhausted == 1);
}

void testUnsyncedOutageIsReportedOnceWithoutAttempts() {
  Supervisor supervisor;
  int reports = 0;
  for (uint32_t now = 0; now <= 120'000; now += 100) {
    const Decision decision = supervisor.update(silent(now, false));
    assert(decision.action == Action::None);
    if (decision.report == Report::HostUnsynced) {
      ++reports;
      assert(decision.outageMs >= kUnsyncedReportMs);
    }
  }
  assert(reports == 1);
  // Once the host syncs, the library gets its grace before an attempt.
  assert(supervisor.update(silent(120'100)).action == Action::None);
  assert(supervisor.update(silent(120'000 + kGraceMs + 100)).action ==
         Action::Attempt);
}

void testResyncRestartsTheFastBudget() {
  Supervisor supervisor;
  const std::vector<uint32_t> initial = attemptsBetween(supervisor, 0, 120'000);
  assert(initial.size() > kFastAttempts);
  assert(supervisor.attempts() > kFastAttempts);
  // A later host reset and resync: fast attempts again, starting at one.
  supervisor.noteHostResynced(120'100);
  const Decision next = supervisor.update(silent(120'100 + kGraceMs));
  assert(next.action == Action::Attempt && next.attempt == 1);
}

void testConnectionEndsOutageAndCountsAsRestored() {
  Supervisor supervisor;
  attemptsBetween(supervisor, 0, 5'000);
  assert(supervisor.attempts() > 0);
  const Decision decision = supervisor.update(connected(5'100));
  assert(decision.report == Report::Restored);
  assert(!supervisor.outageActive());
  // A later outage starts from scratch with a fresh grace.
  assert(supervisor.update(silent(10'000)).action == Action::None);
  const Decision first = supervisor.update(silent(10'000 + kGraceMs));
  assert(first.action == Action::Attempt && first.attempt == 1);
}

void testSuppressedStandsAside() {
  Supervisor supervisor;
  for (uint32_t now = 0; now < 120'000; now += 100) {
    Observation observation = silent(now);
    observation.suppressed = true;
    assert(supervisor.update(observation).action == Action::None);
  }
  assert(!supervisor.outageActive());
}

void testClockWrap() {
  Supervisor supervisor;
  const uint32_t start = UINT32_MAX - 500;
  const std::vector<uint32_t> attempts = attemptsBetween(
      supervisor, start, start + 5'000);
  assert(!attempts.empty());
  assert(static_cast<uint32_t>(attempts[0] - start) == kGraceMs);
}

void testReportPhases() {
  assert(std::strcmp(reportPhase(Report::Restored), "restored") == 0);
  assert(std::strcmp(reportPhase(Report::FastAttemptsExhausted),
                     "fast_attempts_exhausted") == 0);
  assert(std::strcmp(reportPhase(Report::HostUnsynced), "host_unsynced") ==
         0);
}

} // namespace

int main() {
  testRetryDelaysAreBounded();
  testAdvertisingOrConnectedNeedsNothing();
  testNormalRestartInsideGraceIsNotTouched();
  testHostResetRestoresAfterResync();
  testFailedAttemptsBackOffThenSlowRetries();
  testExhaustionIsReportedOnce();
  testUnsyncedOutageIsReportedOnceWithoutAttempts();
  testResyncRestartsTheFastBudget();
  testConnectionEndsOutageAndCountsAsRestored();
  testSuppressedStandsAside();
  testClockWrap();
  testReportPhases();
  return 0;
}
