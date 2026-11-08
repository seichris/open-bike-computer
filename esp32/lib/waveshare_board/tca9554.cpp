#include "tca9554.hpp"

#include "i2c_bus.hpp"
#include "waveshare_board.hpp"

namespace waveshare_board::tca9554 {

namespace {
// Power-on defaults of the TCA9554: every pin an input, outputs latched high.
uint8_t outputShadow = 0xFF;
uint8_t configShadow = 0xFF;
}  // namespace

bool present(const char *label) {
  return waveshare_board::i2c::probe(waveshare_board::TCA9554_ADDR, label);
}

bool configureOutput(uint8_t pin) {
  if (pin > 7)
    return false;
  configShadow &= static_cast<uint8_t>(~(1U << pin));  // Clear bit = output
  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, CONFIG_REG, configShadow, "TCA9554");
}

bool setPin(uint8_t pin, bool level) {
  if (pin > 7)
    return false;
  if (level) {
    outputShadow |= static_cast<uint8_t>(1U << pin);
  } else {
    outputShadow &= static_cast<uint8_t>(~(1U << pin));
  }
  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, OUTPUT_REG, outputShadow, "TCA9554");
}

}  // namespace waveshare_board::tca9554
