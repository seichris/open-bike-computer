/**
 * @file i2c_bus.cpp
 * @brief Shared I2C helpers for the Waveshare ESP32-S3 Touch AMOLED 1.75.
 */

#include "i2c_bus.hpp"

#ifdef WAVESHARE_AMOLED_175

#include "waveshare_board.hpp"
#include <Wire.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <hal.hpp>

namespace waveshare_board::i2c {

namespace {

Stats i2cStats;
bool busConfigured = false;
uint32_t activeClockHz = DEFAULT_CLOCK_HZ;
uint32_t lastFailureLogMs = 0;
SemaphoreHandle_t busMutex = nullptr;

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

template <typename Fn>
bool withRetries(uint8_t address, const char *label, const char *operation,
                 uint8_t attempts, Fn &&fn) {
  if (attempts == 0) {
    attempts = 1;
  }

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
    recoverAfterFailure();
    if (attempt + 1 < attempts) {
      delay(2);
    }
  }

  logFailure(label, operation, address);
  return false;
}

} // namespace

void configureBus(uint32_t clockHz) {
  ensureMutex();
  activeClockHz = clockHz;
  Wire.setPins(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.begin();
  Wire.setClock(activeClockHz);
  Wire.setTimeOut(DEFAULT_TIMEOUT_MS);
  busConfigured = true;
  Serial.printf("Waveshare I2C: configured SDA=%u SCL=%u clock=%lu Hz timeout=%u ms\n",
                I2C_SDA_PIN, I2C_SCL_PIN,
                static_cast<unsigned long>(activeClockHz), DEFAULT_TIMEOUT_MS);
}

const Stats &stats() { return i2cStats; }

void debugScan(Stream &out, uint8_t firstAddress, uint8_t lastAddress) {
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
  bool ok = withRetries(address, label, "probe", attempts, [address]() {
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
                       if (Wire.endTransmission(false) != 0) {
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
                       if (Wire.endTransmission(false) != 0) {
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

#endif // WAVESHARE_AMOLED_175
