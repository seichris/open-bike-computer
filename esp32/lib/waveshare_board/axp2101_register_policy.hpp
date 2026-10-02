#pragma once

#include <cstddef>
#include <cstdint>

namespace waveshare_board::axp2101::register_policy {

// Generic AXP2101 writes are fail-closed. The only validated generic writes
// are the two registers needed to monitor and acknowledge PWR-button
// interrupts. Charger, input-current, BATFET, DCDC, LDO, and every other
// register remain read-only through the shared helpers. The 2.06-inch target's
// dedicated one-way display recovery below is deliberately not part of this
// generic allowlist.
constexpr uint8_t DEVICE_ADDRESS = 0x34;
constexpr uint8_t INTERRUPT_ENABLE_1 = 0x41;
constexpr uint8_t INTERRUPT_STATUS_1 = 0x49;
constexpr uint8_t POWER_BUTTON_CONFIG_REGISTER = 0x27;
constexpr uint8_t POWER_BUTTON_OFF_LEVEL_MASK = 0x0C;
constexpr uint8_t POWER_BUTTON_OFF_LEVEL_SHIFT = 2;
constexpr uint8_t POWER_BUTTON_OFF_LEVEL_COUNT = 4;
// The 2.06-inch target historically disabled this display bit before sleep and
// relies on boot-time recovery after OTA rollback. The generic write helpers
// still reject this register; only the dedicated one-way read/modify/write
// operation in i2c_bus.cpp may set this bit while preserving every other bit.
constexpr uint8_t DISPLAY_ENABLE_REGISTER_206 = 0x90;
constexpr uint8_t DISPLAY_ENABLE_MASK_206 = 0x80;

// Waveshare's e-paper schematic connects AXP2101 ALDO3 to EPD_VCC_AXP, and
// its reference firmware programs that rail to 3.3 V before enabling it.
constexpr uint8_t EPAPER_ALDO3_ENABLE_REGISTER = 0x90;
constexpr uint8_t EPAPER_ALDO3_ENABLE_MASK = 0x04;
constexpr uint8_t EPAPER_ALDO3_VOLTAGE_REGISTER = 0x94;
constexpr uint8_t EPAPER_ALDO3_VOLTAGE_MASK = 0x1F;
constexpr uint8_t EPAPER_ALDO3_3300MV_VALUE = 0x1C;

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

constexpr uint8_t withDisplayEnabled206(uint8_t current) {
  return current | DISPLAY_ENABLE_MASK_206;
}

constexpr bool isDisplayEnableOnlyTransition206(uint8_t current,
                                                uint8_t updated) {
  return updated == withDisplayEnabled206(current) &&
         ((current ^ updated) & ~DISPLAY_ENABLE_MASK_206) == 0;
}

constexpr uint8_t withEpaperAldo3Enabled(uint8_t current) {
  return current | EPAPER_ALDO3_ENABLE_MASK;
}

constexpr uint8_t withEpaperAldo3At3300mV(uint8_t current) {
  return (current & ~EPAPER_ALDO3_VOLTAGE_MASK) |
         EPAPER_ALDO3_3300MV_VALUE;
}

constexpr bool isEpaperAldo3EnableOnlyTransition(uint8_t current,
                                                 uint8_t updated) {
  return updated == withEpaperAldo3Enabled(current) &&
         ((current ^ updated) & ~EPAPER_ALDO3_ENABLE_MASK) == 0;
}

constexpr bool isEpaperAldo3VoltageOnlyTransition(uint8_t current,
                                                  uint8_t updated) {
  return updated == withEpaperAldo3At3300mV(current) &&
         ((current ^ updated) & ~EPAPER_ALDO3_VOLTAGE_MASK) == 0;
}

constexpr uint8_t powerButtonOffLevel(uint8_t registerValue) {
  return (registerValue & POWER_BUTTON_OFF_LEVEL_MASK) >>
         POWER_BUTTON_OFF_LEVEL_SHIFT;
}

constexpr bool hasPowerButtonOffLevel(uint8_t registerValue, uint8_t level) {
  return level < POWER_BUTTON_OFF_LEVEL_COUNT &&
         powerButtonOffLevel(registerValue) == level;
}

constexpr bool isPowerButtonOffLevelTransition(uint8_t current,
                                                uint8_t updated) {
  return ((current ^ updated) & ~POWER_BUTTON_OFF_LEVEL_MASK) == 0;
}

// Enforce the device policy at the shared I2C boundary, not only inside the
// AXP2101 wrapper. Other devices remain unrestricted. AXP2101 writes must use
// one 8-bit register address and one payload byte so block/16-bit helpers cannot
// step into adjacent, non-allowlisted registers.
constexpr bool isTransactionWriteAllowed(uint8_t deviceAddress,
                                         uint16_t reg,
                                         std::size_t registerAddressBytes,
                                         std::size_t payloadBytes) {
  if (deviceAddress != DEVICE_ADDRESS) {
    return true;
  }
  return registerAddressBytes == 1 && payloadBytes == 1 && reg <= 0xFF &&
         isWriteAllowed(static_cast<uint8_t>(reg));
}

} // namespace waveshare_board::axp2101::register_policy
