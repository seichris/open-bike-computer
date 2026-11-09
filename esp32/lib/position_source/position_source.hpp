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
  // I2C only: the longest wait before the receiver acknowledged the read of
  // a length answer and of a data answer, in milliseconds (it refuses reads
  // until the answer is ready), and the refusals (NACKs) per step: the
  // dummy write that checks the slave, request writes, length reads, data
  // reads.
  uint16_t lengthWaitMs = 0;
  uint16_t dataWaitMs = 0;
  uint32_t dummyNacks = 0;
  uint32_t requestNacks = 0;
  uint32_t lengthNacks = 0;
  uint32_t dataNacks = 0;
  // I2C only: requests sent again because the receiver kept refusing the
  // answer read (an answer belongs to its request).
  uint32_t requestRepeats = 0;
  // Every byte read from the port, so a silent line (no bytes) and a wrong
  // rate (bytes without checksum-valid sentences) can be told apart.
  uint32_t bytes = 0;
  uint32_t validSentences = 0;
  uint32_t invalidSentences = 0;
  // RESET pulses issued: the fresh start and every restart after the stream
  // stopped (on a UART, after probe rounds that saw no bytes).
  uint32_t resetPulses = 0;
  uint32_t fixes = 0;
  bool fixValid = false;
  uint8_t satellites = 0;
  uint32_t lastSentenceMs = 0;
  uint32_t lastFixMs = 0;
};

// Opens the receiver where one is fitted (the UART, or the I2C slave after a
// RESET pulse that starts the module fresh); a no-op elsewhere. Runs where
// the user interface starts, after the I2C bus and expander are configured.
void begin();
// Starts the receiver reader task where one is fitted; a no-op elsewhere.
void startTask();

// Whether a phone position may populate the shared record right now.
bool acceptsPhonePosition(uint32_t nowMs);
void notePhonePosition(uint32_t nowMs);
// Receiver side: the reader parsed a fix (valid or not).
void noteGnssFix(uint32_t nowMs, bool fixValid);
// Main loop only: applies the receiver's latest valid fix to the shared
// position record, which the reader task never writes, and returns whether
// one was applied; the loop treats it as navigation input like a phone
// position. Without a valid fix nothing is applied and the phone keeps the
// record. A no-op without a receiver.
bool applyPendingGnssFix();

Source activeSource(uint32_t nowMs);
GnssStatus gnssStatus();
bool gnssFitted();

// CAP2 position-source record: bit 0 phone, bit 1 GNSS; the module code is
// board::GnssModule.
uint8_t sourceFlags();
uint8_t moduleCode();
const char *moduleName();
// "none", "uart" or "i2c": how the ESP32 reaches the receiver.
const char *transportName();
// "none", "phone" or "gnss": which input populates the record now.
const char *activeSourceName(uint32_t nowMs);

}  // namespace position_source
