/**
 * @file axp2101.cpp
 * @brief AXP2101 PMU helpers for the Waveshare ESP32-S3 Touch AMOLED 1.75.
 */

#include "axp2101.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "i2c_bus.hpp"
#include "axp2101_register_policy.hpp"
#include "waveshare_board.hpp"

namespace waveshare_board::axp2101 {

namespace {

bool pmuAvailable = false;

constexpr uint8_t AXP2101_STATUS1_REG = 0x00;
constexpr uint8_t AXP2101_STATUS2_REG = 0x01;
constexpr uint8_t AXP2101_BATTERY_PERCENTAGE_REG = 0xA4;
constexpr uint8_t AXP2101_VBUS_GOOD_MASK = 0x20;
constexpr uint8_t AXP2101_BATTERY_PRESENT_MASK = 0x08;
constexpr uint8_t AXP2101_BATTERY_CURRENT_DIRECTION_SHIFT = 5;
constexpr uint8_t AXP2101_BATTERY_CURRENT_DIRECTION_MASK = 0x03;
constexpr uint8_t AXP2101_SYSTEM_ON_MASK = 0x10;
constexpr uint8_t AXP2101_VINDPM_ACTIVE_MASK = 0x08;
constexpr uint8_t AXP2101_CHARGING_STATUS_MASK = 0x07;
constexpr uint8_t AXP2101_INTERRUPT_ENABLE_1_REG = 0x41;
constexpr uint8_t AXP2101_INTERRUPT_STATUS_1_REG = 0x49;
constexpr uint8_t AXP2101_LDO_ENABLE_REG = 0x90;
constexpr uint8_t AXP2101_POWER_BUTTON_SHORT_PRESS_MASK = 0x08;
constexpr uint8_t AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK = 0x02;
constexpr uint8_t AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK = 0x01;
constexpr uint8_t AXP2101_POWER_BUTTON_EVENT_MASK =
    AXP2101_POWER_BUTTON_SHORT_PRESS_MASK |
    AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK |
    AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK;

bool writeRegister(uint8_t reg, uint8_t value) {
  if (!register_policy::isWriteAllowed(reg)) {
    Serial.printf("AXP2101: blocked unvalidated power-rail write "
                  "reg=0x%02X value=0x%02X\n",
                  reg, value);
    return false;
  }
  return i2c::writeRegister8(AXP2101_ADDR, reg, value, "AXP2101");
}

} // namespace

bool begin() {
  pmuAvailable = i2c::probe(AXP2101_ADDR, "AXP2101");
  return pmuAvailable;
}

bool isAvailable() { return pmuAvailable; }

bool readRegister(uint8_t reg, uint8_t &value) {
  return i2c::readRegister8(AXP2101_ADDR, reg, value, "AXP2101");
}

bool readPowerStatus(PowerStatus &status) {
  if (!readRegister(AXP2101_STATUS1_REG, status.status1) ||
      !readRegister(AXP2101_STATUS2_REG, status.status2)) {
    return false;
  }

  status.vbusGood = (status.status1 & AXP2101_VBUS_GOOD_MASK) != 0;
  status.batteryPresent =
      (status.status1 & AXP2101_BATTERY_PRESENT_MASK) != 0;
  status.batteryCurrentDirection =
      (status.status2 >> AXP2101_BATTERY_CURRENT_DIRECTION_SHIFT) &
      AXP2101_BATTERY_CURRENT_DIRECTION_MASK;
  status.systemOn = (status.status2 & AXP2101_SYSTEM_ON_MASK) != 0;
  status.vindpmActive = (status.status2 & AXP2101_VINDPM_ACTIVE_MASK) != 0;
  status.chargingStatus = status.status2 & AXP2101_CHARGING_STATUS_MASK;
  return true;
}

bool readBatteryStatus(uint8_t &percentage, bool &charging) {
  charging = false;
  if (!pmuAvailable && !begin()) {
    return false;
  }

  PowerStatus status;
  if (!readPowerStatus(status) || !status.batteryPresent) {
    return false;
  }

  uint8_t rawPercentage = 0;
  if (!readRegister(AXP2101_BATTERY_PERCENTAGE_REG, rawPercentage) ||
      rawPercentage > 100) {
    return false;
  }

  percentage = rawPercentage;
  // REG 01H[2:0] values 0-3 are trickle, pre-charge, constant-current,
  // and constant-voltage charging. Require valid VBUS as well so a stale
  // charge phase cannot leave the UI showing external power.
  charging = status.vbusGood && status.chargingStatus <= 3;
  return true;
}

bool readBatteryPercentage(uint8_t &percentage) {
  bool charging = false;
  return readBatteryStatus(percentage, charging);
}

bool setPowerButtonEventMonitoring(bool enabled) {
  if (!pmuAvailable) {
    return false;
  }

  uint8_t interruptEnable = 0;
  if (!readRegister(AXP2101_INTERRUPT_ENABLE_1_REG, interruptEnable)) {
    return false;
  }

  const uint8_t updatedInterruptEnable =
      enabled ? interruptEnable | AXP2101_POWER_BUTTON_EVENT_MASK
              : interruptEnable & ~AXP2101_POWER_BUTTON_EVENT_MASK;
  if (updatedInterruptEnable != interruptEnable &&
      !writeRegister(AXP2101_INTERRUPT_ENABLE_1_REG,
                     updatedInterruptEnable)) {
    return false;
  }

  // AXP2101 interrupt status is write-one-to-clear. Remove any stale press so
  // enabling the feature cannot immediately trigger playback.
  return writeRegister(AXP2101_INTERRUPT_STATUS_1_REG,
                       AXP2101_POWER_BUTTON_EVENT_MASK);
}

bool readAndClearPowerButtonEvents(PowerButtonEvents &events) {
  events = {};
  if (!pmuAvailable) {
    return false;
  }

  uint8_t interruptStatus = 0;
  if (!readRegister(AXP2101_INTERRUPT_STATUS_1_REG, interruptStatus)) {
    return false;
  }
  const uint8_t pendingEvents =
      interruptStatus & AXP2101_POWER_BUTTON_EVENT_MASK;
  if (pendingEvents == 0) {
    return true;
  }
  if (!writeRegister(AXP2101_INTERRUPT_STATUS_1_REG, pendingEvents)) {
    return false;
  }

  events.shortPress =
      (pendingEvents & AXP2101_POWER_BUTTON_SHORT_PRESS_MASK) != 0;
  events.negativeEdge =
      (pendingEvents & AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK) != 0;
  events.positiveEdge =
      (pendingEvents & AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK) != 0;
  return true;
}

bool initializePowerState() {
  Serial.println("Probing AXP2101 without changing power rails...");
  if (!begin()) {
    Serial.println("AXP2101 not found");
    return false;
  }

  PowerStatus status;
  uint8_t ldoEnable = 0;
  const bool ldoReadOk = readRegister(AXP2101_LDO_ENABLE_REG, ldoEnable);
  if (readPowerStatus(status)) {
    Serial.printf("AXP2101: preserving factory rails; status1=0x%02X "
                  "status2=0x%02X vbus=%s battery=%s currentDir=%u "
                  "charge=%u ldo=0x%02X ldoRead=%d\n",
                  status.status1, status.status2,
                  status.vbusGood ? "good" : "not-good",
                  status.batteryPresent ? "present" : "absent",
                  status.batteryCurrentDirection, status.chargingStatus,
                  ldoEnable, ldoReadOk ? 1 : 0);
  } else {
    Serial.printf("AXP2101: preserving factory rails; status read failed "
                  "ldo=0x%02X ldoRead=%d\n",
                  ldoEnable, ldoReadOk ? 1 : 0);
  }
  return true;
}

} // namespace waveshare_board::axp2101

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
