/**
 * @file waveshare_board.cpp
 * @brief Waveshare ESP32-S3 Touch AMOLED 1.75 board helpers.
 */

#include "waveshare_board.hpp"

#ifdef WAVESHARE_AMOLED_175

#include <Wire.h>
#include <hal.hpp>

namespace waveshare_board {

void recoverI2CBus() {
  // Must run before Wire.begin() so stuck slaves can release SDA.
  log_i("Performing I2C bus recovery...");

  pinMode(I2C_SDA_PIN, INPUT_PULLUP);
  pinMode(I2C_SCL_PIN, OUTPUT);

  int clockCount = 0;
  for (int i = 0; i < 9; i++) {
    digitalWrite(I2C_SCL_PIN, LOW);
    delayMicroseconds(5);
    digitalWrite(I2C_SCL_PIN, HIGH);
    delayMicroseconds(5);
    clockCount++;

    if (digitalRead(I2C_SDA_PIN) == HIGH) {
      break;
    }
  }

  pinMode(I2C_SDA_PIN, OUTPUT);
  digitalWrite(I2C_SDA_PIN, LOW);
  delayMicroseconds(5);
  digitalWrite(I2C_SCL_PIN, HIGH);
  delayMicroseconds(5);
  digitalWrite(I2C_SDA_PIN, HIGH);
  delayMicroseconds(5);

  log_i("I2C bus recovery done (%d clocks)", clockCount);
}

static void writeAxp2101(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(AXP2101_ADDR);
  Wire.write(reg);
  Wire.write(value);
  Wire.endTransmission();
}

void enablePowerRails() {
  Serial.println("Enabling display power via AXP2101...");
  Wire.beginTransmission(AXP2101_ADDR);
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ AXP2101 found!");

    writeAxp2101(AXP2101_DLDO1_REG, AXP2101_LDO_3V3);
    writeAxp2101(AXP2101_DLDO1_REG, AXP2101_LDO_3V3_ENABLED);

    constexpr uint8_t ldoRegs[] = {
        AXP2101_ALDO1_REG, AXP2101_ALDO2_REG, AXP2101_ALDO3_REG,
        AXP2101_ALDO4_REG, AXP2101_BLDO1_REG, AXP2101_BLDO2_REG};

    Serial.println("Resetting Peripheral Power...");
    for (uint8_t reg : ldoRegs) {
      writeAxp2101(reg, AXP2101_LDO_3V3);
    }
    delay(500);

    Serial.println("Enabling Peripheral Power...");
    for (uint8_t reg : ldoRegs) {
      writeAxp2101(reg, AXP2101_LDO_3V3);
      writeAxp2101(reg, AXP2101_LDO_3V3_ENABLED);
    }

    delay(500);
    Serial.println("✓ AXP2101 display power enabled");
  } else {
    Serial.println("✗ AXP2101 not found - display may not work!");
  }
}

} // namespace waveshare_board

#endif // WAVESHARE_AMOLED_175
