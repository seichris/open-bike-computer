/**
 * @file tft.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief TFT definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include <Arduino.h>
#include "../storage/storage.hpp"
#include "../panel/panelSelect.hpp"

// Use Arduino_GFX for CO5300 AMOLED
#include "../panel/WAVESHARE_AMOLED_175.hpp"

static const char* calibrationFile PROGMEM = "/spiffs/TouchCal";
extern bool repeatCalib;

extern uint16_t TFT_WIDTH;
extern uint16_t TFT_HEIGHT;
extern bool waitScreenRefresh;                  // Wait for refresh screen (screenshot issues)

void tftOn(uint8_t brightness);
void tftOff();
void initTFT();
