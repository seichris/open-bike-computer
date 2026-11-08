#include "gnss_receiver.hpp"

#include "../board/board.hpp"

#if BOARD_GNSS_FITTED

#include <Arduino.h>
#include <HardwareSerial.h>

#include <type_traits>

#include "../gps/gps.hpp"
#include "../waveshare_board/i2c_bus.hpp"
#include "../waveshare_board/tca9554.hpp"
#if PERSISTENT_RIDE_DIAGNOSTICS
#include "../ride_diagnostics/ride_diagnostics.hpp"
#endif

extern Gps gps;

namespace position_source::gnss_receiver {

namespace {
constexpr bool kUart = board::gnss::transport == board::GnssTransport::uart;
constexpr bool kI2c = board::gnss::transport == board::GnssTransport::i2c;
static_assert(kUart || kI2c, "a fitted receiver needs a transport");

portMUX_TYPE mux = portMUX_INITIALIZER_UNLOCKED;
GnssStatus state;
NmeaLineValidator validator;
bool probeReported = false;
uint8_t firstBytes[32] = {};
uint8_t firstByteCount = 0;
bool firstBytesReported = false;
// Parser outcomes per byte: sentences the NMEA parser completed and bytes it
// rejected, so a capture tells a stream the parser accepts from one it
// does not (capture 17: thousands of checksum-valid sentences, nothing
// parsed). Diagnostics profiles also print one raw sample of the stream.
uint32_t decodeCompleted = 0;
uint32_t decodeInvalid = 0;
// Sentence types seen (by the five characters after '$'): the parser closes
// an interval only on RMC, so a stream without RMC never yields a fix.
enum SentenceType : uint8_t { kRmc, kGga, kGll, kGsa, kGsv, kVtg, kZda, kOther, kTypeCount };
uint32_t typeCounts[kTypeCount] = {};
char typeHeader[6] = {};
uint8_t typeHeaderLength = 0;
bool typeHeaderCounted = false;
#if FIRMWARE_DIAGNOSTICS
char sample[1201] = {};
uint16_t sampleLength = 0;
bool sampleReported = false;
#endif

void tallySentenceType(char c) {
  if (c == '$') {
    typeHeaderLength = 0;
    typeHeaderCounted = false;
    return;
  }
  if (typeHeaderCounted)
    return;
  if (typeHeaderLength < 5) {
    typeHeader[typeHeaderLength++] = c;
    return;
  }
  typeHeaderCounted = true;
  const char *type = typeHeader + 2;  // after the two-character talker
  auto is = [type](const char *name) {
    return type[0] == name[0] && type[1] == name[1] && type[2] == name[2];
  };
  SentenceType which = kOther;
  if (typeHeader[0] == 'G') {
    if (is("RMC")) which = kRmc;
    else if (is("GGA")) which = kGga;
    else if (is("GLL")) which = kGll;
    else if (is("GSA")) which = kGsa;
    else if (is("GSV")) which = kGsv;
    else if (is("VTG")) which = kVtg;
    else if (is("ZDA")) which = kZda;
  }
  ++typeCounts[which];
}
constexpr uint8_t kMaxResetPulses = 3;
bool fixReported = false;
uint32_t lastFixLogMs = 0;
constexpr uint32_t kFixLogIntervalMs = 30'000;
// Diagnostics profiles repeat the BOOT_GNSS record with its counters at this
// interval once the probe locked, so a capture ends with the stream's totals.
uint32_t lastStatusMs = 0;
constexpr uint32_t kStatusIntervalMs = 30'000;
constexpr uint32_t kTaskStackBytes = 8192;

GnssStatus snapshot() {
  portENTER_CRITICAL(&mux);
  const GnssStatus copy = state;
  portEXIT_CRITICAL(&mux);
  return copy;
}

void printBoot(const char *probeState) {
  const GnssStatus s = snapshot();
  char line[352] = {};
  size_t used = static_cast<size_t>(snprintf(
      line, sizeof(line), "BOOT_GNSS schema=1 fitted=1 module=%s transport=%s reset=%s ",
      position_source::moduleName(), kUart ? "uart" : "i2c",
      board::gnss::resetViaExpander ? "expander" : "none"));
  if (used < sizeof(line)) {
    if constexpr (kUart) {
      used += static_cast<size_t>(snprintf(
          line + used, sizeof(line) - used, "uart=%u rx=%u tx=%u baud=%lu ",
          static_cast<unsigned>(board::gnss::uart),
          static_cast<unsigned>(board::gnss::rx),
          static_cast<unsigned>(board::gnss::tx),
          static_cast<unsigned long>(s.baud)));
    } else {
      used += static_cast<size_t>(snprintf(
          line + used, sizeof(line) - used,
          "i2c=0x%02x/0x%02x present=%u polls=%lu errors=%lu backlog=%lu "
          "answerMs=%u/%u nacks=%lu/%lu/%lu/%lu repeats=%lu ",
          static_cast<unsigned>(board::gnss::i2cCommandAddress),
          static_cast<unsigned>(board::gnss::i2cDataAddress),
          s.portOpen ? 1U : 0U, static_cast<unsigned long>(s.polls),
          static_cast<unsigned long>(s.pollErrors),
          static_cast<unsigned long>(s.backlog),
          static_cast<unsigned>(s.lengthWaitMs),
          static_cast<unsigned>(s.dataWaitMs),
          static_cast<unsigned long>(s.dummyNacks),
          static_cast<unsigned long>(s.requestNacks),
          static_cast<unsigned long>(s.lengthNacks),
          static_cast<unsigned long>(s.dataNacks),
          static_cast<unsigned long>(s.requestRepeats)));
    }
  }
  if (used < sizeof(line)) {
    // fixes counts the parser's completed intervals (every interval, fix or
    // not); sats is satellites used in the fix over satellites in view
    // (from GSV); fixStatus is NeoGPS's status of the last interval
    // (0 none, 2 time only, 3 standard, 4 differential); decode is the
    // parser's completed sentences over rejected bytes.
    snprintf(line + used, sizeof(line) - used,
             "probe=%s bytes=%lu sentences=%lu invalid=%lu resetPulses=%u "
             "fixes=%lu sats=%u/%u fixStatus=%u decode=%lu/%lu "
             "types=%lu/%lu/%lu/%lu/%lu/%lu/%lu/%lu",
             probeState, static_cast<unsigned long>(s.bytes),
             static_cast<unsigned long>(s.validSentences),
             static_cast<unsigned long>(s.invalidSentences),
             static_cast<unsigned>(s.resetPulses),
             static_cast<unsigned long>(s.fixes),
             static_cast<unsigned>(s.satellites),
             static_cast<unsigned>(GPS.sat_count),
             static_cast<unsigned>(fix.status),
             static_cast<unsigned long>(decodeCompleted),
             static_cast<unsigned long>(decodeInvalid),
             static_cast<unsigned long>(typeCounts[kRmc]),
             static_cast<unsigned long>(typeCounts[kGga]),
             static_cast<unsigned long>(typeCounts[kGll]),
             static_cast<unsigned long>(typeCounts[kGsa]),
             static_cast<unsigned long>(typeCounts[kGsv]),
             static_cast<unsigned long>(typeCounts[kVtg]),
             static_cast<unsigned long>(typeCounts[kZda]),
             static_cast<unsigned long>(typeCounts[kOther]));
  }
  Serial.println(line);
}

void recordDiagnostic(const char *event, bool available, bool fixValid,
                      uint32_t sentences, uint32_t invalid) {
#if PERSISTENT_RIDE_DIAGNOSTICS
  char fields[160] = {};
  snprintf(fields, sizeof(fields),
           "{\"source\":\"gnss\",\"available\":%s,\"fixValid\":%s,"
           "\"eventCount\":%lu,\"droppedCount\":%lu}",
           available ? "true" : "false", fixValid ? "true" : "false",
           static_cast<unsigned long>(sentences),
           static_cast<unsigned long>(invalid));
  ride_diagnostics::record(ride_diagnostics::Level::Info, "gnss", event,
                           fields);
#else
  (void)event;
  (void)available;
  (void)fixValid;
  (void)sentences;
  (void)invalid;
#endif
}

void releaseReset() {
  if (!board::gnss::resetViaExpander)
    return;
  // The receiver's RESET is active low. Driving the expander pin high keeps
  // the module running without restarting its acquisition.
  const bool ok =
      waveshare_board::tca9554::configureOutput(board::gnss::resetExpanderPin) &&
      waveshare_board::tca9554::setPin(board::gnss::resetExpanderPin, true);
  Serial.printf("GNSS: reset line %s\n",
                ok ? "released through the expander"
                   : "not controllable (expander write failed)");
}

// Pulses the receiver's RESET (active low) through the expander: a module
// that never produced a byte may be held by a stale reset or need a restart.
void pulseReset(const char *reason) {
  if (!board::gnss::resetViaExpander)
    return;
  const bool ok =
      waveshare_board::tca9554::setPin(board::gnss::resetExpanderPin, false);
  delay(100);
  const bool released =
      waveshare_board::tca9554::setPin(board::gnss::resetExpanderPin, true);
  portENTER_CRITICAL(&mux);
  ++state.resetPulses;
  const uint8_t pulses = state.resetPulses;
  portEXIT_CRITICAL(&mux);
  Serial.printf("GNSS: reset pulse %u %s (%s)\n", static_cast<unsigned>(pulses),
                ok && released ? "issued" : "failed at the expander", reason);
}

void drainFixes();

// Feeds received bytes to the checksum validator and the NMEA parser and
// returns how many checksum-valid sentences they completed.
uint32_t consume(const uint8_t *data, size_t len) {
  uint32_t valid = 0;
  uint32_t invalid = 0;
  for (size_t i = 0; i < len; ++i) {
    const char c = static_cast<char>(data[i]);
    if (firstByteCount < sizeof(firstBytes))
      firstBytes[firstByteCount++] = data[i];
    const NmeaLineValidator::Event event = validator.feed(c);
    if (event == NmeaLineValidator::Event::Valid)
      ++valid;
    else if (event == NmeaLineValidator::Event::Invalid)
      ++invalid;
    tallySentenceType(c);
    // handle(), not decode(): decode() parses a sentence, and only handle()
    // stores the completed fix into the parser's buffer where available()
    // and read() find it (the old serial path reached it through
    // available(port)). Captures 18 and 19 fed decode() and saw every
    // sentence parsed with no interval ever closing.
    const NMEAGPS::decode_t decoded = GPS.handle(static_cast<uint8_t>(c));
    if (decoded == NMEAGPS::DECODE_COMPLETED) {
      ++decodeCompleted;
      // The parser buffers one fix and the next completed sentence pops an
      // unread one; VTG follows RMC within the same chunk, so the fix must
      // be read before the next sentence completes (capture 20: one fix in
      // four minutes, whenever a chunk ended between the two). A UART
      // reader never met this because its bytes trickle in.
      drainFixes();
    }
    else if (decoded == NMEAGPS::DECODE_CHR_INVALID)
      ++decodeInvalid;
#if FIRMWARE_DIAGNOSTICS
    if (!sampleReported && probeReported && sampleLength < sizeof(sample) - 1) {
      const bool lineEnd = c == '\r' || c == '\n';
      const bool printable = c >= ' ' && c <= '~';
      sample[sampleLength++] = lineEnd ? '|' : printable ? c : '.';
    }
#endif
  }
  if (len == 0)
    return 0;
  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&mux);
  state.bytes += len;
  state.validSentences += valid;
  state.invalidSentences += invalid;
  if (valid != 0)
    state.lastSentenceMs = nowMs;
  portEXIT_CRITICAL(&mux);
#if FIRMWARE_DIAGNOSTICS
  if (!sampleReported && sampleLength == sizeof(sample) - 1) {
    sampleReported = true;
    for (uint16_t offset = 0; offset < sampleLength; offset += 400) {
      Serial.printf("GNSS: sample %u: %.400s\n",
                    static_cast<unsigned>(offset / 400), sample + offset);
    }
  }
  if (!firstBytesReported && firstByteCount == sizeof(firstBytes)) {
    firstBytesReported = true;
    char hex[3 * sizeof(firstBytes) + 1] = {};
    for (uint8_t i = 0; i < sizeof(firstBytes); ++i)
      snprintf(hex + 3 * i, 4, "%02x ", static_cast<unsigned>(firstBytes[i]));
    Serial.printf("GNSS: first bytes: %s\n", hex);
  }
#endif
  return valid;
}

// Applies every fix the parser completed to the shared position record.
void drainFixes() {
  while (GPS.available()) {
    fix = GPS.read();
    gps.getGPSData();
    const bool fixValid =
        fix.status >= gps_fix::STATUS_STD && static_cast<bool>(fix.valid.location);
    const uint32_t nowMs = millis();
    portENTER_CRITICAL(&mux);
    ++state.fixes;
    state.fixValid = fixValid;
    state.satellites = fix.satellites;
    if (fixValid)
      state.lastFixMs = nowMs;
    portEXIT_CRITICAL(&mux);
    position_source::noteGnssFix(nowMs, fixValid);
    if (fixValid && (!fixReported ||
                     static_cast<uint32_t>(nowMs - lastFixLogMs) >= kFixLogIntervalMs)) {
      const GnssStatus s = snapshot();
#if FIRMWARE_DIAGNOSTICS
      Serial.printf("GNSS: fix sats=%u lat=%.6f lon=%.6f speed=%u heading=%s%u\n",
                    static_cast<unsigned>(s.satellites), gps.gpsData.latitude,
                    gps.gpsData.longitude,
                    static_cast<unsigned>(gps.gpsData.speed),
                    gps.gpsData.headingValid ? "" : "invalid:",
                    static_cast<unsigned>(gps.gpsData.heading));
#endif
      recordDiagnostic(fixReported ? "fix_checkpoint" : "fix", true, true,
                       s.validSentences, s.invalidSentences);
      fixReported = true;
      lastFixLogMs = nowMs;
    }
  }
}

// The first checksum-valid sentences arrived: the receiver is fitted,
// powered, out of reset and reachable over its transport.
void reportLocked() {
  if (probeReported)
    return;
  probeReported = true;
  portENTER_CRITICAL(&mux);
  state.probeLocked = true;
  portEXIT_CRITICAL(&mux);
  printBoot("ok");
  lastStatusMs = millis();
  const GnssStatus s = snapshot();
  recordDiagnostic("probe", true, false, s.validSentences, s.invalidSentences);
}

// NMEA on a UART. The receiver's rate is unknown until checksum-valid
// sentences arrive, so a probe cycles the common rates, and a complete round
// without a byte pulses RESET.
struct UartTransport {
  HardwareSerial port{board::gnss::uart};
  BaudProbe probe;
  bool validSinceSwitch = false;
  uint32_t bytesAtRoundStart = 0;

  void begin(uint32_t nowMs) {
    probe.begin(board::gnss::baud, nowMs);
    port.setRxBufferSize(1024);
    port.begin(probe.current(), SERIAL_8N1, board::gnss::rx, board::gnss::tx);
    portENTER_CRITICAL(&mux);
    state.portOpen = true;
    state.baud = probe.current();
    portEXIT_CRITICAL(&mux);
  }

  // Drains the port and runs the rate probe. Returns the delay before the
  // next pass (0 while bytes keep arriving) and whether the probe locked.
  uint32_t service(uint32_t nowMs, bool &locked) {
    bool readAny = false;
    for (;;) {
      uint8_t chunk[64];
      size_t n = 0;
      while (n < sizeof(chunk) && port.available() > 0)
        chunk[n++] = static_cast<uint8_t>(port.read());
      if (n == 0)
        break;
      readAny = true;
      if (consume(chunk, n) != 0)
        validSinceSwitch = true;
    }
    if (probe.poll(nowMs, validSinceSwitch)) {
      validSinceSwitch = false;
      port.updateBaudRate(probe.current());
      portENTER_CRITICAL(&mux);
      state.baud = probe.current();
      const uint32_t bytesNow = state.bytes;
      const uint8_t pulses = state.resetPulses;
      portEXIT_CRITICAL(&mux);
      printBoot("retry");
      // Back at the first rate after a round that saw nothing at all.
      if (probe.index == 0 && bytesNow == bytesAtRoundStart &&
          pulses < kMaxResetPulses) {
        pulseReset("no bytes during a probe round");
      }
      if (probe.index == 0)
        bytesAtRoundStart = bytesNow;
    }
    locked = probe.locked;
    return readAny ? 0 : 20;
  }
};

// The receiver's I2C slave, polled with Quectel's command/answer scheme the
// way Waveshare's LC76G examples do: a request goes to the command address
// and its answer is read from the data address. A request is a register and
// a length, both little endian, around the 0x51 0xAA marker. Register 0x0008
// answers with the number of buffered bytes, register 0x2000 with that many
// bytes of the NMEA stream. The slave refuses (NACKs) transactions it is
// not ready for: on the bench it refused an answer read 100 ms after the
// request (the gap the vendor's ESP32 example leaves) and a request write
// that followed an acknowledged probe within a millisecond. The vendor's
// Raspberry Pi driver therefore precedes every transaction with a 10 ms
// gap, retries each step on refusal and starts each poll with a one-byte
// dummy write that checks the slave; this transport does the same and
// counts the refusals per step. With those gaps the slave acknowledged every
// write on the bench but still refused reads for stretches well beyond
// 250 ms (capture 8: 9 KB buffered at the first answered poll), so the
// retry budget is long and the stream is drained the way the vendor driver
// does it: one length query, then data requests of up to STREAM_BUFFER_BYTES
// each until the announced length is read, without querying again.
struct I2cTransport {
  // Every transaction with the slave waits kStepGapMs first and is tried
  // while the slave refuses: a write up to kWriteAttempts times, an answer
  // read up to kReadsPerRequest times per request. An answer belongs to its
  // request, and the slave kept refusing a read for seconds while busy with
  // new output (capture 10: bursts of 3.5 s every 8 to 18 s), so after
  // kReadsPerRequest refusals the request is sent again, up to
  // kRequestRounds times, the vendor driver's "restart". The longest waits
  // are reported so the budget can be tightened from evidence.
  static constexpr uint32_t kStepGapMs = 20;
  static constexpr uint8_t kWriteAttempts = 10;
  static constexpr uint8_t kReadsPerRequest = 5;
  static constexpr uint8_t kRequestRounds = 20;
  static constexpr uint32_t kIdlePollMs = 200;
  static constexpr uint32_t kAbsentPollMs = 2000;
  // A soldered receiver that keeps failing to answer is a hardware fault;
  // after a few misses the polls slow down so the log stays readable.
  static constexpr uint32_t kAbsentSlowPollMs = 30'000;
  static constexpr uint8_t kAbsentPollsBeforeSlow = 5;
  static constexpr uint32_t kSilentWindowMs = 15'000;
  static constexpr size_t kChunkBytes = waveshare_board::i2c::STREAM_BUFFER_BYTES;
  uint8_t chunk[kChunkBytes] = {};
  uint32_t silentSinceMs = 0;
  uint8_t consecutiveFailures = 0;
  bool sawValidSentence = false;

  enum class Step : uint8_t { dummy, request, length, data };

  // One transaction with the slave, the vendor driver's way: a gap, a try,
  // and more tries while the slave refuses, up to attempts. Counts refusals
  // per step and adds the time spent to waitedMs.
  template <typename Fn>
  bool step(Step which, uint8_t attempts, uint32_t &waitedMs,
            Fn &&transaction) {
    for (uint8_t attempt = 0; attempt < attempts; ++attempt) {
      vTaskDelay(pdMS_TO_TICKS(kStepGapMs));
      waitedMs += kStepGapMs;
      if (transaction())
        return true;
      portENTER_CRITICAL(&mux);
      switch (which) {
      case Step::dummy:
        ++state.dummyNacks;
        break;
      case Step::request:
        ++state.requestNacks;
        break;
      case Step::length:
        ++state.lengthNacks;
        break;
      case Step::data:
        ++state.dataNacks;
        break;
      }
      portEXIT_CRITICAL(&mux);
    }
    return false;
  }

  // The one-byte write the vendor driver uses to check that the slave is
  // alive before a request (an address-only probe is not what it does).
  bool dummyWrite() {
    static constexpr uint8_t dummy[1] = {0x00};
    uint32_t waitedMs = 0;
    return step(Step::dummy, kWriteAttempts, waitedMs, [] {
      return waveshare_board::i2c::writeBytes(board::gnss::i2cCommandAddress,
                                              dummy, sizeof(dummy), "GNSS", 1);
    });
  }

  // A request and its answer. When the slave keeps refusing the answer
  // read, the request is sent again rather than the read repeated further,
  // as the vendor driver does. Records the longest total wait per answer
  // kind and counts the repeated requests.
  bool exchange(Step answerStep, const uint8_t (&bytes)[8], uint8_t *data,
                size_t len) {
    uint32_t waitedMs = 0;
    for (uint8_t round = 0; round < kRequestRounds; ++round) {
      if (round != 0) {
        portENTER_CRITICAL(&mux);
        ++state.requestRepeats;
        portEXIT_CRITICAL(&mux);
      }
      if (!step(Step::request, kWriteAttempts, waitedMs, [&bytes] {
            return waveshare_board::i2c::writeBytes(
                board::gnss::i2cCommandAddress, bytes, sizeof(bytes), "GNSS",
                1);
          }))
        return false;
      if (step(answerStep, kReadsPerRequest, waitedMs, [data, len] {
            return waveshare_board::i2c::readStream(
                board::gnss::i2cDataAddress, data, len, "GNSS", 1);
          })) {
        portENTER_CRITICAL(&mux);
        if (answerStep == Step::length && waitedMs > state.lengthWaitMs)
          state.lengthWaitMs = static_cast<uint16_t>(waitedMs);
        if (answerStep == Step::data && waitedMs > state.dataWaitMs)
          state.dataWaitMs = static_cast<uint16_t>(waitedMs);
        portEXIT_CRITICAL(&mux);
        return true;
      }
    }
    return false;
  }

  void begin(uint32_t nowMs) {
    // The module runs from power-on and its buffer predates the reader by
    // seconds on a cold boot and by minutes after a warm reset. On the bench
    // a slave whose buffer had overflowed refused reads for the whole window
    // until RESET restarted it, after which every poll was served at once
    // (capture 9). So the reader starts the module fresh; with the RTC rail
    // on V_BCKP that is a hot start. The reader task makes the first
    // contact once the module is up again.
    pulseReset("fresh start with the reader");
    silentSinceMs = nowMs;
  }

  enum class Outcome : uint8_t { noAnswer, partial, complete };

  // One poll: the length query, then the announced bytes in chunks, each
  // consumed as it arrives. received is the number of stream bytes read.
  Outcome poll(size_t &received) {
    received = 0;
    if (!dummyWrite())
      return Outcome::noAnswer;
    static constexpr uint8_t lengthRequest[8] = {0x08, 0x00, 0x51, 0xAA,
                                                 0x04, 0x00, 0x00, 0x00};
    uint8_t answerBytes[4] = {};
    if (!exchange(Step::length, lengthRequest, answerBytes, sizeof(answerBytes)))
      return Outcome::noAnswer;
    const uint32_t available = static_cast<uint32_t>(answerBytes[0]) |
                               (static_cast<uint32_t>(answerBytes[1]) << 8) |
                               (static_cast<uint32_t>(answerBytes[2]) << 16) |
                               (static_cast<uint32_t>(answerBytes[3]) << 24);
    portENTER_CRITICAL(&mux);
    if (available > state.backlog)
      state.backlog = available;
    portEXIT_CRITICAL(&mux);
    // An implausible length (the vendor driver rejects 35 KB and more) is
    // treated as an unanswered poll rather than read.
    if (available >= 35U * 1024U)
      return Outcome::noAnswer;
    uint32_t remaining = available;
    while (remaining != 0) {
      const uint32_t want = remaining < kChunkBytes
                                ? remaining
                                : static_cast<uint32_t>(kChunkBytes);
      const uint8_t dataRequest[8] = {0x00,
                                      0x20,
                                      0x51,
                                      0xAA,
                                      static_cast<uint8_t>(want),
                                      static_cast<uint8_t>(want >> 8),
                                      static_cast<uint8_t>(want >> 16),
                                      static_cast<uint8_t>(want >> 24)};
      if (!exchange(Step::data, dataRequest, chunk, want))
        return received != 0 ? Outcome::partial : Outcome::noAnswer;
      if (consume(chunk, want) != 0)
        sawValidSentence = true;
      received += want;
      remaining -= want;
    }
    return Outcome::complete;
  }

  // One poll and its bookkeeping. Returns the delay before the next poll (0
  // while the receiver still has buffered bytes) and whether valid sentences
  // have arrived.
  uint32_t service(uint32_t nowMs, bool &locked) {
    size_t received = 0;
    const Outcome outcome = poll(received);
    const bool answered = outcome != Outcome::noAnswer;
    portENTER_CRITICAL(&mux);
    ++state.polls;
    if (!answered)
      ++state.pollErrors;
    const bool wasPresent = state.portOpen;
    state.portOpen = answered;
    const uint32_t bytesNow = state.bytes;
    const uint8_t pulses = state.resetPulses;
    portEXIT_CRITICAL(&mux);
    if (answered)
      consecutiveFailures = 0;
    else if (consecutiveFailures < UINT8_MAX)
      ++consecutiveFailures;
    if (answered != wasPresent)
      printBoot(probeReported ? "ok" : answered ? "pending" : "retry");
    // No byte for a while, answering or not: the module may be held by a
    // stale reset or need a restart.
    if (bytesNow == 0 &&
        static_cast<uint32_t>(nowMs - silentSinceMs) >= kSilentWindowMs) {
      silentSinceMs = nowMs;
      if (pulses < kMaxResetPulses) {
        pulseReset("no bytes in 15 s");
        printBoot("retry");
      }
    }
    locked = sawValidSentence;
    if (!answered) {
      // A slave that answered the previous poll and now refuses beyond the
      // step budget is busy, not gone: poll again at once. Only a slave
      // that keeps refusing is polled slowly.
      if (wasPresent)
        return 0;
      return consecutiveFailures >= kAbsentPollsBeforeSlow ? kAbsentSlowPollMs
                                                           : kAbsentPollMs;
    }
    // A partial drain left bytes behind: query again soon.
    return outcome == Outcome::partial ? 0 : kIdlePollMs;
  }
};

using Transport = std::conditional_t<kI2c, I2cTransport, UartTransport>;
Transport transport;

void readerTask(void *) {
  for (;;) {
    bool locked = false;
    const uint32_t delayMs = transport.service(millis(), locked);
    drainFixes();
    if (locked)
      reportLocked();
#if FIRMWARE_DIAGNOSTICS
    if (probeReported &&
        static_cast<uint32_t>(millis() - lastStatusMs) >= kStatusIntervalMs) {
      lastStatusMs = millis();
      printBoot("ok");
    }
#endif
    vTaskDelay(delayMs == 0 ? 1 : pdMS_TO_TICKS(delayMs));
  }
}
}  // namespace

#if FIRMWARE_DIAGNOSTICS
// Passive look at the candidate receiver lines before the UART claims them:
// with a pull-down a driven-high (idle UART) line still reads high and an
// unconnected pad reads low; with a pull-up a driven-low line reads low; edges
// within a short window show traffic. Inputs only, nothing is driven. Besides
// the board's rx/tx this also checks the H2 header's UART0 pads (GPIO43/44),
// the pins an earlier hardware note called the GPS pads, so a receiver wired
// there is found as well. Only the UART transport runs it; on the bench the
// 1.75 with the receiver showed every line floating, which is what sent the
// part to the receiver's I2C slave.
void probeLines() {
  const uint8_t candidates[] = {board::gnss::rx, board::gnss::tx, 43, 44};
  char report[160] = {};
  size_t used = 0;
  for (size_t i = 0; i < sizeof(candidates); ++i) {
    const uint8_t pin = candidates[i];
    bool seen = false;
    for (size_t j = 0; j < i; ++j)
      seen = seen || candidates[j] == pin;
    if (seen || pin == board::noPin)
      continue;
    pinMode(pin, INPUT_PULLDOWN);
    delay(5);
    const bool highWithPullDown = digitalRead(pin) == HIGH;
    pinMode(pin, INPUT_PULLUP);
    delay(5);
    const bool highWithPullUp = digitalRead(pin) == HIGH;
    uint32_t edges = 0;
    int last = digitalRead(pin);
    const uint32_t start = micros();
    while (static_cast<uint32_t>(micros() - start) < 300'000U) {
      const int level = digitalRead(pin);
      if (level != last) {
        ++edges;
        last = level;
      }
    }
    pinMode(pin, INPUT);
    const char *level = highWithPullDown && highWithPullUp ? "driven_high"
                        : (!highWithPullDown && !highWithPullUp) ? "driven_low"
                                                                 : "floating";
    used += static_cast<size_t>(snprintf(report + used, sizeof(report) - used,
                                         " pin%u=%s:%lu", static_cast<unsigned>(pin),
                                         level, static_cast<unsigned long>(edges)));
    if (used >= sizeof(report) - 1)
      break;
  }
  Serial.printf("BOOT_GNSS_LINES schema=1%s\n", report);
}
#endif

void begin() {
  portENTER_CRITICAL(&mux);
  state.fitted = true;
  portEXIT_CRITICAL(&mux);
  releaseReset();
#if FIRMWARE_DIAGNOSTICS
  if constexpr (kUart)
    probeLines();
#endif
  transport.begin(millis());
  printBoot("pending");
}

void startTask() {
  xTaskCreatePinnedToCore(readerTask, "GNSS", kTaskStackBytes, nullptr, 1,
                          nullptr, 0);
}

GnssStatus status() { return snapshot(); }

}  // namespace position_source::gnss_receiver

#else  // No receiver on this board.

namespace position_source::gnss_receiver {

void begin() {}
void startTask() {}
GnssStatus status() { return GnssStatus{}; }

}  // namespace position_source::gnss_receiver

#endif
