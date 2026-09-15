#pragma once

#include "../epaper_display/epaper_display.hpp"
#include "../waveshare_board/display.hpp"
#include "../waveshare_board/cst9217_touch_frame.hpp"

struct lv_display_t;
#define SCREEN_WIDTH waveshare_board::display::ACTIVE_WIDTH
#define SCREEN_HEIGHT waveshare_board::display::ACTIVE_HEIGHT
extern lv_display_t *display;
extern volatile uint32_t displayFlushCount, lastDisplayFlushMs;
extern volatile uint32_t lastDisplayFlushDurationUs, maxDisplayFlushDurationUs;
void setupDisplay();
void setupLVGLforArduinoGFX(); // Shared RGB565 LVGL setup entry point.
bool hasFullScreenRgb565Buffer();
// Shared input observers have an explicit absent-touch result on this board.
inline waveshare_board::touch::TouchFrame getTouchFrameSnapshot() { return {}; }
inline uint32_t getTouchActivityGeneration() { return 0; }
inline bool isPrimaryTouchSuppressed() { return false; }
inline bool hasUnattemptedTouchInterrupt() { return false; }
inline void suppressPrimaryTouchUntilReleaseForDisplayWake() {}
inline void setMultiTouchSuppressionPolicy(bool (*)()) {}
inline void configureTouchWakeInterrupt() {}
inline bool isTouchWakeSourceActive() { return false; }
inline void readTouch() {}
