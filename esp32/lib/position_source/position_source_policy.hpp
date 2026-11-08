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
  static constexpr size_t kMaxCandidates = 3;
  uint32_t candidates[kMaxCandidates] = {0, 0, 0};
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
    const uint32_t common[] = {preferredBaud, 115200, 9600};
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

}  // namespace position_source
