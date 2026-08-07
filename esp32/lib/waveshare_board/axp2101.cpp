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
constexpr uint8_t AXP2101_LDO_ENABLE_REG = 0x90;
constexpr uint8_t AXP2101_POWER_BUTTON_SHORT_PRESS_MASK = 0x08;
constexpr uint8_t AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK = 0x02;
constexpr uint8_t AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK = 0x01;
constexpr uint8_t AXP2101_POWER_BUTTON_EVENT_MASK =
    AXP2101_POWER_BUTTON_SHORT_PRESS_MASK |
    AXP2101_POWER_BUTTON_NEGATIVE_EDGE_MASK |
    AXP2101_POWER_BUTTON_POSITIVE_EDGE_MASK;
constexpr unsigned AXP2101_POWER_BUTTON_OFF_SECONDS = 4;

bool writeRegister(uint8_t reg, uint8_t value) {
  if (!register_policy::isWriteAllowed(reg)) {
    Serial.printf("AXP_WRITE_BLOCKED schema=1 reg=0x%02X value=0x%02X "
                  "policy=interrupt-only\n",
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

bool setPowerButtonOffLevel(PowerButtonOffLevel level) {
  if (!pmuAvailable) {
    return false;
  }

  i2c::Axp2101PowerButtonOffLevelResult result;
  const bool ok = i2c::ensureAxp2101PowerButtonOffLevel(
      static_cast<uint8_t>(level), result);
  if (ok) {
    Serial.printf("AXP2101: PWR button off level=%u before=0x%02X "
                  "after=0x%02X changed=%d\n",
                  static_cast<unsigned>(level), result.before, result.after,
                  result.changed ? 1 : 0);
  }
  return ok;
}

bool setPowerButtonEventMonitoring(bool enabled) {
  if (!pmuAvailable) {
    return false;
  }

  uint8_t interruptEnable = 0;
  if (!readRegister(register_policy::INTERRUPT_ENABLE_1, interruptEnable)) {
    return false;
  }

  const uint8_t updatedInterruptEnable =
      enabled ? interruptEnable | AXP2101_POWER_BUTTON_EVENT_MASK
              : interruptEnable & ~AXP2101_POWER_BUTTON_EVENT_MASK;
  if (updatedInterruptEnable != interruptEnable &&
      !writeRegister(register_policy::INTERRUPT_ENABLE_1,
                     updatedInterruptEnable)) {
    return false;
  }

  // AXP2101 interrupt status is write-one-to-clear. Remove any stale press so
  // enabling the feature cannot immediately trigger playback.
  return writeRegister(register_policy::INTERRUPT_STATUS_1,
                       AXP2101_POWER_BUTTON_EVENT_MASK);
}

bool readAndClearPowerButtonEvents(PowerButtonEvents &events) {
  events = {};
  if (!pmuAvailable) {
    return false;
  }

  uint8_t interruptStatus = 0;
  if (!readRegister(register_policy::INTERRUPT_STATUS_1, interruptStatus)) {
    return false;
  }
  const uint8_t pendingEvents =
      interruptStatus & AXP2101_POWER_BUTTON_EVENT_MASK;
  if (pendingEvents == 0) {
    return true;
  }
  if (!writeRegister(register_policy::INTERRUPT_STATUS_1, pendingEvents)) {
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
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
  Serial.println("Probing AXP2101 with 2.06 display-enable-only recovery...");
#else
  Serial.println("Probing AXP2101 without changing output rails...");
#endif
  if (!begin()) {
    Serial.println("AXP2101 not found");
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
    Serial.println("BOOT_PMIC schema=1 mode=display-enable-only available=0 "
                   "railState=unknown displayRecovery=0 "
                   "powerButtonOffConfigured=0 powerButtonConfigRead=0");
#else
    Serial.println("BOOT_PMIC schema=1 mode=read-only available=0 "
                   "railState=unknown powerButtonOffConfigured=0 "
                   "powerButtonConfigRead=0");
#endif
    return false;
  }

  // The AXP2101 default is six seconds. Configure the shorter four-second
  // hard-off gesture without changing any other PMU power-button fields, then
  // independently re-read REG27 so boot validation cannot pass on a partial or
  // unverifiable update.
  constexpr PowerButtonOffLevel requestedPowerButtonOffLevel =
      PowerButtonOffLevel::FourSeconds;
  const bool powerButtonOffWriteOk =
      setPowerButtonOffLevel(requestedPowerButtonOffLevel);
  uint8_t powerButtonConfig = 0;
  const bool powerButtonConfigReadOk = readRegister(
      register_policy::POWER_BUTTON_CONFIG_REGISTER, powerButtonConfig);
  const uint8_t observedPowerButtonOffLevel =
      powerButtonConfigReadOk
          ? register_policy::powerButtonOffLevel(powerButtonConfig)
          : UINT8_MAX;
  const bool powerButtonOffConfigured =
      powerButtonOffWriteOk && powerButtonConfigReadOk &&
      register_policy::hasPowerButtonOffLevel(
          powerButtonConfig,
          static_cast<uint8_t>(requestedPowerButtonOffLevel));
  if (!powerButtonOffConfigured) {
    Serial.printf(
        "BOOT_DIAGNOSTICS_ERROR schema=1 "
        "operation=power_button_off_level write=%d read=%d "
        "expectedLevel=%u actualLevel=%u config=0x%02X\n",
        powerButtonOffWriteOk ? 1 : 0, powerButtonConfigReadOk ? 1 : 0,
        static_cast<unsigned>(requestedPowerButtonOffLevel),
        static_cast<unsigned>(observedPowerButtonOffLevel), powerButtonConfig);
  }
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
  const char *bootPmicMode = powerButtonOffConfigured
                                 ? "display-enable-only"
                                 : "power-button-config-failed";
#else
  const char *bootPmicMode =
      powerButtonOffConfigured ? "read-only" : "power-button-config-failed";
#endif

  PowerStatus status;
  uint8_t ldoEnable = 0;
  bool ldoReadOk = readRegister(AXP2101_LDO_ENABLE_REG, ldoEnable);
  const bool statusReadOk = readPowerStatus(status);
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
  i2c::Axp2101DisplayEnableResult displayEnable;
  const bool displayRecoveryOk =
      i2c::ensureAxp2101DisplayEnabled(displayEnable);
  if (displayRecoveryOk) {
    ldoEnable = displayEnable.after;
    ldoReadOk = true;
  }
  Serial.printf("AXP2101: 2.06 display-enable-only recovery ok=%d changed=%d "
                "before=0x%02X after=0x%02X\n",
                displayRecoveryOk ? 1 : 0, displayEnable.changed ? 1 : 0,
                displayEnable.before, displayEnable.after);
#endif
  if (statusReadOk) {
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
    Serial.printf("AXP2101: preserving every non-display PMIC rail bit; "
                  "status1=0x%02X status2=0x%02X vbus=%s battery=%s "
                  "currentDir=%u charge=%u ldo=0x%02X ldoRead=%d\n",
                  status.status1, status.status2,
                  status.vbusGood ? "good" : "not-good",
                  status.batteryPresent ? "present" : "absent",
                  status.batteryCurrentDirection, status.chargingStatus,
                  ldoEnable, ldoReadOk ? 1 : 0);
    Serial.printf("BOOT_PMIC schema=1 mode=%s available=1 "
                  "railState=%s statusRead=1 status1=0x%02X status2=0x%02X "
                  "vbus=%d battery=%d currentDirection=%u charging=%u "
                  "ldoRead=%d ldo=0x%02X displayRecovery=%d "
                  "displayChanged=%d powerButtonOffConfigured=%d "
                  "powerButtonOffSeconds=%u powerButtonOffLevel=%u "
                  "powerButtonConfigRead=%d powerButtonConfig=0x%02X\n",
                  bootPmicMode,
                  displayRecoveryOk ? "display-enabled" : "unknown",
                  status.status1, status.status2, status.vbusGood ? 1 : 0,
                  status.batteryPresent ? 1 : 0,
                  status.batteryCurrentDirection, status.chargingStatus,
                  ldoReadOk ? 1 : 0, ldoEnable, displayRecoveryOk ? 1 : 0,
                  displayEnable.changed ? 1 : 0,
                  powerButtonOffConfigured ? 1 : 0,
                  AXP2101_POWER_BUTTON_OFF_SECONDS,
                  static_cast<unsigned>(observedPowerButtonOffLevel),
                  powerButtonConfigReadOk ? 1 : 0, powerButtonConfig);
#else
    Serial.printf("AXP2101: preserving current PMIC rail state; status1=0x%02X "
                  "status2=0x%02X vbus=%s battery=%s currentDir=%u "
                  "charge=%u ldo=0x%02X ldoRead=%d\n",
                  status.status1, status.status2,
                  status.vbusGood ? "good" : "not-good",
                  status.batteryPresent ? "present" : "absent",
                  status.batteryCurrentDirection, status.chargingStatus,
                  ldoEnable, ldoReadOk ? 1 : 0);
    Serial.printf("BOOT_PMIC schema=1 mode=%s available=1 "
                  "railState=current-preserved "
                  "statusRead=1 status1=0x%02X status2=0x%02X vbus=%d "
                  "battery=%d currentDirection=%u charging=%u ldoRead=%d "
                  "ldo=0x%02X powerButtonOffConfigured=%d "
                  "powerButtonOffSeconds=%u powerButtonOffLevel=%u "
                  "powerButtonConfigRead=%d powerButtonConfig=0x%02X\n",
                  bootPmicMode,
                  status.status1, status.status2, status.vbusGood ? 1 : 0,
                  status.batteryPresent ? 1 : 0,
                  status.batteryCurrentDirection, status.chargingStatus,
                  ldoReadOk ? 1 : 0, ldoEnable,
                  powerButtonOffConfigured ? 1 : 0,
                  AXP2101_POWER_BUTTON_OFF_SECONDS,
                  static_cast<unsigned>(observedPowerButtonOffLevel),
                  powerButtonConfigReadOk ? 1 : 0, powerButtonConfig);
#endif
  } else {
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
    Serial.printf("AXP2101: preserving every non-display PMIC rail bit; "
                  "status read failed ldo=0x%02X ldoRead=%d\n",
                  ldoEnable, ldoReadOk ? 1 : 0);
    Serial.printf("BOOT_PMIC schema=1 mode=%s available=1 "
                  "railState=%s statusRead=0 ldoRead=%d ldo=0x%02X "
                  "displayRecovery=%d displayChanged=%d "
                  "powerButtonOffConfigured=%d powerButtonOffSeconds=%u "
                  "powerButtonOffLevel=%u powerButtonConfigRead=%d "
                  "powerButtonConfig=0x%02X\n",
                  bootPmicMode,
                  displayRecoveryOk ? "display-enabled" : "unknown",
                  ldoReadOk ? 1 : 0, ldoEnable,
                  displayRecoveryOk ? 1 : 0,
                  displayEnable.changed ? 1 : 0,
                  powerButtonOffConfigured ? 1 : 0,
                  AXP2101_POWER_BUTTON_OFF_SECONDS,
                  static_cast<unsigned>(observedPowerButtonOffLevel),
                  powerButtonConfigReadOk ? 1 : 0, powerButtonConfig);
#else
    Serial.printf("AXP2101: preserving current PMIC rail state; status read failed "
                  "ldo=0x%02X ldoRead=%d\n",
                  ldoEnable, ldoReadOk ? 1 : 0);
    Serial.printf("BOOT_PMIC schema=1 mode=%s available=1 "
                  "railState=current-preserved "
                  "statusRead=0 ldoRead=%d ldo=0x%02X "
                  "powerButtonOffConfigured=%d powerButtonOffSeconds=%u "
                  "powerButtonOffLevel=%u powerButtonConfigRead=%d "
                  "powerButtonConfig=0x%02X\n",
                  bootPmicMode,
                  ldoReadOk ? 1 : 0, ldoEnable,
                  powerButtonOffConfigured ? 1 : 0,
                  AXP2101_POWER_BUTTON_OFF_SECONDS,
                  static_cast<unsigned>(observedPowerButtonOffLevel),
                  powerButtonConfigReadOk ? 1 : 0, powerButtonConfig);
#endif
  }
#if defined(WAVESHARE_AMOLED_206) && defined(WAVESHARE_206_FORCE_AXP_DISPLAY)
  return displayRecoveryOk && powerButtonOffConfigured;
#else
  return powerButtonOffConfigured;
#endif
}

} // namespace waveshare_board::axp2101

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
