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
  static_assert(!isWriteAllowed(POWER_BUTTON_CONFIG_REGISTER));

  std::size_t allowedCount = 0;
  for (unsigned int address = 0; address <= 0xFF; ++address) {
    const bool expected = address == INTERRUPT_ENABLE_1 ||
                          address == INTERRUPT_STATUS_1;
    const bool allowed = isWriteAllowed(static_cast<uint8_t>(address));
    assert(allowed == expected);
    assert(isTransactionWriteAllowed(DEVICE_ADDRESS, address, 1, 1) ==
           expected);
    allowedCount += allowed ? 1 : 0;
  }

  // The exhaustive loop makes any future permission an intentional test
  // change instead of an accidental hole around the known rail registers.
  assert(allowedCount == 2);

  // REG27 remains blocked through generic writes. The dedicated boot-time
  // helper may change only the OFFLEVEL bits (3:2), preserving every other
  // power-button field.
  assert(!isTransactionWriteAllowed(DEVICE_ADDRESS,
                                    POWER_BUTTON_CONFIG_REGISTER, 1, 1));
  for (unsigned int currentValue = 0; currentValue <= 0xFF; ++currentValue) {
    for (unsigned int level = 0; level < POWER_BUTTON_OFF_LEVEL_COUNT;
         ++level) {
      const uint8_t current = static_cast<uint8_t>(currentValue);
      const uint8_t updated =
          (current & ~POWER_BUTTON_OFF_LEVEL_MASK) |
          ((static_cast<uint8_t>(level) << POWER_BUTTON_OFF_LEVEL_SHIFT) &
           POWER_BUTTON_OFF_LEVEL_MASK);
      assert(isPowerButtonOffLevelTransition(current, updated));
      assert((updated & ~POWER_BUTTON_OFF_LEVEL_MASK) ==
             (current & ~POWER_BUTTON_OFF_LEVEL_MASK));
      assert((updated & POWER_BUTTON_OFF_LEVEL_MASK) ==
             ((level << POWER_BUTTON_OFF_LEVEL_SHIFT) &
              POWER_BUTTON_OFF_LEVEL_MASK));
      assert(powerButtonOffLevel(updated) == level);
      assert(hasPowerButtonOffLevel(updated, level));
      assert(!hasPowerButtonOffLevel(updated, POWER_BUTTON_OFF_LEVEL_COUNT));

      // The transition guard must reject collateral changes to any neighboring
      // PWR-button setting, even when the requested OFFLEVEL bits are correct.
      assert(!isPowerButtonOffLevelTransition(current,
                                              updated ^ uint8_t{0x01}));
    }
  }

  // The shared-bus block and 16-bit helpers must not provide alternate paths
  // into the AXP2101, even when the starting register itself is allowlisted.
  assert(!isTransactionWriteAllowed(DEVICE_ADDRESS, INTERRUPT_ENABLE_1, 1, 2));
  assert(!isTransactionWriteAllowed(DEVICE_ADDRESS, INTERRUPT_STATUS_1, 2, 1));
  assert(!isTransactionWriteAllowed(DEVICE_ADDRESS,
                                    DISPLAY_ENABLE_REGISTER_206, 1, 1));

  // The 2.06-inch compatibility operation is intentionally narrower than a
  // generic permission for register 0x90. Exhaust every possible starting
  // value to prove that it can only set bit 0x80 and preserves all seven other
  // bits exactly.
  for (unsigned int value = 0; value <= 0xFF; ++value) {
    const uint8_t current = static_cast<uint8_t>(value);
    const uint8_t updated = withDisplayEnabled206(current);
    assert((updated & DISPLAY_ENABLE_MASK_206) != 0);
    assert((updated & ~DISPLAY_ENABLE_MASK_206) ==
           (current & ~DISPLAY_ENABLE_MASK_206));
    assert(isDisplayEnableOnlyTransition206(current, updated));

    const uint8_t malicious = updated ^ 0x01;
    assert(!isDisplayEnableOnlyTransition206(current, malicious));
  }

  // This device policy must not interfere with normal writes to other I2C
  // peripherals on the shared bus.
  assert(isTransactionWriteAllowed(0x20, 0x03, 1, 2));
  assert(isTransactionWriteAllowed(0x51, 0x0000, 2, 1));
  return 0;
}
