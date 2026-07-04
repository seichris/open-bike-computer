#pragma once

#include <Arduino.h>

namespace xiao_round {

class DisplayRound {
public:
  static constexpr int16_t width = 240;
  static constexpr int16_t height = 240;

  bool begin();
  void setBrightness(uint8_t percent);
  void drawBootScreen();
  void drawStatus(const char *line1, const char *line2);
  void beginMapFrame();
  void drawLine(int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                uint16_t color);
  void drawCenteredPositionMarker(bool courseUp);
  void drawNavigationGuidanceOverlay(uint8_t iconId, uint16_t distanceMeters);
  void endMapFrame(const char *label, uint32_t elapsedMs);

private:
  uint8_t brightnessPercent = 100;
  uint16_t frameLineCount = 0;
  bool frameActive = false;
  bool statusOverlayPending = false;
  bool initialized = false;
};

} // namespace xiao_round
