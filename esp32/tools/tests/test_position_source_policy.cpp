// Host test of the position-source part's pure decisions: which source may
// populate the shared position record, NMEA sentence validation and the
// serial rate probe. Built by the render-ahead map architecture host check.
#include "../../lib/position_source/position_source_policy.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

using position_source::Arbiter;
using position_source::BaudProbe;
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
  assert(probe.count == 2 && probe.current() == 115200);
  // No valid sentence within the window: move to the next rate.
  assert(!probe.poll(3999, false));
  assert(probe.poll(4000, false));
  assert(probe.current() == 9600 && probe.switches == 1);
  // Still nothing: back to the first rate after another window.
  assert(probe.poll(8000, false));
  assert(probe.current() == 115200 && probe.switches == 2);
  // A valid sentence locks the probe; later polls never switch.
  assert(!probe.poll(9000, true));
  assert(probe.locked);
  assert(!probe.poll(20000, false));
  assert(probe.current() == 115200);
  // A board rate outside the common list is tried first; duplicates fold.
  BaudProbe custom;
  custom.begin(38400, 100);
  assert(custom.count == 3 && custom.candidates[0] == 38400 &&
         custom.candidates[1] == 115200 && custom.candidates[2] == 9600);
  BaudProbe folded;
  folded.begin(9600, 0);
  assert(folded.count == 2 && folded.candidates[0] == 9600 &&
         folded.candidates[1] == 115200);
  // No rate at all: nothing to probe, never switches.
  BaudProbe empty;
  empty.begin(0, 0);
  assert(empty.count == 2 && empty.current() == 115200);
}

}  // namespace

int main() {
  testArbiterWithoutReceiver();
  testArbiterWithReceiver();
  testNmeaValidator();
  testBaudProbe();
  std::cout << "test_position_source_policy passed\n";
  return 0;
}
