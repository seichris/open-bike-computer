// Host test of the position-source part's pure decisions: which source may
// populate the shared position record, NMEA sentence validation, the serial
// rate probe, and the I2C reader's restart and poll cadence. Built by the
// render-ahead map architecture host check.
#include "../../lib/position_source/position_source_policy.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

using position_source::Arbiter;
using position_source::BaudProbe;
using position_source::I2cReceiverPolicy;
using position_source::NmeaLineValidator;
using position_source::Source;

namespace {

NmeaLineValidator::Event feedLine(NmeaLineValidator &validator,
                                  const char *line) {
  NmeaLineValidator::Event last = NmeaLineValidator::Event::None;
  for (const char *c = line; *c != '\0'; ++c) {
    const auto event = validator.feed(*c);
    if (event != NmeaLineValidator::Event::None)
      last = event;
  }
  return last;
}

void testArbiterWithoutReceiver() {
  Arbiter arbiter;
  assert(arbiter.acceptsPhone(0));
  assert(arbiter.active(0) == Source::None);
  arbiter.notePhone(1000);
  assert(arbiter.active(1000) == Source::Phone);
  assert(arbiter.active(1000 + arbiter.phoneHoldMs - 1) == Source::Phone);
  assert(arbiter.active(1000 + arbiter.phoneHoldMs) == Source::None);
  // A receiver fix reported on a board without one never holds the record.
  arbiter.noteGnss(2000, true);
  assert(arbiter.acceptsPhone(2000));
  assert(arbiter.active(2000) == Source::Phone);
}

void testArbiterWithReceiver() {
  Arbiter arbiter;
  arbiter.gnssFitted = true;
  // Before the first valid fix the phone populates the record.
  assert(arbiter.acceptsPhone(0));
  arbiter.notePhone(500);
  assert(arbiter.active(500) == Source::Phone);
  arbiter.noteGnss(600, false);  // sentences but no fix yet
  assert(arbiter.acceptsPhone(600));
  assert(arbiter.active(600) == Source::Phone);
  // A valid fix holds the record for gnssHoldMs.
  arbiter.noteGnss(1000, true);
  assert(!arbiter.acceptsPhone(1000));
  assert(arbiter.active(1000) == Source::Gnss);
  assert(!arbiter.acceptsPhone(1000 + arbiter.gnssHoldMs - 1));
  assert(arbiter.acceptsPhone(1000 + arbiter.gnssHoldMs));
  // The phone's latest position fills in once the fix is stale.
  arbiter.notePhone(4200);
  assert(arbiter.active(4200) == Source::Phone);
  // A fix that turns invalid releases the record at once.
  arbiter.noteGnss(4300, true);
  assert(arbiter.active(4300) == Source::Gnss);
  arbiter.noteGnss(4400, false);
  assert(arbiter.acceptsPhone(4400));
  assert(arbiter.active(4400) == Source::Phone);
  // Millisecond wrap-around keeps the hold window intact.
  Arbiter wrapped;
  wrapped.gnssFitted = true;
  wrapped.noteGnss(0xFFFFFF00U, true);
  assert(!wrapped.acceptsPhone(0x00000100U));
  assert(wrapped.acceptsPhone(0x00000C00U));
}

void testNmeaValidator() {
  NmeaLineValidator validator;
  assert(feedLine(validator, "$GNRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n") ==
         NmeaLineValidator::Event::Invalid);  // checksum of the GP form, not GN
  assert(feedLine(validator, "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n") ==
         NmeaLineValidator::Event::Valid);
  assert(feedLine(validator, "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n") ==
         NmeaLineValidator::Event::Valid);
  // Lower-case hex digits are accepted; a wrong checksum is not.
  assert(feedLine(validator, "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*4f\r\n") ==
         NmeaLineValidator::Event::Invalid);
  // A sentence without a checksum never counts as valid.
  assert(feedLine(validator, "$GPTXT,no checksum\r\n") == NmeaLineValidator::Event::Invalid);
  // Garbage between sentences (wrong baud) does not produce valid events, and
  // a fresh '$' resynchronises the validator.
  assert(feedLine(validator, "\xff\x7fzz$GP*\x01\r\n") == NmeaLineValidator::Event::Invalid);
  assert(feedLine(validator, "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n") ==
         NmeaLineValidator::Event::Valid);
  // Runaway lines are rejected before they can grow without bound.
  NmeaLineValidator runaway;
  runaway.feed('$');
  NmeaLineValidator::Event event = NmeaLineValidator::Event::None;
  for (int i = 0; i < 200 && event == NmeaLineValidator::Event::None; ++i)
    event = runaway.feed('A');
  assert(event == NmeaLineValidator::Event::Invalid);
}

void testBaudProbe() {
  BaudProbe probe;
  probe.begin(115200, 0);
  assert(probe.count == 5 && probe.current() == 115200);
  // No valid sentence within the window: move to the next rate.
  assert(!probe.poll(3999, false));
  assert(probe.poll(4000, false));
  assert(probe.current() == 9600 && probe.switches == 1 && probe.index == 1);
  // Still nothing: through the remaining rates, then back to the first.
  assert(probe.poll(8000, false) && probe.current() == 38400);
  assert(probe.poll(12000, false) && probe.current() == 57600);
  assert(probe.poll(16000, false) && probe.current() == 230400);
  assert(probe.poll(20000, false) && probe.current() == 115200 && probe.index == 0);
  assert(probe.switches == 5);
  // A valid sentence locks the probe; later polls never switch.
  assert(!probe.poll(21000, true));
  assert(probe.locked);
  assert(!probe.poll(40000, false));
  assert(probe.current() == 115200);
  // A board rate outside the common list is tried first; duplicates fold.
  BaudProbe custom;
  custom.begin(38400, 100);
  assert(custom.count == 5 && custom.candidates[0] == 38400 &&
         custom.candidates[1] == 115200 && custom.candidates[2] == 9600 &&
         custom.candidates[3] == 57600 && custom.candidates[4] == 230400);
  BaudProbe folded;
  folded.begin(9600, 0);
  assert(folded.count == 5 && folded.candidates[0] == 9600 &&
         folded.candidates[1] == 115200);
  // No rate at all: the common list alone.
  BaudProbe empty;
  empty.begin(0, 0);
  assert(empty.count == 5 && empty.current() == 115200);
}

using Policy = I2cReceiverPolicy;

void testI2cHealthyStream() {
  Policy policy;
  policy.begin(1000);
  uint32_t bytes = 0;
  // New bytes at every poll: never a restart, and the window stays at its
  // starting length.
  for (uint32_t now = 1200; now < 400'000; now += 200) {
    bytes += 300;
    assert(!policy.notePoll(true, bytes, now));
    assert(policy.silentWindowMs == Policy::kSilentWindowMs);
    assert(policy.nextPollDelayMs(true, false, true) == Policy::kIdlePollMs);
  }
  // A partial drain left bytes behind: the next query follows at once.
  assert(policy.nextPollDelayMs(true, true, true) == 0);
}

void testI2cAbsentModule() {
  Policy policy;
  policy.begin(0);
  // Four misses keep the 2 s cadence; the fifth slows polling down.
  for (uint32_t miss = 1; miss <= 4; ++miss) {
    assert(!policy.notePoll(false, 0, miss * 2000));
    assert(policy.nextPollDelayMs(false, false, false) == Policy::kAbsentPollMs);
  }
  assert(!policy.notePoll(false, 0, 10'000));
  assert(policy.nextPollDelayMs(false, false, false) ==
         Policy::kAbsentSlowPollMs);
  // The next slow poll is past the window with more than three polls: restart.
  assert(policy.notePoll(false, 0, 40'000));
  policy.restarted(40'100);
  assert(policy.silentWindowMs == 2 * Policy::kSilentWindowMs);
  assert(policy.pollsSinceProgress == 0 && policy.progressMs == 40'100);
  // The restart clears the failure count: the module that comes back up is
  // polled at the 2 s cadence, not the slow one.
  assert(policy.consecutiveFailures == 0);
  assert(policy.nextPollDelayMs(false, false, false) == Policy::kAbsentPollMs);
}

void testI2cSilentWindow() {
  // A module that answers but delivers nothing.
  Policy policy;
  policy.begin(1000);
  // A long first poll is past the window, but three polls are needed.
  assert(!policy.notePoll(true, 0, 20'000));
  assert(!policy.notePoll(true, 0, 20'200));
  assert(policy.notePoll(true, 0, 20'400));
  policy.restarted(20'500);
  // And many polls never restart it before the doubled window has passed.
  for (uint32_t now = 20'700; now < 20'500 + 30'000; now += 200)
    assert(!policy.notePoll(true, 0, now));
  assert(policy.notePoll(true, 0, 20'500 + 30'000));
}

void testI2cWindowDoublesAndResets() {
  Policy policy;
  policy.begin(0);
  const uint32_t windows[] = {30'000, 60'000, 120'000, 240'000, 300'000,
                              300'000};
  for (uint32_t window : windows) {
    const uint32_t due = policy.progressMs + policy.silentWindowMs;
    // Three polls one millisecond early: the window is not over yet.
    for (int poll = 0; poll < 3; ++poll)
      assert(!policy.notePoll(false, 0, due - 1));
    assert(policy.notePoll(false, 0, due));
    policy.restarted(due + 100);
    assert(policy.silentWindowMs == window);
  }
  // Bytes flowing again return the window to its starting length.
  assert(!policy.notePoll(true, 42, policy.progressMs + 10));
  assert(policy.silentWindowMs == Policy::kSilentWindowMs);
  assert(policy.pollsSinceProgress == 0);
}

void testI2cStreamStops() {
  Policy policy;
  policy.begin(0);
  assert(!policy.notePoll(true, 500, 1000));
  assert(!policy.notePoll(true, 900, 1200));  // the last new bytes
  // Afterwards the slave alternates between refusing and answering empty:
  // the restart follows 15 s after the last new byte, not after the start.
  uint32_t now = 1400;
  for (; now < 1200 + Policy::kSilentWindowMs; now += 200)
    assert(!policy.notePoll(now % 400 == 0, 900, now));
  assert(policy.notePoll(false, 900, 1200 + Policy::kSilentWindowMs));
}

void testI2cPollCadence() {
  Policy policy;
  policy.begin(0);
  assert(policy.nextPollDelayMs(true, false, false) == Policy::kIdlePollMs);
  assert(policy.nextPollDelayMs(true, true, false) == 0);
  // A slave that answered the previous poll and now refuses is busy, not
  // gone: poll again at once.
  assert(!policy.notePoll(false, 0, 100));
  assert(policy.nextPollDelayMs(false, false, true) == 0);
  // The failure count saturates instead of wrapping back to the fast cadence.
  for (int miss = 0; miss < 300; ++miss)
    assert(!policy.notePoll(false, 0, 200));
  assert(policy.consecutiveFailures == UINT8_MAX);
  assert(policy.nextPollDelayMs(false, false, false) ==
         Policy::kAbsentSlowPollMs);
  // One answer clears it.
  assert(!policy.notePoll(true, 0, 300));
  assert(policy.consecutiveFailures == 0);
  assert(!policy.notePoll(false, 0, 400));
  assert(policy.nextPollDelayMs(false, false, false) == Policy::kAbsentPollMs);
}

void testI2cClockWrap() {
  Policy policy;
  const uint32_t start = UINT32_MAX - 5'000;
  policy.begin(start);
  // The millisecond clock wraps during the window.
  assert(!policy.notePoll(true, 0, start + 2'000));
  assert(!policy.notePoll(true, 0, start + 4'000));
  assert(!policy.notePoll(true, 0, start + Policy::kSilentWindowMs - 1));
  assert(policy.notePoll(true, 0, start + Policy::kSilentWindowMs));
}

}  // namespace

int main() {
  testArbiterWithoutReceiver();
  testArbiterWithReceiver();
  testNmeaValidator();
  testBaudProbe();
  testI2cHealthyStream();
  testI2cAbsentModule();
  testI2cSilentWindow();
  testI2cWindowDoublesAndResets();
  testI2cStreamStops();
  testI2cPollCadence();
  testI2cClockWrap();
  std::cout << "test_position_source_policy passed\n";
  return 0;
}
