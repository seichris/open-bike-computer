#pragma once

#include <cstdint>

namespace waveshare_board::i2c {

// Optional per-call observation, never shared between tasks. Status is the
// Arduino Wire transmit result, or the received byte count for Receive.
enum class TransactionPhase : uint8_t { None, Lock, Transmit, Receive };

struct TransactionTrace {
  uint8_t attempts = 0;
  uint8_t failedAttempts = 0;
  TransactionPhase firstPhase = TransactionPhase::None;
  TransactionPhase lastPhase = TransactionPhase::None;
  uint8_t firstStatus = 0;
  uint8_t lastStatus = 0;
  uint32_t elapsedMs = 0;

  void failure(TransactionPhase phase, uint8_t status) {
    if (failedAttempts == 0) {
      firstPhase = phase;
      firstStatus = status;
    }
    ++failedAttempts;
    lastPhase = phase;
    lastStatus = status;
  }
};

} // namespace waveshare_board::i2c
