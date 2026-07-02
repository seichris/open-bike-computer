/**
 * @file waveshare_board.cpp
 * @brief Waveshare ESP32-S3 Touch AMOLED 1.75 board helpers.
 */

#include "waveshare_board.hpp"

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)

#include "axp2101.hpp"
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

void enablePowerRails() {
  axp2101::restoreDefaultRails();
}

} // namespace waveshare_board

#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206
