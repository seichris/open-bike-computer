/**
 * @file axp2101.cpp
 * @brief AXP2101 PMU helpers for the Waveshare ESP32-S3 Touch AMOLED 1.75.
 */

#include "axp2101.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "i2c_bus.hpp"
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
constexpr uint8_t AXP2101_POWER_BUTTON_SHORT_PRESS_MASK = 0x08;
constexpr uint8_t AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK = 0x02;
constexpr uint8_t AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK = 0x01;
constexpr uint8_t AXP2101_POWER_BUTTON_EVENT_MASK =
    AXP2101_POWER_BUTTON_SHORT_PRESS_MASK |
    AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK |
    AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK;

constexpr uint8_t peripheralRailRegs[] = {
    AXP2101_ALDO1_VOLTAGE_REG, AXP2101_ALDO2_VOLTAGE_REG,
    AXP2101_ALDO3_VOLTAGE_REG, AXP2101_ALDO4_VOLTAGE_REG,
    AXP2101_BLDO1_VOLTAGE_REG, AXP2101_BLDO2_VOLTAGE_REG};

bool writeRegisterChecked(const char *label, uint8_t reg, uint8_t value,
                          uint8_t readbackMask = 0xFF) {
  uint8_t readback = 0;
  for (uint8_t attempt = 0; attempt < 2; attempt++) {
    if (!writeRegister(reg, value)) {
      Serial.printf("AXP2101: %s write failed reg=0x%02X value=0x%02X\n",
                    label, reg, value);
      return false;
    }

    delay(5);
    if (!readRegister(reg, readback)) {
      Serial.printf("AXP2101: %s readback failed reg=0x%02X expected=0x%02X\n",
                    label, reg, value);
      continue;
    }

    bool ok = (readback & readbackMask) == (value & readbackMask);
    Serial.printf("AXP2101: %s reg=0x%02X value=0x%02X read=0x%02X mask=0x%02X %s\n",
                  label, reg, value, readback, readbackMask,
                  ok ? "ok" : "mismatch");
    if (ok) {
      return true;
    }
  }

  return false;
}

uint8_t currentLdoEnableValue(uint8_t fallback) {
  uint8_t value = fallback;
  readRegister(AXP2101_LDO_ENABLE_REG, value);
  return value;
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

bool writeRegister(uint8_t reg, uint8_t value) {
  return i2c::writeRegister8(AXP2101_ADDR, reg, value, "AXP2101");
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

bool setDisplayPower(bool enabled) {
  uint8_t value = currentLdoEnableValue(AXP2101_KNOWN_GOOD_LDO_ENABLES);
  Serial.printf("AXP2101: display power request enabled=%d currentLdo=0x%02X "
                "mask=0x%02X\n",
                enabled ? 1 : 0, value, AXP2101_DISPLAY_ENABLE_MASK);
  if (enabled) {
    value |= AXP2101_DISPLAY_ENABLE_MASK;
  } else {
    value &= ~AXP2101_DISPLAY_ENABLE_MASK;
  }
  return writeRegisterChecked(enabled ? "display on" : "display off",
                              AXP2101_LDO_ENABLE_REG, value);
}

bool enableDisplayRails() { return setDisplayPower(true); }

bool setPeripheralPower(bool enabled) {
  uint8_t value = currentLdoEnableValue(
      enabled ? AXP2101_KNOWN_GOOD_LDO_ENABLES
              : AXP2101_MANAGED_LDO_ENABLE_MASK);
  if (enabled) {
    value |= AXP2101_MANAGED_LDO_ENABLE_MASK;
  } else {
    value &= ~AXP2101_MANAGED_LDO_ENABLE_MASK;
  }
  return writeRegisterChecked(enabled ? "peripheral on" : "peripheral off",
                              AXP2101_LDO_ENABLE_REG, value);
}

bool enablePeripheralRails() {
  bool voltageOk = true;
  for (uint8_t reg : peripheralRailRegs) {
    voltageOk = writeRegisterChecked("peripheral 3v3", reg,
                                     AXP2101_LDO_VOLTAGE_3V3,
                                     AXP2101_LDO_VOLTAGE_MASK) &&
                voltageOk;
  }

  if (!voltageOk) {
    Serial.println("AXP2101: peripheral voltage readback warning");
  }

  return writeRegisterChecked("peripheral on", AXP2101_LDO_ENABLE_REG,
                              AXP2101_KNOWN_GOOD_LDO_ENABLES);
}

bool restoreDefaultRails() {
  Serial.println("Enabling display power via AXP2101...");
  if (!begin()) {
    Serial.println("AXP2101 not found - display may not work!");
    return false;
  }

  Serial.println("AXP2101 found!");

#ifdef WAVESHARE_AMOLED_206
  // Waveshare's 2.06 Arduino display examples do not program AXP2101 rails
  // before gfx->begin(). Preserve the PMU state during bring-up instead of
  // reusing the 1.75 board's known-good LDO mask and voltage sequence.
  PowerStatus status;
  if (readPowerStatus(status)) {
    uint8_t ldoEnable = 0;
    bool ldoReadOk = readRegister(AXP2101_LDO_ENABLE_REG, ldoEnable);
    Serial.printf("AXP2101: 2.06 safe mode preserving rails; status1=0x%02X "
                  "status2=0x%02X vbus=%s battery=%s currentDir=%u "
                  "charge=%u ldo=0x%02X ldoRead=%d\n",
                  status.status1, status.status2,
                  status.vbusGood ? "good" : "not-good",
                  status.batteryPresent ? "present" : "absent",
                  status.batteryCurrentDirection, status.chargingStatus,
                  ldoEnable, ldoReadOk ? 1 : 0);
  } else {
    Serial.println("AXP2101: 2.06 safe mode status read failed");
  }

#ifdef WAVESHARE_206_FORCE_AXP_DISPLAY
  Serial.println("AXP2101: 2.06 forcing display rail by explicit build flag");
  return enableDisplayRails();
#else
  return true;
#endif
#else
  bool ok = writeRegisterChecked("ldo baseline reset", AXP2101_LDO_ENABLE_REG,
                                 AXP2101_KNOWN_GOOD_LDO_RESET);
  ok = writeRegisterChecked("ldo baseline on", AXP2101_LDO_ENABLE_REG,
                            AXP2101_KNOWN_GOOD_LDO_ENABLES) &&
       ok;

  PowerStatus status;
  if (readPowerStatus(status)) {
    Serial.printf("AXP2101: status1=0x%02X status2=0x%02X vbus=%s battery=%s "
                  "currentDir=%u charge=%u\n",
                  status.status1, status.status2,
                  status.vbusGood ? "good" : "not-good",
                  status.batteryPresent ? "present" : "absent",
                  status.batteryCurrentDirection, status.chargingStatus);
  } else {
    Serial.println("AXP2101: status read failed");
  }

  Serial.println("Configuring Peripheral Power...");
  ok = enablePeripheralRails() && ok;

  delay(500);
  if (ok) {
    Serial.println("AXP2101 display power enabled");
  } else {
    Serial.println("! AXP2101 rail setup completed with readback errors");
  }
  return ok;
#endif
}

} // namespace waveshare_board::axp2101

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
