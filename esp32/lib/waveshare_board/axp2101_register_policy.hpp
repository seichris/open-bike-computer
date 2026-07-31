#pragma once

#include <cstdint>

namespace waveshare_board::axp2101::register_policy {

// AXP2101 writes are fail-closed. The only validated writes are the two
// registers needed to monitor and acknowledge PWR-button interrupts. Charger,
// input-current, BATFET, DCDC, LDO, and every other register remain read-only
// until a board-specific electrical validation deliberately expands this
// allowlist.
constexpr uint8_t INTERRUPT_ENABLE_1 = 0x41;
constexpr uint8_t INTERRUPT_STATUS_1 = 0x49;

// These ranges remain named so tests and documentation can explicitly cover
// the output-rail blocks that prompted the policy. They are not the boundary
// of the protection: all non-allowlisted addresses are blocked.
constexpr uint8_t DCDC_CONTROL_FIRST = 0x80;
constexpr uint8_t DCDC_CONTROL_LAST = 0x86;
constexpr uint8_t LDO_CONTROL_FIRST = 0x90;
constexpr uint8_t LDO_CONTROL_LAST = 0x9A;

constexpr bool isPowerRailControlRegister(uint8_t reg) {
  return (reg >= DCDC_CONTROL_FIRST && reg <= DCDC_CONTROL_LAST) ||
         (reg >= LDO_CONTROL_FIRST && reg <= LDO_CONTROL_LAST);
}

constexpr bool isWriteAllowed(uint8_t reg) {
  return reg == INTERRUPT_ENABLE_1 || reg == INTERRUPT_STATUS_1;
}

} // namespace waveshare_board::axp2101::register_policy
