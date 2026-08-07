/**
 * @file i2c_bus.cpp
 * @brief Shared I2C helpers for the Waveshare ESP32-S3 Touch AMOLED 1.75.
 */

#include "i2c_bus.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "axp2101_register_policy.hpp"
#include "waveshare_board.hpp"
#include "../power_management/power_management.hpp"
#include <Wire.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <hal.hpp>

namespace waveshare_board::i2c {

namespace {

namespace axp_policy = waveshare_board::axp2101::register_policy;

static_assert(axp_policy::DEVICE_ADDRESS == AXP2101_ADDR,
              "AXP2101 address must match the write policy");

Stats i2cStats;
bool busConfigured = false;
uint32_t activeClockHz = DEFAULT_CLOCK_HZ;
uint32_t lastFailureLogMs = 0;
SemaphoreHandle_t busMutex = nullptr;

bool writeAllowed(uint8_t address, uint16_t reg,
                  std::size_t registerAddressBytes,
                  std::size_t payloadBytes, const char *shape) {
  if (axp_policy::isTransactionWriteAllowed(
          address, reg, registerAddressBytes, payloadBytes)) {
    return true;
  }

  Serial.printf("AXP_WRITE_BLOCKED schema=1 reg=0x%04X shape=%s "
                "registerBytes=%u payloadBytes=%u policy=interrupt-only\n",
                static_cast<unsigned>(reg), shape,
                static_cast<unsigned>(registerAddressBytes),
                static_cast<unsigned>(payloadBytes));
  return false;
}

void ensureMutex() {
  if (busMutex == nullptr) {
    busMutex = xSemaphoreCreateMutex();
  }
}

class BusLock {
public:
  BusLock() {
    ensureMutex();
    locked = busMutex != nullptr &&
             xSemaphoreTake(busMutex, pdMS_TO_TICKS(DEFAULT_TIMEOUT_MS)) ==
                 pdTRUE;
  }

  ~BusLock() {
    if (locked) {
      xSemaphoreGive(busMutex);
    }
  }

  bool ok() const { return locked; }

private:
  bool locked = false;
};

void logFailure(const char *label, const char *operation, uint8_t address) {
  uint32_t now = millis();
  if (now - lastFailureLogMs < 5000) {
    return;
  }

  Serial.printf("Waveshare I2C: %s failed addr=0x%02X label=%s failures=%u "
                "recoveries=%u recovered=%u missing=%u\n",
                operation, address, label ? label : "-",
                i2cStats.failedTransactions, i2cStats.recoveryAttempts,
                i2cStats.recoveredTransactions, i2cStats.missingDevices);
  lastFailureLogMs = now;
}

#ifdef WAVESHARE_AMOLED_206
void recoverAfterFailure() {
  i2cStats.recoveryAttempts++;
  if (busConfigured) {
    Wire.end();
  }
  waveshare_board::recoverI2CBus();
  if (busConfigured) {
    Wire.setPins(I2C_SDA_PIN, I2C_SCL_PIN);
    Wire.begin();
    Wire.setClock(activeClockHz);
    Wire.setTimeOut(DEFAULT_TIMEOUT_MS);
  }
}
#endif

template <typename Fn>
bool withRetries(uint8_t address, const char *label, const char *operation,
                 uint8_t attempts, Fn &&fn) {
  if (attempts == 0) {
    attempts = 1;
  }

  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  BusLock lock;
  if (!lock.ok()) {
    i2cStats.failedTransactions++;
    logFailure(label, operation, address);
    return false;
  }

  for (uint8_t attempt = 0; attempt < attempts; attempt++) {
    if (fn()) {
      if (attempt > 0) {
        i2cStats.recoveredTransactions++;
      }
      return true;
    }

    i2cStats.failedTransactions++;
#ifdef WAVESHARE_AMOLED_206
    recoverAfterFailure();
#endif
    if (attempt + 1 < attempts) {
      delay(2);
    }
  }

  logFailure(label, operation, address);
  return false;
}

} // namespace

void configureBus(uint32_t clockHz) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  ensureMutex();
  activeClockHz = clockHz;
#ifdef WAVESHARE_AMOLED_175
  busConfigured = Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  if (busConfigured) {
    Wire.setClock(activeClockHz);
    Wire.setTimeOut(DEFAULT_TIMEOUT_MS);
  }
  Serial.printf("Waveshare I2C: %s SDA=%u SCL=%u clock=%lu Hz timeout=%u ms\n",
                busConfigured ? "configured" : "configuration failed",
                I2C_SDA_PIN, I2C_SCL_PIN,
                static_cast<unsigned long>(activeClockHz), DEFAULT_TIMEOUT_MS);
#else
  Wire.setPins(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.begin();
  Wire.setClock(activeClockHz);
  Wire.setTimeOut(DEFAULT_TIMEOUT_MS);
  busConfigured = true;
  Serial.printf("Waveshare I2C: configured SDA=%u SCL=%u clock=%lu Hz timeout=%u ms\n",
                I2C_SDA_PIN, I2C_SCL_PIN,
                static_cast<unsigned long>(activeClockHz), DEFAULT_TIMEOUT_MS);
#endif
}

const Stats &stats() { return i2cStats; }

void debugScan(Stream &out, uint8_t firstAddress, uint8_t lastAddress) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  BusLock lock;
  if (!lock.ok()) {
    out.println("Waveshare I2C scan: bus busy");
    return;
  }

  out.println("Waveshare I2C scan:");
  for (uint16_t address = firstAddress; address <= lastAddress; address++) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) {
      out.printf("  found 0x%02X\n", address);
    }
  }
}

bool probe(uint8_t address, const char *label, uint8_t attempts) {
#ifdef WAVESHARE_AMOLED_175
  if (attempts == 0) {
    attempts = 1;
  }

  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  BusLock lock;
  if (!lock.ok()) {
    i2cStats.failedTransactions++;
    logFailure(label, "probe", address);
    i2cStats.missingDevices++;
    return false;
  }

  for (uint8_t attempt = 0; attempt < attempts; ++attempt) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) {
      return true;
    }
    i2cStats.failedTransactions++;
    if (attempt + 1 < attempts) {
      delay(2);
    }
  }

  logFailure(label, "probe", address);
  i2cStats.missingDevices++;
  return false;
#else
  bool ok = withRetries(address, label, "probe", attempts, [address]() {
    Wire.beginTransmission(address);
    return Wire.endTransmission() == 0;
  });
  if (!ok) {
    i2cStats.missingDevices++;
  }
  return ok;
#endif
}

bool writeRegister8(uint8_t address, uint8_t reg, uint8_t value,
                    const char *label, uint8_t attempts) {
  if (!writeAllowed(address, reg, 1, 1, "write8")) {
    return false;
  }
  return withRetries(address, label, "write8", attempts,
                     [address, reg, value]() {
                       Wire.beginTransmission(address);
                       Wire.write(reg);
                       Wire.write(value);
                       return Wire.endTransmission() == 0;
                     });
}

bool writeRegisterBlock8(uint8_t address, uint8_t reg, const uint8_t *data,
                         uint8_t len, const char *label, uint8_t attempts) {
  if (data == nullptr || len == 0) {
    return false;
  }
  if (!writeAllowed(address, reg, 1, len, "writeBlock8")) {
    return false;
  }

  return withRetries(address, label, "writeBlock8", attempts,
                     [address, reg, data, len]() {
                       Wire.beginTransmission(address);
                       Wire.write(reg);
                       for (uint8_t i = 0; i < len; i++) {
                         Wire.write(data[i]);
                       }
                       return Wire.endTransmission() == 0;
                     });
}

bool writeRegister16(uint8_t address, uint16_t reg, uint8_t value,
                     const char *label, uint8_t attempts) {
  if (!writeAllowed(address, reg, 2, 1, "write16")) {
    return false;
  }
  return withRetries(address, label, "write16", attempts,
                     [address, reg, value]() {
                       Wire.beginTransmission(address);
                       Wire.write(static_cast<uint8_t>(reg >> 8));
                       Wire.write(static_cast<uint8_t>(reg & 0xFF));
                       Wire.write(value);
                       return Wire.endTransmission() == 0;
                     });
}

bool ensureAxp2101PowerButtonOffLevel(
    uint8_t level, Axp2101PowerButtonOffLevelResult &result,
    uint8_t attempts) {
  result = {};
  if (level >= axp_policy::POWER_BUTTON_OFF_LEVEL_COUNT) {
    Serial.printf("AXP_WRITE_BLOCKED schema=1 reg=0x%02X level=%u "
                  "policy=power-button-off-level\n",
                  axp_policy::POWER_BUTTON_CONFIG_REGISTER,
                  static_cast<unsigned>(level));
    return false;
  }

  bool observedInitialValue = false;
  return withRetries(
      axp_policy::DEVICE_ADDRESS, "AXP2101", "power-button-off-level",
      attempts, [&result, &observedInitialValue, level]() {
        Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
        Wire.write(axp_policy::POWER_BUTTON_CONFIG_REGISTER);
        if (Wire.endTransmission() != 0 ||
            Wire.requestFrom(axp_policy::DEVICE_ADDRESS,
                             static_cast<uint8_t>(1)) != 1) {
          return false;
        }

        const uint8_t current = Wire.read();
        if (!observedInitialValue) {
          result.before = current;
          observedInitialValue = true;
        }

        const uint8_t updated =
            (current & ~axp_policy::POWER_BUTTON_OFF_LEVEL_MASK) |
            ((level << axp_policy::POWER_BUTTON_OFF_LEVEL_SHIFT) &
             axp_policy::POWER_BUTTON_OFF_LEVEL_MASK);
        if (!axp_policy::isPowerButtonOffLevelTransition(current, updated) ||
            !axp_policy::isPowerButtonOffLevelTransition(result.before,
                                                          updated)) {
          Serial.printf("AXP_WRITE_BLOCKED schema=1 reg=0x%02X value=0x%02X "
                        "policy=power-button-off-level\n",
                        axp_policy::POWER_BUTTON_CONFIG_REGISTER, updated);
          return false;
        }

        if (current == updated) {
          result.after = current;
          const bool valid =
              axp_policy::isPowerButtonOffLevelTransition(result.before,
                                                           current);
          if (valid) {
            result.changed = result.before != current;
          }
          return valid;
        }

        Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
        Wire.write(axp_policy::POWER_BUTTON_CONFIG_REGISTER);
        Wire.write(updated);
        if (Wire.endTransmission() != 0) {
          return false;
        }

        delay(5);
        Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
        Wire.write(axp_policy::POWER_BUTTON_CONFIG_REGISTER);
        if (Wire.endTransmission() != 0 ||
            Wire.requestFrom(axp_policy::DEVICE_ADDRESS,
                             static_cast<uint8_t>(1)) != 1) {
          return false;
        }

        const uint8_t readback = Wire.read();
        result.after = readback;
        const bool valid =
            readback == updated &&
            axp_policy::isPowerButtonOffLevelTransition(result.before,
                                                         readback);
        if (valid) {
          result.changed = result.before != readback;
        }
        return valid;
      });
}

#ifdef WAVESHARE_AMOLED_206
bool ensureAxp2101DisplayEnabled(Axp2101DisplayEnableResult &result,
                                uint8_t attempts) {
  result = {};
  bool observedInitialValue = false;
  return withRetries(
      axp_policy::DEVICE_ADDRESS, "AXP2101", "display-enable-only", attempts,
      [&result, &observedInitialValue]() {
        Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
        Wire.write(axp_policy::DISPLAY_ENABLE_REGISTER_206);
        if (Wire.endTransmission() != 0 ||
            Wire.requestFrom(axp_policy::DEVICE_ADDRESS,
                             static_cast<uint8_t>(1)) != 1) {
          return false;
        }

        const uint8_t current = Wire.read();
        if (!observedInitialValue) {
          result.before = current;
          observedInitialValue = true;
        }
        const uint8_t updated = axp_policy::withDisplayEnabled206(current);
        if (current == updated) {
          result.after = current;
          const bool valid =
              axp_policy::isDisplayEnableOnlyTransition206(result.before,
                                                            current);
          if (valid) {
            result.changed = result.before != current;
          }
          return valid;
        }

        if (!axp_policy::isDisplayEnableOnlyTransition206(current, updated) ||
            !axp_policy::isDisplayEnableOnlyTransition206(result.before,
                                                           updated)) {
          Serial.printf("AXP_WRITE_BLOCKED schema=1 reg=0x%02X value=0x%02X "
                        "policy=206-display-enable-only\n",
                        axp_policy::DISPLAY_ENABLE_REGISTER_206, updated);
          return false;
        }

        Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
        Wire.write(axp_policy::DISPLAY_ENABLE_REGISTER_206);
        Wire.write(updated);
        if (Wire.endTransmission() != 0) {
          return false;
        }

        delay(5);
        Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
        Wire.write(axp_policy::DISPLAY_ENABLE_REGISTER_206);
        if (Wire.endTransmission() != 0 ||
            Wire.requestFrom(axp_policy::DEVICE_ADDRESS,
                             static_cast<uint8_t>(1)) != 1) {
          return false;
        }

        const uint8_t readback = Wire.read();
        result.after = readback;
        const bool valid =
            readback == updated &&
            axp_policy::isDisplayEnableOnlyTransition206(result.before,
                                                          readback);
        if (valid) {
          result.changed = result.before != readback;
        }
        return valid;
      });
}
#endif

bool readRegister8(uint8_t address, uint8_t reg, uint8_t &value,
                   const char *label, uint8_t attempts) {
  return withRetries(address, label, "read8", attempts, [address, reg, &value]() {
    Wire.beginTransmission(address);
    Wire.write(reg);
    if (Wire.endTransmission() != 0) {
      return false;
    }

    if (Wire.requestFrom(address, static_cast<uint8_t>(1)) != 1) {
      return false;
    }

    value = Wire.read();
    return true;
  });
}

bool readRegisterBlock8(uint8_t address, uint8_t reg, uint8_t *data,
                        uint8_t len, const char *label, uint8_t attempts) {
  if (data == nullptr || len == 0) {
    return false;
  }

  return withRetries(address, label, "readBlock8", attempts,
                     [address, reg, data, len]() {
                       Wire.beginTransmission(address);
                       Wire.write(reg);
#ifdef WAVESHARE_AMOLED_175
                       if (Wire.endTransmission() != 0) {
#else
                       if (Wire.endTransmission(false) != 0) {
#endif
                         return false;
                       }

                       delay(2);
                       if (Wire.requestFrom(address, len,
                                            static_cast<uint8_t>(true)) != len) {
                         return false;
                       }

                       for (uint8_t i = 0; i < len; i++) {
                         data[i] = Wire.read();
                       }
                       return true;
                     });
}

bool readRegister16(uint8_t address, uint16_t reg, uint8_t *data, uint8_t len,
                    const char *label, uint8_t attempts) {
  if (data == nullptr || len == 0) {
    return false;
  }

  return withRetries(address, label, "read16", attempts,
                     [address, reg, data, len]() {
                       Wire.beginTransmission(address);
                       Wire.write(reg >> 8);
                       Wire.write(reg & 0xFF);
#ifdef WAVESHARE_AMOLED_175
                       if (Wire.endTransmission() != 0) {
#else
                       if (Wire.endTransmission(false) != 0) {
#endif
                         return false;
                       }

                       delay(2);
                       if (Wire.requestFrom(address, len,
                                            static_cast<uint8_t>(true)) != len) {
                         return false;
                       }

                       for (uint8_t i = 0; i < len; i++) {
                         data[i] = Wire.read();
                       }
                       return true;
                     });
}

} // namespace waveshare_board::i2c

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
