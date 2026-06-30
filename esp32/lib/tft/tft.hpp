/**
 * @file tft.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief TFT definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include <Arduino.h>
#include "storage.hpp"
#include "panelSelect.hpp"

#ifdef USE_ARDUINO_GFX
// Use Arduino_GFX for CO5300 AMOLED
#include "WAVESHARE_AMOLED_175.hpp"
#else
// Use LovyanGFX for other displays
#include <LGFX_TFT_eSPI.hpp>
extern TFT_eSPI tft;
#endif

static const char* calibrationFile PROGMEM = "/spiffs/TouchCal";
extern bool repeatCalib;

extern uint16_t TFT_WIDTH;
extern uint16_t TFT_HEIGHT;
extern bool waitScreenRefresh;                  // Wait for refresh screen (screenshot issues)

void tftOn(uint8_t brightness);
void tftOff();
#ifndef USE_ARDUINO_GFX
void touchCalibrate();
#endif
void initTFT();
