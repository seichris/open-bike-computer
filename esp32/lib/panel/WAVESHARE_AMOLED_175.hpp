/**
 * @file WAVESHARE_AMOLED_175.hpp
 * @brief Waveshare 1.75 AMOLED (CO5300) pin definition for IceNav
 */

#pragma once

// Use Arduino_GFX for CO5300 AMOLED (like working esp32 project)
#include "../waveshare_board/display.hpp"
#include "../waveshare_board/cst9217_touch_frame.hpp"

class Arduino_ESP32QSPI;
class Arduino_CO5300;
struct lv_display_t;

// Display dimensions
#define SCREEN_WIDTH waveshare_board::display::ACTIVE_WIDTH
#define SCREEN_HEIGHT waveshare_board::display::ACTIVE_HEIGHT

// Arduino_GFX instances
extern Arduino_ESP32QSPI *bus;
extern Arduino_CO5300 *gfx;

// LVGL 9 display buffer
extern lv_display_t *display;
extern volatile uint32_t displayFlushCount;
extern volatile uint32_t lastDisplayFlushMs;
extern volatile uint32_t lastDisplayFlushDurationUs;
extern volatile uint32_t maxDisplayFlushDurationUs;

// Touch handling (CST9217)
extern bool touchPressed;
extern uint16_t touchX, touchY;
waveshare_board::touch::TouchFrame getTouchFrameSnapshot();
uint32_t getTouchActivityGeneration();
bool isPrimaryTouchSuppressed();
void suppressPrimaryTouchUntilReleaseForDisplayWake();
using MultiTouchSuppressionPolicy = bool (*)();
void setMultiTouchSuppressionPolicy(MultiTouchSuppressionPolicy policy);
bool hasUnattemptedTouchInterrupt();
void configureTouchWakeInterrupt();
bool isTouchWakeSourceActive();
bool hasFullScreenRgb565Buffer();

// Function declarations
void setupDisplay();
void setupLVGLforArduinoGFX();
void readTouch();

