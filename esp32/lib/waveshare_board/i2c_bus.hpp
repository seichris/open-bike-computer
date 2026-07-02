/**
 * @file i2c_bus.hpp
 * @brief Shared I2C helpers for the Waveshare ESP32-S3 Touch AMOLED 1.75.
 */

#pragma once

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include <Arduino.h>

namespace waveshare_board::i2c {

constexpr uint32_t DEFAULT_CLOCK_HZ = 100000;
constexpr uint16_t DEFAULT_TIMEOUT_MS = 50;

struct Stats {
  uint32_t recoveryAttempts = 0;
  uint32_t failedTransactions = 0;
  uint32_t recoveredTransactions = 0;
  uint32_t missingDevices = 0;
};

void configureBus(uint32_t clockHz = DEFAULT_CLOCK_HZ);
const Stats &stats();
void debugScan(Stream &out = Serial, uint8_t firstAddress = 0x08,
               uint8_t lastAddress = 0x77);

bool probe(uint8_t address, const char *label = nullptr,
           uint8_t attempts = 2);
bool writeRegister8(uint8_t address, uint8_t reg, uint8_t value,
                    const char *label = nullptr, uint8_t attempts = 2);
bool writeRegisterBlock8(uint8_t address, uint8_t reg, const uint8_t *data,
                         uint8_t len, const char *label = nullptr,
                         uint8_t attempts = 2);
bool readRegister8(uint8_t address, uint8_t reg, uint8_t &value,
                   const char *label = nullptr, uint8_t attempts = 3);
bool readRegisterBlock8(uint8_t address, uint8_t reg, uint8_t *data,
                        uint8_t len, const char *label = nullptr,
                        uint8_t attempts = 3);
bool readRegister16(uint8_t address, uint16_t reg, uint8_t *data, uint8_t len,
                    const char *label = nullptr, uint8_t attempts = 3);

} // namespace waveshare_board::i2c

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
