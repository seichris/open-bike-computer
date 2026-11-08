#pragma once

#include <cstdint>

#include "position_source_policy.hpp"

// The position-source part: the phone's positions arrive over BLE on every
// board; a board whose data declares a fitted GNSS receiver also reads that
// receiver. Both populate the one shared position record (gps.gpsData) that
// navigation, the map and ride automation consume; this part decides which
// may do so now. Implementation files: position_source.cpp (arbitration and
// the phone side) and gnss_receiver.cpp (the receiver, compiled only where
// BOARD_GNSS_FITTED is set by the board file).
namespace position_source {

struct GnssStatus {
  bool fitted = false;
  // UART: the port opened. I2C: the receiver answered its latest poll.
  bool portOpen = false;
  // Checksum-valid sentences arrived (on a UART, at the rate now in use).
  bool probeLocked = false;
  // UART only: the rate in use.
  uint32_t baud = 0;
  // I2C only: polls of the receiver, the ones it did not answer, and the
  // largest buffered length it reported (how far the reader lags).
  uint32_t polls = 0;
  uint32_t pollErrors = 0;
  uint32_t backlog = 0;
  // I2C only: the longest wait before the receiver acknowledged an answer
  // read, in milliseconds (it refuses the read until the answer is ready).
  uint16_t answerWaitMs = 0;
  // Every byte read from the port, so a silent line (no bytes) and a wrong
  // rate (bytes without checksum-valid sentences) can be told apart.
  uint32_t bytes = 0;
  uint32_t validSentences = 0;
  uint32_t invalidSentences = 0;
  // RESET pulses issued after probe rounds that saw no bytes.
  uint8_t resetPulses = 0;
  uint32_t fixes = 0;
  bool fixValid = false;
  uint8_t satellites = 0;
  uint32_t lastSentenceMs = 0;
  uint32_t lastFixMs = 0;
};

// Opens the receiver where one is fitted (the UART, or a presence check of
// the I2C slave); a no-op elsewhere. Runs where the user interface starts,
// after the I2C bus and expander are configured.
void begin();
// Starts the receiver reader task where one is fitted; a no-op elsewhere.
void startTask();

// Whether a phone position may populate the shared record right now.
bool acceptsPhonePosition(uint32_t nowMs);
void notePhonePosition(uint32_t nowMs);
// Receiver side: a parsed fix was applied to the record (valid or not).
void noteGnssFix(uint32_t nowMs, bool fixValid);
// One-shot flag raised by a valid receiver fix and consumed by the UI task,
// which treats the device's own fix as navigation input like a phone position.
bool takeFreshGnssFix();

Source activeSource(uint32_t nowMs);
GnssStatus gnssStatus();
bool gnssFitted();

// CAP2 position-source record: bit 0 phone, bit 1 GNSS; the module code is
// board::GnssModule.
uint8_t sourceFlags();
uint8_t moduleCode();
const char *moduleName();

}  // namespace position_source
