#include "../../lib/waveshare_board/axp2101_register_policy.hpp"

#include <cassert>
#include <cstddef>

int main() {
  using namespace waveshare_board::axp2101::register_policy;

  static_assert(!isPowerRailControlRegister(0x7F));
  static_assert(isPowerRailControlRegister(0x80));
  static_assert(isPowerRailControlRegister(0x86));
  static_assert(!isPowerRailControlRegister(0x87));
  static_assert(!isPowerRailControlRegister(0x8F));
  static_assert(isPowerRailControlRegister(0x90));
  static_assert(isPowerRailControlRegister(0x9A));
  static_assert(!isPowerRailControlRegister(0x9B));

  static_assert(isWriteAllowed(INTERRUPT_ENABLE_1));
  static_assert(isWriteAllowed(INTERRUPT_STATUS_1));

  std::size_t allowedCount = 0;
  for (unsigned int address = 0; address <= 0xFF; ++address) {
    const bool expected = address == INTERRUPT_ENABLE_1 ||
                          address == INTERRUPT_STATUS_1;
    const bool allowed = isWriteAllowed(static_cast<uint8_t>(address));
    assert(allowed == expected);
    allowedCount += allowed ? 1 : 0;
  }

  // The exhaustive loop makes any future permission an intentional test
  // change instead of an accidental hole around the known rail registers.
  assert(allowedCount == 2);
  return 0;
}
