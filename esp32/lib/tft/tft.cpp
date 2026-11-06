/**
 * @file tft.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief TFT definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "tft.hpp"
#include "power_metrics.hpp"

#include "display_power.hpp"


bool repeatCalib = false;
uint16_t TFT_WIDTH = 0;
uint16_t TFT_HEIGHT = 0;
bool waitScreenRefresh = false;
extern Storage storage;

/**
 * @brief Turn on TFT display
 *
 */
void tftOn(uint8_t brightness)
{
  // Compatibility adapter for legacy callers. DisplayPowerManager remains the
  // only owner that issues CO5300 brightness and display-state commands.
  const int32_t percent =
      (static_cast<uint32_t>(brightness) * 100u + 127u) / 255u;
  displayPowerManager.requestUserBrightness(percent);
  displayPowerManager.requestState(display_power::State::Active);
  displayPowerManager.applyPendingPanelChange();
}

/**
 * @brief Turn off TFT display
 *
 */
void tftOff()
{
  displayPowerManager.requestState(display_power::State::Off);
  displayPowerManager.applyPendingPanelChange();
}

/**
 * @brief Touch calibrate (LovyanGFX only)
 *
 */

/**
 * @brief Init TFT display
 *
 */
void initTFT()
{
  // Arduino_GFX initialization for CO5300
  setupDisplay();

  TFT_WIDTH = SCREEN_WIDTH;
  TFT_HEIGHT = SCREEN_HEIGHT;

  // No touch calibration needed for Arduino_GFX (handled in setupLVGLforArduinoGFX)
}
