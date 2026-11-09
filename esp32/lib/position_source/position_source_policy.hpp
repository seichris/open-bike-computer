#pragma once

#include <cstddef>
#include <cstdint>

// Pure decisions of the position-source part, kept free of Arduino and board
// headers so tools/tests/test_position_source_policy.cpp can exercise them.
namespace position_source {

// Which physical source currently populates the shared position record.
enum class Source : uint8_t { None = 0, Phone = 1, Gnss = 2 };

// Chooses which source may populate the shared position record. A fitted
// receiver with a valid fix holds the record for gnssHoldMs after its latest
// valid fix; outside that window the phone's positions apply, so navigation
// keeps working indoors and before the first fix.
struct Arbiter {
  uint32_t gnssHoldMs = 3000;
  uint32_t phoneHoldMs = 5000;
  bool gnssFitted = false;
  bool gnssFixSeen = false;
  bool gnssFixValid = false;
  uint32_t lastGnssFixMs = 0;
  bool phoneSeen = false;
  uint32_t lastPhoneMs = 0;

  bool gnssHolds(uint32_t nowMs) const {
    return gnssFitted && gnssFixSeen && gnssFixValid &&
           static_cast<uint32_t>(nowMs - lastGnssFixMs) < gnssHoldMs;
  }
  bool acceptsPhone(uint32_t nowMs) const { return !gnssHolds(nowMs); }
  Source active(uint32_t nowMs) const {
    if (gnssHolds(nowMs))
      return Source::Gnss;
    if (phoneSeen && static_cast<uint32_t>(nowMs - lastPhoneMs) < phoneHoldMs)
      return Source::Phone;
    return Source::None;
  }
  void noteGnss(uint32_t nowMs, bool fixValid) {
    gnssFixValid = fixValid;
    if (fixValid) {
      gnssFixSeen = true;
      lastGnssFixMs = nowMs;
    }
  }
  void notePhone(uint32_t nowMs) {
    phoneSeen = true;
    lastPhoneMs = nowMs;
  }
};

// Counts NMEA 0183 sentences byte by byte ('$' ... '*' hh <CR><LF>) and
// verifies the XOR checksum, independently of the fix parser. The baud probe
// and the sentence statistics rely on it.
class NmeaLineValidator {
public:
  enum class Event : uint8_t { None = 0, Valid = 1, Invalid = 2 };

  Event feed(char c) {
    if (c == '$') {
      inSentence_ = true;
      inChecksum_ = false;
      checksum_ = 0;
      expected_ = 0;
      hexDigits_ = 0;
      length_ = 0;
      return Event::None;
    }
    if (!inSentence_)
      return Event::None;
    if (++length_ > kMaxLength) {
      inSentence_ = false;
      return Event::Invalid;
    }
    if (inChecksum_) {
      const int digit = hexValue(c);
      if (digit >= 0 && hexDigits_ < 2) {
        expected_ = static_cast<uint8_t>((expected_ << 4) | digit);
        ++hexDigits_;
        return Event::None;
      }
      inSentence_ = false;
      if ((c == '\r' || c == '\n') && hexDigits_ == 2 && expected_ == checksum_)
        return Event::Valid;
      return Event::Invalid;
    }
    if (c == '*') {
      inChecksum_ = true;
      return Event::None;
    }
    if (c == '\r' || c == '\n') {
      inSentence_ = false;  // A sentence without a checksum is not counted.
      return Event::Invalid;
    }
    checksum_ ^= static_cast<uint8_t>(c);
    return Event::None;
  }

private:
  static constexpr size_t kMaxLength = 120;  // NMEA allows 82; proprietary slack.
  static int hexValue(char c) {
    if (c >= '0' && c <= '9')
      return c - '0';
    if (c >= 'A' && c <= 'F')
      return c - 'A' + 10;
    if (c >= 'a' && c <= 'f')
      return c - 'a' + 10;
    return -1;
  }
  bool inSentence_ = false;
  bool inChecksum_ = false;
  uint8_t checksum_ = 0;
  uint8_t expected_ = 0;
  uint8_t hexDigits_ = 0;
  size_t length_ = 0;
};

// Serial rate probe: starts at the board's rate, then tries the other common
// receiver rates while no valid sentence arrives within windowMs, and locks on
// the first valid sentence.
struct BaudProbe {
  static constexpr size_t kMaxCandidates = 6;
  uint32_t candidates[kMaxCandidates] = {0, 0, 0, 0, 0, 0};
  size_t count = 0;
  size_t index = 0;
  uint32_t windowMs = 4000;
  uint32_t windowStartMs = 0;
  bool locked = false;
  uint8_t switches = 0;

  void begin(uint32_t preferredBaud, uint32_t nowMs) {
    count = 0;
    index = 0;
    locked = false;
    switches = 0;
    windowStartMs = nowMs;
    const uint32_t common[] = {preferredBaud, 115200, 9600, 38400, 57600, 230400};
    for (uint32_t candidate : common) {
      if (candidate == 0)
        continue;
      bool known = false;
      for (size_t i = 0; i < count; ++i)
        known = known || candidates[i] == candidate;
      if (!known && count < kMaxCandidates)
        candidates[count++] = candidate;
    }
  }
  uint32_t current() const { return count == 0 ? 0 : candidates[index]; }
  // Returns true when the port must move to current(), which just changed.
  bool poll(uint32_t nowMs, bool validSentenceSeen) {
    if (locked || count == 0)
      return false;
    if (validSentenceSeen) {
      locked = true;
      return false;
    }
    if (static_cast<uint32_t>(nowMs - windowStartMs) < windowMs || count < 2)
      return false;
    index = (index + 1) % count;
    windowStartMs = nowMs;
    ++switches;
    return true;
  }
};

// Restart and poll-cadence bookkeeping of the I2C receiver reader in
// gnss_receiver.cpp. The module is restarted when no new stream byte arrives
// for silentWindowMs across at least kSilentPolls attempted polls, whether it
// never started (absent or unpowered) or its stream stopped later: an
// overflowed slave refuses reads until RESET restarts it (bench capture 9),
// and a module that answers with nothing forever needs the same. After each
// restart without progress the window doubles, up to kMaxSilentWindowMs, so
// an absent module is pulsed rarely; it returns to kSilentWindowMs once bytes
// flow. A restart also clears the failure count, so the module is polled at
// the kAbsentPollMs cadence while it comes back rather than the slow one.
// The result of one poll of the I2C receiver: no answer at all, an answer
// whose announced bytes were only partly drained, or a complete drain.
enum class I2cPollOutcome : uint8_t { noAnswer = 0, partial = 1, complete = 2 };

struct I2cReceiverPolicy {
  static constexpr uint32_t kSilentWindowMs = 15'000;
  static constexpr uint32_t kMaxSilentWindowMs = 300'000;
  static constexpr uint8_t kSilentPolls = 3;
  static constexpr uint32_t kIdlePollMs = 200;
  static constexpr uint32_t kAbsentPollMs = 2000;
  // A soldered receiver that keeps failing to answer is a hardware fault;
  // after a few misses the polls slow down so the log stays readable.
  static constexpr uint32_t kAbsentSlowPollMs = 30'000;
  static constexpr uint8_t kAbsentPollsBeforeSlow = 5;

  uint32_t progressBytes = 0;
  uint32_t progressMs = 0;
  uint32_t pollsSinceProgress = 0;
  uint32_t silentWindowMs = kSilentWindowMs;
  uint8_t consecutiveFailures = 0;

  // The reader started the module fresh at nowMs.
  void begin(uint32_t nowMs) { progressMs = nowMs; }

  // Records one poll: its outcome, and the stream's byte total read at nowMs
  // after the poll, which can take seconds. Returns true when the module must
  // be restarted; call restarted() once it has been.
  bool notePoll(I2cPollOutcome outcome, uint32_t streamBytes, uint32_t nowMs) {
    if (outcome != I2cPollOutcome::noAnswer)
      consecutiveFailures = 0;
    else if (consecutiveFailures < UINT8_MAX)
      ++consecutiveFailures;
    if (streamBytes != progressBytes) {
      progressBytes = streamBytes;
      progressMs = nowMs;
      pollsSinceProgress = 0;
      silentWindowMs = kSilentWindowMs;
      return false;
    }
    return ++pollsSinceProgress >= kSilentPolls &&
           static_cast<uint32_t>(nowMs - progressMs) >= silentWindowMs;
  }

  // Records a restart that finished at nowMs.
  void restarted(uint32_t nowMs) {
    progressMs = nowMs;
    pollsSinceProgress = 0;
    consecutiveFailures = 0;
    silentWindowMs = silentWindowMs * 2 < kMaxSilentWindowMs
                         ? silentWindowMs * 2
                         : kMaxSilentWindowMs;
  }

  // Delay before the next poll. A slave that answered the previous poll and
  // now refuses beyond the step budget is busy, not gone, so it is polled
  // again at once; only a slave that keeps refusing is polled slowly. A
  // partial drain left bytes behind, so the next query follows at once too.
  uint32_t nextPollDelayMs(I2cPollOutcome outcome, bool answeredBefore) const {
    switch (outcome) {
    case I2cPollOutcome::noAnswer:
      if (answeredBefore)
        return 0;
      return consecutiveFailures >= kAbsentPollsBeforeSlow ? kAbsentSlowPollMs
                                                           : kAbsentPollMs;
    case I2cPollOutcome::partial:
      return 0;
    case I2cPollOutcome::complete:
      break;
    }
    return kIdlePollMs;
  }
};

}  // namespace position_source
