#pragma once

#include <cstdint>

// TCA9554 I/O expander on the board I2C bus (waveshare_board::TCA9554_ADDR).
// Output levels and pin directions are shadowed here so every user of the
// expander (touch reset, GNSS receiver reset) works on one register image.
// Each update and its register write happen under one lock, so users on
// different tasks cannot write over each other's pins.
namespace waveshare_board::tca9554 {

constexpr uint8_t OUTPUT_REG = 0x01;
constexpr uint8_t CONFIG_REG = 0x03;

// True when the expander answers on the bus.
bool present(const char *label = "TCA9554");
// Marks a pin (0-7) as an output in the shadowed configuration register.
bool configureOutput(uint8_t pin);
// Drives a configured output pin (0-7).
bool setPin(uint8_t pin, bool level);

}  // namespace waveshare_board::tca9554
