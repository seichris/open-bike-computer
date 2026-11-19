#pragma once

#include <cstdint>

// Bounded supervision of BLE advertising while no central is connected.
//
// A NimBLE host reset (GAP disconnect reason BLE_HS_ECONTROLLER = 12,
// BLE_HS_ETIMEOUT_HCI, ...) ends the link, resets the controller and clears
// the host's identity addresses (pinned NimBLE-Arduino 1.4.3: `ble_hs_reset()`
// calls `ble_hs_id_reset()`). Resynchronization re-reads only the public
// address, while this firmware advertises from a persisted static random one,
// so NimBLE-Arduino's own restart after resync failed with BLE_HS_ENOADDR and
// the board stayed silent until a reboot (GNSS bench, 2026-11-18). The host
// sync hook restores that address before the library restarts advertising;
// this supervisor is the second line. It notices a synchronized, unconnected
// host that is not advertising and asks the host task to restore the address
// and advertise: quickly at first, then once a minute, never in a tight loop.
// It does not address whatever made the controller and host disagree.
namespace ble_advertising_recovery {

// The disconnect callback and the library's resync restart land first.
constexpr uint32_t kGraceMs = 1'000;
constexpr uint32_t kFirstRetryMs = 1'000;
constexpr uint32_t kMaxFastRetryMs = 30'000;
// Six attempts about 1, 2, 4, 8, 16 and 32 s into an outage (the grace, then
// doubling gaps), then one a minute.
constexpr uint16_t kFastAttempts = 6;
constexpr uint32_t kSlowRetryMs = 60'000;
// An outage this long without a synchronized host is reported once.
constexpr uint32_t kUnsyncedReportMs = 10'000;

struct Observation {
  uint32_t nowMs = 0;
  bool hostSynced = false;
  // A central holds or is establishing the link.
  bool connected = false;
  bool advertising = false;
  // The firmware deliberately keeps advertising off (none today besides the
  // radio being down); supervision then stands aside.
  bool suppressed = false;
};

enum class Action : uint8_t {
  None = 0,
  // Post one restoration attempt (address, then advertising) to the host.
  Attempt = 1,
};

enum class Report : uint8_t {
  None = 0,
  // Advertising came back after at least one supervised attempt.
  Restored = 1,
  // The fast attempts all failed; slow retries continue.
  FastAttemptsExhausted = 2,
  // The host has not resynchronized for kUnsyncedReportMs.
  HostUnsynced = 3,
};

struct Decision {
  Action action = Action::None;
  Report report = Report::None;
  // The attempt being posted (Action::Attempt) or, for a report, the
  // attempts made so far.
  uint16_t attempt = 0;
  // Time since the outage began.
  uint32_t outageMs = 0;
};

inline uint32_t retryDelayMs(uint16_t attemptsMade) {
  if (attemptsMade == 0)
    return kFirstRetryMs;
  if (attemptsMade >= kFastAttempts)
    return kSlowRetryMs;
  uint32_t delay = kFirstRetryMs;
  for (uint16_t index = 1; index < attemptsMade && delay < kMaxFastRetryMs;
       ++index)
    delay *= 2;
  return delay < kMaxFastRetryMs ? delay : kMaxFastRetryMs;
}

class Supervisor {
public:
  Decision update(const Observation &observation) {
    Decision decision;
    const uint32_t now = observation.nowMs;
    if (observation.connected || observation.advertising ||
        observation.suppressed) {
      // A connection proves advertising worked, even if it was never seen.
      if (outage_ && attempts_ > 0 &&
          (observation.advertising || observation.connected)) {
        decision.report = Report::Restored;
        decision.attempt = attempts_;
        decision.outageMs = now - outageStartMs_;
      }
      outage_ = false;
      return decision;
    }
    if (!outage_) {
      outage_ = true;
      outageStartMs_ = now;
      attempts_ = 0;
      nextAttemptMs_ = now + kGraceMs;
      unsyncedReported_ = false;
      exhaustedReported_ = false;
    }
    decision.outageMs = now - outageStartMs_;
    decision.attempt = attempts_;
    if (!observation.hostSynced) {
      // NimBLE retries the sync itself and restarts advertising on success;
      // keep the grace ahead of a sync that is about to land.
      if (due(now + kGraceMs, nextAttemptMs_))
        nextAttemptMs_ = now + kGraceMs;
      if (!unsyncedReported_ && decision.outageMs >= kUnsyncedReportMs) {
        unsyncedReported_ = true;
        decision.report = Report::HostUnsynced;
      }
      return decision;
    }
    if (!due(now, nextAttemptMs_))
      return decision;
    if (attempts_ >= kFastAttempts && !exhaustedReported_) {
      exhaustedReported_ = true;
      decision.report = Report::FastAttemptsExhausted;
    }
    if (attempts_ < UINT16_MAX)
      ++attempts_;
    nextAttemptMs_ = now + retryDelayMs(attempts_);
    decision.action = Action::Attempt;
    decision.attempt = attempts_;
    return decision;
  }

  // The host resynchronized after a reset: start a fresh, fast budget once
  // the library's own restart has had its grace period.
  void noteHostResynced(uint32_t nowMs) {
    if (!outage_)
      return;
    attempts_ = 0;
    exhaustedReported_ = false;
    nextAttemptMs_ = nowMs + kGraceMs;
  }

  bool outageActive() const { return outage_; }
  uint16_t attempts() const { return attempts_; }

private:
  // Wrap-safe "now has reached deadline".
  static bool due(uint32_t now, uint32_t deadline) {
    return static_cast<int32_t>(now - deadline) >= 0;
  }

  bool outage_ = false;
  uint32_t outageStartMs_ = 0;
  uint32_t nextAttemptMs_ = 0;
  uint16_t attempts_ = 0;
  bool unsyncedReported_ = false;
  bool exhaustedReported_ = false;
};

// Field text of a `ble advertising_recovery` diagnostics event.
inline const char *reportPhase(Report report) {
  switch (report) {
  case Report::Restored:
    return "restored";
  case Report::FastAttemptsExhausted:
    return "fast_attempts_exhausted";
  case Report::HostUnsynced:
    return "host_unsynced";
  case Report::None:
    break;
  }
  return "none";
}

} // namespace ble_advertising_recovery
