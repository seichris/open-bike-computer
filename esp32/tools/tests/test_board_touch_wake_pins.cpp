#include <cassert>
#include <cstdint>

// Host stand-in for ESP-IDF's numeric GPIO enum. Compile the real HAL for each
// board so the wake-policy test cannot hide a wrong pin behind a test fixture.
enum {
  GPIO_NUM_0 = 0, GPIO_NUM_1 = 1, GPIO_NUM_2 = 2, GPIO_NUM_3 = 3,
  GPIO_NUM_4 = 4, GPIO_NUM_5 = 5, GPIO_NUM_6 = 6, GPIO_NUM_7 = 7,
  GPIO_NUM_8 = 8, GPIO_NUM_9 = 9, GPIO_NUM_11 = 11, GPIO_NUM_12 = 12,
  GPIO_NUM_14 = 14, GPIO_NUM_15 = 15, GPIO_NUM_17 = 17, GPIO_NUM_21 = 21,
  GPIO_NUM_38 = 38, GPIO_NUM_39 = 39, GPIO_NUM_41 = 41,
};

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
