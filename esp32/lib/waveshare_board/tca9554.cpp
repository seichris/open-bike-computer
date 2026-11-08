#include "tca9554.hpp"

#include <mutex>

#include "i2c_bus.hpp"
#include "waveshare_board.hpp"

namespace waveshare_board::tca9554 {

namespace {
// Power-on defaults of the TCA9554: every pin an input, outputs latched high.
uint8_t outputShadow = 0xFF;
uint8_t configShadow = 0xFF;
// Serializes each shadow update with its register write. The touch
// controller is reset from the UI task (from the touch read path, after boot
// and after a failed init) and the GNSS receiver from its reader task; an
// interleaved read-modify-write would write an image that lacks the other
// task's pin. The bus transaction itself is bounded by the I2C helper's
// timeouts, so the hold time is too.
std::mutex shadowMutex;
}  // namespace

bool present(const char *label) {
  return waveshare_board::i2c::probe(waveshare_board::TCA9554_ADDR, label);
}

bool configureOutput(uint8_t pin) {
  if (pin > 7)
    return false;
  std::lock_guard<std::mutex> guard(shadowMutex);
  configShadow &= static_cast<uint8_t>(~(1U << pin));  // Clear bit = output
  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, CONFIG_REG, configShadow, "TCA9554");
}

bool setPin(uint8_t pin, bool level) {
  if (pin > 7)
    return false;
  std::lock_guard<std::mutex> guard(shadowMutex);
  if (level) {
    outputShadow |= static_cast<uint8_t>(1U << pin);
  } else {
    outputShadow &= static_cast<uint8_t>(~(1U << pin));
  }
  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, OUTPUT_REG, outputShadow, "TCA9554");
}

}  // namespace waveshare_board::tca9554
