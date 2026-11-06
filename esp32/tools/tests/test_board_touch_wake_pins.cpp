#include <cassert>
#include <cstdint>

// Compile the real board definition and hal.hpp names for each board so the
// wake-policy test cannot hide a wrong pin behind a test fixture.
#include "../../include/hal.hpp"
#include "../../lib/ui_scheduler/ui_scheduler_policy.hpp"

int main() {
#if defined(WAVESHARE_AMOLED_175)
  // Retained vendor schematic page 1: TP_INT=11, QMI_INT2=21.
  constexpr uint8_t schematicTouchPin = 11;
  constexpr uint8_t unrelatedPin = 21;
  static_assert(TCH_I2C_INT == schematicTouchPin);
  static_assert(TFT_QSPI_CLK == 38);
#elif defined(WAVESHARE_AMOLED_206)
  // The 2.06 uses GPIO11 for the display clock, NOT touch.
  constexpr uint8_t schematicTouchPin = 38;
  constexpr uint8_t unrelatedPin = 11;
  static_assert(TCH_I2C_INT == schematicTouchPin);
  static_assert(TFT_QSPI_CLK == 11);
#else
#error Select the board under test
#endif
  static_assert(BOARD_BOOT_PIN == 0);
  static_assert(TCH_I2C_INT != TFT_QSPI_CLK);
  static_assert(TCH_I2C_INT == board::touch::interrupt);
  static_assert(BOARD_BOOT_PIN == board::buttons::boot);
  static_assert(board::touch::resetOnGpio == (TCH_I2C_RST != board::noPin));
  assert(ui_scheduler::gpioWakeReasons(0, TCH_I2C_INT, BOARD_BOOT_PIN) == 0);
  const auto touch = ui_scheduler::gpioWakeReasons(
      1ULL << schematicTouchPin, TCH_I2C_INT, BOARD_BOOT_PIN);
  assert(ui_scheduler::hasReason(touch, ui_scheduler::WakeReason::Touch));
  assert(!ui_scheduler::hasReason(touch, ui_scheduler::WakeReason::Boot));
  assert(ui_scheduler::gpioWakeReasons(
             1ULL << unrelatedPin, TCH_I2C_INT, BOARD_BOOT_PIN) == 0);
  const auto both = ui_scheduler::gpioWakeReasons(
      (1ULL << schematicTouchPin) | (1ULL << BOARD_BOOT_PIN),
      TCH_I2C_INT, BOARD_BOOT_PIN);
  assert(ui_scheduler::hasReason(both, ui_scheduler::WakeReason::Touch));
  assert(ui_scheduler::hasReason(both, ui_scheduler::WakeReason::Boot));
}
