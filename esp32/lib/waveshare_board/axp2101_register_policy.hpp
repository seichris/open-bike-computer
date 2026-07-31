#pragma once

#include <cstdint>

namespace waveshare_board::axp2101::register_policy {

// The board schematics do not identify every populated load behind the
// AXP2101 outputs, and the vendor display/audio examples rely on the PMIC's
// factory/eFuse configuration. Treat every output-enable and output-voltage
// register as read-only until a board-specific rail map is electrically
// validated.
constexpr uint8_t DCDC_CONTROL_FIRST = 0x80;
constexpr uint8_t DCDC_CONTROL_LAST = 0x86;
constexpr uint8_t LDO_CONTROL_FIRST = 0x90;
constexpr uint8_t LDO_CONTROL_LAST = 0x9A;

constexpr bool isPowerRailControlRegister(uint8_t reg) {
  return (reg >= DCDC_CONTROL_FIRST && reg <= DCDC_CONTROL_LAST) ||
         (reg >= LDO_CONTROL_FIRST && reg <= LDO_CONTROL_LAST);
}

constexpr bool isWriteAllowed(uint8_t reg) {
  return !isPowerRailControlRegister(reg);
}

} // namespace waveshare_board::axp2101::register_policy
