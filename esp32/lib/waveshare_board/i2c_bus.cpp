/**
 * @file i2c_bus.cpp
 * @brief Shared I2C helpers for the supported Waveshare ESP32-S3 boards.
 */

#include "i2c_bus.hpp"

#if DEVICE_REMOTE_DEBUG
#include "i2c_retry_log.hpp"
#endif


#include "axp2101_register_policy.hpp"
#include "waveshare_board.hpp"
#include "../power_management/power_management.hpp"
#include <Wire.h>
#include <atomic>
#include <cstring>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <hal.hpp>

namespace waveshare_board::i2c {

namespace {

namespace axp_policy = waveshare_board::axp2101::register_policy;

static_assert(axp_policy::DEVICE_ADDRESS == AXP2101_ADDR,
              "AXP2101 address must match the write policy");

// Counters are bumped from every task that uses the bus, inside and outside
// the bus lock (a failed probe counts its device missing after the lock is
// released), so they are atomic and read as a snapshot.
struct Counters {
  std::atomic<uint32_t> recoveryAttempts{0};
  std::atomic<uint32_t> failedTransactions{0};
  std::atomic<uint32_t> recoveredTransactions{0};
  std::atomic<uint32_t> missingDevices{0};
} i2cStats;
// Written and read only with the bus lock held: another task's recovery may
// be reinstalling the driver while this task decides whether to transact.
bool busConfigured = false;
uint32_t activeClockHz = DEFAULT_CLOCK_HZ;
uint32_t lastFailureLogMs = 0;
SemaphoreHandle_t busMutex = nullptr;

bool writeAllowed(uint8_t address, uint16_t reg,
                  std::size_t registerAddressBytes,
                  std::size_t payloadBytes, const char *shape) {
#ifdef WAVESHARE_EPAPER_397
  if (address == AXP2101_ADDR) return false;
#endif
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
             xSemaphoreTake(busMutex, pdMS_TO_TICKS(TRANSACTION_TIMEOUT_MS)) ==
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
                i2cStats.failedTransactions.load(), i2cStats.recoveryAttempts.load(),
                i2cStats.recoveredTransactions.load(), i2cStats.missingDevices.load());
  lastFailureLogMs = now;
}

// Installs the driver and applies the clock and timeout, recording whether
// the bus is usable. No transaction may run while it is not: the pinned
// TwoWire frees its buffers when begin() fails, endTransmission() then
// returns before releasing the bus mutex, and the next begin() or end()
// would wait on that mutex forever.
void beginBus() {
  // The receive buffer must hold the longest readStream; Wire keeps the size
  // it was given across end()/begin() cycles.
  if constexpr (STREAM_BUFFER_BYTES != I2C_BUFFER_LENGTH) {
    Wire.setBufferSize(STREAM_BUFFER_BYTES);
  }
  busConfigured = Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  if (busConfigured) {
    Wire.setClock(activeClockHz);
    Wire.setTimeOut(TRANSACTION_TIMEOUT_MS);
  }
}

// Used where board::i2c::recoverOnFailure is set (the 2.06): ends a live bus,
// clocks stuck slaves off SDA and installs the driver again.
[[maybe_unused]] void recoverAfterFailure() {
  i2cStats.recoveryAttempts++;
  if (busConfigured) {
    Wire.end();
  }
  waveshare_board::recoverI2CBus();
  beginBus();
}

// Called with the bus lock held before any transaction. A bus whose driver
// install failed is initialized again first: through the full recovery where
// the board recovers on failure, otherwise by a plain begin.
bool ensureBusConfigured() {
  if (busConfigured) {
    return true;
  }
  if constexpr (board::i2c::recoverOnFailure) {
    recoverAfterFailure();
  } else {
    beginBus();
  }
  return busConfigured;
}

uint32_t retryStartTime() {
#if DEVICE_REMOTE_DEBUG
  return millis();
#else
  return 0;
#endif
}

// Called only with BusLock held, after the transaction/retries have settled.
// No raw data or sensor values; production keeps its existing logging policy.
void logRetryResult(uint8_t address, uint16_t reg, const char *operation,
                    uint8_t attempts, bool recovered, uint32_t startedMs) {
#if DEVICE_REMOTE_DEBUG
  static RetryLogLimiter limiter;
  const uint32_t now = millis();
  uint32_t suppressed = 0;
  if (!limiter.admit(address, recovered, now, suppressed)) return;
  Serial.printf("I2C_RETRY schema=1 addr=0x%02X regKnown=%u reg=0x%04X "
                "operation=%s outcome=%s attempts=%u failedAttempts=%u "
                "elapsedMs=%lu suppressed=%lu\n",
                static_cast<unsigned>(address), reg != UINT16_MAX ? 1U : 0U,
                static_cast<unsigned>(reg), operation,
                recovered ? "recovered" : "exhausted",
                static_cast<unsigned>(attempts),
                static_cast<unsigned>(attempts - (recovered ? 1 : 0)),
                static_cast<unsigned long>(now - startedMs),
                static_cast<unsigned long>(suppressed));
#else
  (void)address;
  (void)reg;
  (void)operation;
  (void)attempts;
  (void)recovered;
  (void)startedMs;
#endif
}

template <typename Fn>
bool withRetries(uint8_t address, uint16_t reg, const char *label,
                 const char *operation, uint8_t attempts, Fn &&fn,
                 TransactionTrace *trace = nullptr) {
  const uint32_t traceStartedMs = trace ? millis() : 0;
  if (trace) *trace = {};
  if (attempts == 0) {
    attempts = 1;
  }

  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  BusLock lock;
  if (!lock.ok()) {
    if (trace) {
      trace->failure(TransactionPhase::Lock, 0);
      trace->elapsedMs = millis() - traceStartedMs;
    }
    i2cStats.failedTransactions++;
    logFailure(label, operation, address);
    return false;
  }

  const uint32_t startedMs = retryStartTime();
  for (uint8_t attempt = 0; attempt < attempts; attempt++) {
    if (trace) trace->attempts = attempt + 1;
    if (!ensureBusConfigured()) {
      // The driver is still not installed: count the attempt without touching
      // TwoWire, whose mutex a bufferless transaction would leave taken.
      if (trace) trace->failure(TransactionPhase::Transmit, 4);
      i2cStats.failedTransactions++;
      if (attempt + 1 < attempts) {
        delay(2);
      }
      continue;
    }
    if (fn()) {
      if (trace) trace->elapsedMs = millis() - traceStartedMs;
      if (attempt > 0) {
        i2cStats.recoveredTransactions++;
        logRetryResult(address, reg, operation, attempt + 1, true, startedMs);
      }
      return true;
    }

    i2cStats.failedTransactions++;
    if constexpr (board::i2c::recoverOnFailure) {
      recoverAfterFailure();
    }
    if (attempt + 1 < attempts) {
      delay(2);
    }
  }

  if (trace) trace->elapsedMs = millis() - traceStartedMs;
  logRetryResult(address, reg, operation, attempts, false, startedMs);
  logFailure(label, operation, address);
  return false;
}

} // namespace

void configureBus(uint32_t clockHz) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  ensureMutex();
  BusLock lock;
  if (!lock.ok()) {
    Serial.println("Waveshare I2C: bus busy, configuration skipped");
    return;
  }
  activeClockHz = clockHz;
  beginBus();
  Serial.printf("Waveshare I2C: %s SDA=%u SCL=%u clock=%lu Hz timeout=%u ms\n",
                busConfigured ? "configured" : "configuration failed",
                I2C_SDA_PIN, I2C_SCL_PIN,
                static_cast<unsigned long>(activeClockHz),
                static_cast<unsigned>(TRANSACTION_TIMEOUT_MS));
}

Stats stats() {
  Stats snapshot;
  snapshot.recoveryAttempts = i2cStats.recoveryAttempts.load();
  snapshot.failedTransactions = i2cStats.failedTransactions.load();
  snapshot.recoveredTransactions = i2cStats.recoveredTransactions.load();
  snapshot.missingDevices = i2cStats.missingDevices.load();
  return snapshot;
}

void debugScan(Stream &out, uint8_t firstAddress, uint8_t lastAddress) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::I2c);
  BusLock lock;
  if (!lock.ok()) {
    out.println("Waveshare I2C scan: bus busy");
    return;
  }
  if (!ensureBusConfigured()) {
    out.println("Waveshare I2C scan: bus not configured");
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
  bool ok = withRetries(address, UINT16_MAX, label, "probe", attempts, [address]() {
    Wire.beginTransmission(address);
    return Wire.endTransmission() == 0;
  });
  if (!ok) {
    i2cStats.missingDevices++;
  }
  return ok;
}

bool writeRegister8(uint8_t address, uint8_t reg, uint8_t value,
                    const char *label, uint8_t attempts) {
  if (!writeAllowed(address, reg, 1, 1, "write8")) {
    return false;
  }
  return withRetries(address, reg, label, "write8", attempts,
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

  return withRetries(address, reg, label, "writeBlock8", attempts,
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
                     const char *label, uint8_t attempts,
                     TransactionTrace *trace) {
  if (trace) *trace = {};
  if (!writeAllowed(address, reg, 2, 1, "write16")) {
    return false;
  }
  return withRetries(address, reg, label, "write16", attempts,
                     [address, reg, value, trace]() {
                       Wire.beginTransmission(address);
                       Wire.write(static_cast<uint8_t>(reg >> 8));
                       Wire.write(static_cast<uint8_t>(reg & 0xFF));
                       Wire.write(value);
                       const uint8_t status = Wire.endTransmission();
                       if (trace && status != 0)
                         trace->failure(TransactionPhase::Transmit, status);
                       return status == 0;
                     }, trace);
}

bool writeCommand16(uint8_t address, uint16_t command, const char *label,
                    uint8_t attempts) {
  if (!writeAllowed(address, command, 0, 2, "command16")) {
    return false;
  }
  return withRetries(address, command, label, "command16", attempts,
                     [address, command]() {
                       Wire.beginTransmission(address);
                       Wire.write(static_cast<uint8_t>(command >> 8));
                       Wire.write(static_cast<uint8_t>(command & 0xFF));
                       return Wire.endTransmission() == 0;
                     });
}

bool ensureAxp2101PowerButtonOffLevel(
    uint8_t level, Axp2101PowerButtonOffLevelResult &result,
    uint8_t attempts) {
  result = {};
#ifdef WAVESHARE_EPAPER_397
  return false;
#endif
  if (level >= axp_policy::POWER_BUTTON_OFF_LEVEL_COUNT) {
    Serial.printf("AXP_WRITE_BLOCKED schema=1 reg=0x%02X level=%u "
                  "policy=power-button-off-level\n",
                  axp_policy::POWER_BUTTON_CONFIG_REGISTER,
                  static_cast<unsigned>(level));
    return false;
  }

  bool observedInitialValue = false;
  return withRetries(
      axp_policy::DEVICE_ADDRESS, axp_policy::POWER_BUTTON_CONFIG_REGISTER,
      "AXP2101", "power-button-off-level",
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

#if BOARD_PMIC_DISPLAY_ENABLE_RECOVERY
bool ensureAxp2101DisplayEnabled(Axp2101DisplayEnableResult &result,
                                uint8_t attempts) {
  result = {};
  bool observedInitialValue = false;
  return withRetries(
      axp_policy::DEVICE_ADDRESS, axp_policy::DISPLAY_ENABLE_REGISTER_206,
      "AXP2101", "display-enable-only", attempts,
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

#ifdef WAVESHARE_EPAPER_397
bool ensureAxp2101EpaperPower(Axp2101EpaperPowerResult &result,
                             uint8_t attempts) {
  result = {};
  bool observedInitialValues = false;
  return withRetries(
      axp_policy::DEVICE_ADDRESS, UINT16_MAX, "AXP2101", "epaper-aldo3-only",
      attempts,
      [&result, &observedInitialValues]() {
        const auto readRegister = [](uint8_t reg, uint8_t &value) {
          Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
          Wire.write(reg);
          if (Wire.endTransmission() != 0 ||
              Wire.requestFrom(axp_policy::DEVICE_ADDRESS,
                               static_cast<uint8_t>(1)) != 1) {
            return false;
          }
          value = Wire.read();
          return true;
        };
        const auto writeRegister = [](uint8_t reg, uint8_t value) {
          Wire.beginTransmission(axp_policy::DEVICE_ADDRESS);
          Wire.write(reg);
          Wire.write(value);
          return Wire.endTransmission() == 0;
        };

        uint8_t enable = 0, voltage = 0;
        if (!readRegister(axp_policy::EPAPER_ALDO3_ENABLE_REGISTER, enable) ||
            !readRegister(axp_policy::EPAPER_ALDO3_VOLTAGE_REGISTER,
                          voltage)) {
          return false;
        }
        if (!observedInitialValues) {
          result.enableBefore = enable;
          result.voltageBefore = voltage;
          observedInitialValues = true;
        }

        const uint8_t targetVoltage =
            axp_policy::withEpaperAldo3At3300mV(voltage);
        const uint8_t targetEnable =
            axp_policy::withEpaperAldo3Enabled(enable);
        if (!axp_policy::isEpaperAldo3VoltageOnlyTransition(
                voltage, targetVoltage) ||
            !axp_policy::isEpaperAldo3VoltageOnlyTransition(
                result.voltageBefore, targetVoltage) ||
            !axp_policy::isEpaperAldo3EnableOnlyTransition(enable,
                                                           targetEnable) ||
            !axp_policy::isEpaperAldo3EnableOnlyTransition(
                result.enableBefore, targetEnable)) {
          Serial.printf("AXP_WRITE_BLOCKED schema=1 enable=0x%02X "
                        "voltage=0x%02X policy=epaper-aldo3-only\n",
                        targetEnable, targetVoltage);
          return false;
        }

        if (voltage != targetVoltage) {
          if (!writeRegister(axp_policy::EPAPER_ALDO3_VOLTAGE_REGISTER,
                             targetVoltage)) {
            return false;
          }
          delay(5);
          if (!readRegister(axp_policy::EPAPER_ALDO3_VOLTAGE_REGISTER,
                            voltage) || voltage != targetVoltage) {
            return false;
          }
        }
        if (enable != targetEnable) {
          if (!writeRegister(axp_policy::EPAPER_ALDO3_ENABLE_REGISTER,
                             targetEnable)) {
            return false;
          }
          delay(5);
        }

        if (!readRegister(axp_policy::EPAPER_ALDO3_ENABLE_REGISTER, enable) ||
            !readRegister(axp_policy::EPAPER_ALDO3_VOLTAGE_REGISTER,
                          voltage)) {
          return false;
        }
        result.enableAfter = enable;
        result.voltageAfter = voltage;
        const bool valid =
            enable == targetEnable && voltage == targetVoltage &&
            axp_policy::isEpaperAldo3EnableOnlyTransition(
                result.enableBefore, enable) &&
            axp_policy::isEpaperAldo3VoltageOnlyTransition(
                result.voltageBefore, voltage);
        if (valid) {
          result.enableChanged = result.enableBefore != enable;
          result.voltageChanged = result.voltageBefore != voltage;
        }
        return valid;
      });
}
#endif

bool readRegister8(uint8_t address, uint8_t reg, uint8_t &value,
                   const char *label, uint8_t attempts) {
  return withRetries(address, reg, label, "read8", attempts, [address, reg, &value]() {
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

  return withRetries(address, reg, label, "readBlock8", attempts,
                     [address, reg, data, len]() {
                       Wire.beginTransmission(address);
                       Wire.write(reg);
                       if (Wire.endTransmission(
                               board::i2c::stopBetweenWriteAndRead) != 0) {
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

bool readRegisterBlock8Once(uint8_t address, uint8_t reg, uint8_t *data,
                            uint8_t len) {
  if (data == nullptr || len == 0 || len > 16 ||
      static_cast<unsigned>(reg) + len > 256)
    return false;

  power_management::ScopedLock powerLock(power_management::LockDomain::I2c);
  BusLock lock;
  if (!lock.ok()) return false;
  // Read under the bus lock: another task's recovery may be reinstalling the
  // driver, and a transaction on a bufferless bus would keep TwoWire's mutex.
  // Observation never reinstalls the driver itself.
  if (!busConfigured) return false;
  // Intentionally not withRetries(): where the board recovers the bus on
  // failure (the 2.06), even its final failed attempt resets/reconfigures
  // the bus. Observation must not do that.
  Wire.beginTransmission(address);
  Wire.write(reg); // address pointer only, not a register-value write
  if (Wire.endTransmission(board::i2c::stopBetweenWriteAndRead) != 0)
    return false;
  delay(2); // retain the existing board read transaction timing
  if (Wire.requestFrom(address, len, static_cast<uint8_t>(true)) != len)
    return false;
  uint8_t result[16] = {};
  for (uint8_t i = 0; i < len; ++i) {
    const int value = Wire.read();
    if (value < 0) return false;
    result[i] = static_cast<uint8_t>(value);
  }
  std::memcpy(data, result, len);
  return true;
}

bool readRegister16(uint8_t address, uint16_t reg, uint8_t *data, uint8_t len,
                    const char *label, uint8_t attempts,
                    TransactionTrace *trace) {
  if (trace) *trace = {};
  if (data == nullptr || len == 0) {
    return false;
  }

  return withRetries(address, reg, label, "read16", attempts,
                     [address, reg, data, len, trace]() {
                       Wire.beginTransmission(address);
                       Wire.write(reg >> 8);
                       Wire.write(reg & 0xFF);
                       const uint8_t status = Wire.endTransmission(
                           board::i2c::stopBetweenWriteAndRead);
                       if (status != 0) {
                         if (trace)
                           trace->failure(TransactionPhase::Transmit, status);
                         return false;
                       }

                       delay(2);
                       const uint8_t received = Wire.requestFrom(
                           address, len, static_cast<uint8_t>(true));
                       if (received != len) {
                         if (trace)
                           trace->failure(TransactionPhase::Receive, received);
                         return false;
                       }

                       for (uint8_t i = 0; i < len; i++) {
                         data[i] = Wire.read();
                       }
                       return true;
                     }, trace);
}

bool readBytes(uint8_t address, uint8_t *data, uint8_t len,
               const char *label, uint8_t attempts) {
  if (data == nullptr || len == 0) {
    return false;
  }
  return withRetries(address, UINT16_MAX, label, "readBytes", attempts,
                     [address, data, len]() {
                       if (Wire.requestFrom(address, len,
                                            static_cast<uint8_t>(true)) != len) {
                         return false;
                       }
                       for (uint8_t i = 0; i < len; ++i) {
                         data[i] = Wire.read();
                       }
                       return true;
                     });
}

bool writeBytes(uint8_t address, const uint8_t *data, uint8_t len,
                const char *label, uint8_t attempts) {
  if (data == nullptr || len == 0) {
    return false;
  }
  if (!writeAllowed(address, data[0], 1, static_cast<std::size_t>(len) - 1,
                    "writeBytes")) {
    return false;
  }
  return withRetries(address, data[0], label, "writeBytes", attempts,
                     [address, data, len]() {
                       Wire.beginTransmission(address);
                       for (uint8_t i = 0; i < len; i++) {
                         Wire.write(data[i]);
                       }
                       return Wire.endTransmission() == 0;
                     });
}

bool readStream(uint8_t address, uint8_t *data, size_t len, const char *label,
                uint8_t attempts) {
  if (data == nullptr || len == 0 || len > STREAM_BUFFER_BYTES) {
    return false;
  }
  return withRetries(address, UINT16_MAX, label, "readStream", attempts,
                     [address, data, len]() {
                       if (Wire.requestFrom(address, len, true) != len) {
                         return false;
                       }
                       for (size_t i = 0; i < len; ++i) {
                         data[i] = static_cast<uint8_t>(Wire.read());
                       }
                       return true;
                     });
}

} // namespace waveshare_board::i2c

