#pragma once

#include <array>
#include <cstdint>

namespace waveshare_board::i2c {

// Debug-only caller owns synchronization. Fixed storage; no heap or bus access.
// Recovered traffic must not suppress the first exhausted transaction.
class RetryLogLimiter {
public:
  static constexpr uint32_t intervalMs = 5000;

  bool admit(uint8_t address, bool recovered, uint32_t now,
             uint32_t &suppressed) {
    if (address >= entries.size()) return false;
    auto &entry = entries[address];
    const unsigned kind = recovered ? 0 : 1;
    const uint8_t bit = 1U << kind;
    if ((entry.emitted & bit) != 0 &&
        static_cast<uint32_t>(now - entry.last[kind]) < intervalMs) {
      if (entry.suppressed[kind] != UINT32_MAX) ++entry.suppressed[kind];
      return false;
    }
    suppressed = entry.suppressed[kind];
    entry.suppressed[kind] = 0;
    entry.last[kind] = now;
    entry.emitted |= bit;
    return true;
  }

private:
  struct Entry {
    uint32_t last[2] = {};
    uint32_t suppressed[2] = {};
    uint8_t emitted = 0;
  };
  std::array<Entry, 128> entries{};
};

} // namespace waveshare_board::i2c
