#include "display_round.hpp"

#include "round_display_pins.hpp"

#include <SPI.h>
#include <TFT_eSPI.h>

namespace xiao_round {
namespace {

constexpr uint16_t BACKGROUND_COLOR = TFT_BLACK;
constexpr uint16_t PRIMARY_TEXT_COLOR = TFT_WHITE;
constexpr uint16_t SECONDARY_TEXT_COLOR = TFT_CYAN;
constexpr uint16_t STATUS_PANEL_COLOR = 0x0008;
constexpr uint16_t ACCENT_COLOR = TFT_GREEN;
constexpr uint16_t GUIDANCE_PANEL_COLOR = 0x0000;
constexpr uint16_t GUIDANCE_DIM_COLOR = 0x4208;

TFT_eSPI tft;

void drawCenteredText(const char *text, int16_t y, uint8_t size,
                      uint16_t color) {
  tft.setTextSize(size);
  tft.setTextColor(color, BACKGROUND_COLOR);
  tft.setTextDatum(TC_DATUM);
  tft.drawString(text == nullptr ? "" : text, DisplayRound::width / 2, y);
}

void drawStatusPanel(const char *line1, const char *line2, bool overlay) {
  if (overlay) {
    tft.fillRect(0, 0, DisplayRound::width, 38, STATUS_PANEL_COLOR);
    tft.fillRect(0, DisplayRound::height - 42, DisplayRound::width, 42,
                 STATUS_PANEL_COLOR);
  } else {
    tft.fillScreen(BACKGROUND_COLOR);
  }

  tft.setTextDatum(TC_DATUM);
  tft.setTextSize(2);
  tft.setTextColor(PRIMARY_TEXT_COLOR, overlay ? STATUS_PANEL_COLOR
                                               : BACKGROUND_COLOR);
  tft.drawString(line1 == nullptr ? "" : line1, DisplayRound::width / 2,
                 overlay ? 8 : 76);

  tft.setTextSize(1);
  tft.setTextColor(SECONDARY_TEXT_COLOR, overlay ? STATUS_PANEL_COLOR
                                                 : BACKGROUND_COLOR);
  tft.drawString(line2 == nullptr ? "" : line2, DisplayRound::width / 2,
                 overlay ? DisplayRound::height - 28 : 128);
}

void drawThickLine(int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                   uint16_t color, int16_t thickness) {
  const bool mostlyVertical = abs(y2 - y1) >= abs(x2 - x1);
  const int16_t half = thickness / 2;
  for (int16_t offset = -half; offset <= half; offset++) {
    if (mostlyVertical) {
      tft.drawLine(x1 + offset, y1, x2 + offset, y2, color);
    } else {
      tft.drawLine(x1, y1 + offset, x2, y2 + offset, color);
    }
  }
}

void drawManeuverArrow(uint8_t iconId, int16_t x, int16_t y, uint16_t color) {
  switch (iconId) {
  case 2:
    drawThickLine(x + 18, y + 28, x + 18, y + 4, color, 6);
    drawThickLine(x + 18, y + 4, x - 18, y + 4, color, 6);
    tft.fillTriangle(x - 26, y + 4, x - 12, y - 6, x - 12, y + 14, color);
    break;
  case 3:
    drawThickLine(x - 18, y + 28, x - 18, y + 4, color, 6);
    drawThickLine(x - 18, y + 4, x + 18, y + 4, color, 6);
    tft.fillTriangle(x + 26, y + 4, x + 12, y - 6, x + 12, y + 14, color);
    break;
  case 4:
    drawThickLine(x + 18, y + 28, x + 18, y - 6, color, 6);
    drawThickLine(x + 18, y - 6, x - 12, y - 6, color, 6);
    drawThickLine(x - 12, y - 6, x - 12, y + 16, color, 6);
    tft.fillTriangle(x - 12, y + 26, x - 22, y + 12, x - 2, y + 12, color);
    break;
  default:
    drawThickLine(x, y + 26, x, y - 12, color, 6);
    tft.fillTriangle(x, y - 24, x - 12, y - 6, x + 12, y - 6, color);
    break;
  }
}

} // namespace

bool DisplayRound::begin() {
  pinMode(pins::backlight, OUTPUT);
  pinMode(pins::touchInt, INPUT);
  pinMode(pins::lcdCs, OUTPUT);
  pinMode(pins::sdCs, OUTPUT);
  pinMode(pins::lcdDc, OUTPUT);

  digitalWrite(pins::lcdCs, HIGH);
  digitalWrite(pins::sdCs, HIGH);
  setBrightness(brightnessPercent);

  SPI.setPins(pins::spiMiso, pins::spiSck, pins::spiMosi);
  SPI.begin();
  tft.init();
  tft.setRotation(3);
  tft.fillScreen(BACKGROUND_COLOR);
  initialized = true;

  Serial.println("DisplayRound: Seeed_GFX GC9A01 init complete");
  return initialized;
}

void DisplayRound::setBrightness(uint8_t percent) {
  brightnessPercent = percent > 100 ? 100 : percent;
  const uint8_t duty = static_cast<uint8_t>((brightnessPercent * 255U) / 100U);
  analogWrite(pins::backlight, duty);
  Serial.print("DisplayRound: brightness=");
  Serial.print(brightnessPercent);
  Serial.println("%");
}

void DisplayRound::drawBootScreen() {
  if (initialized) {
    tft.fillScreen(BACKGROUND_COLOR);
    tft.drawCircle(width / 2, height / 2, 112, ACCENT_COLOR);
    drawCenteredText("Bike", 78, 3, PRIMARY_TEXT_COLOR);
    drawCenteredText("Computer", 112, 2, SECONDARY_TEXT_COLOR);
    drawCenteredText("XIAO nRF52840", 154, 1, PRIMARY_TEXT_COLOR);
  }
  Serial.println("DisplayRound: boot screen drawn");
}

void DisplayRound::drawStatus(const char *line1, const char *line2) {
  if (initialized) {
    drawStatusPanel(line1, line2, statusOverlayPending);
    statusOverlayPending = false;
  }
  Serial.print("DisplayRound: status: ");
  Serial.print(line1 == nullptr ? "" : line1);
  Serial.print(" | ");
  Serial.println(line2 == nullptr ? "" : line2);
}

void DisplayRound::beginMapFrame() {
  frameActive = true;
  statusOverlayPending = false;
  frameLineCount = 0;
  if (initialized) {
    tft.fillScreen(BACKGROUND_COLOR);
  }
}

void DisplayRound::drawLine(int16_t x1, int16_t y1, int16_t x2, int16_t y2,
                            uint16_t color) {
  if (frameActive) {
    frameLineCount++;
    if (initialized) {
      tft.drawLine(x1, y1, x2, y2, color);
    }
  }
}

void DisplayRound::drawCenteredPositionMarker(bool courseUp) {
  if (!frameActive) {
    return;
  }
  frameLineCount += 4;
  if (!initialized) {
    return;
  }

  const int16_t centerX = width / 2;
  const int16_t centerY = height / 2;
  if (courseUp) {
    tft.fillTriangle(centerX, centerY - 15, centerX - 11, centerY + 12,
                     centerX + 11, centerY + 12, TFT_WHITE);
    tft.drawTriangle(centerX, centerY - 15, centerX - 11, centerY + 12,
                     centerX + 11, centerY + 12, TFT_BLACK);
  } else {
    tft.fillCircle(centerX, centerY, 5, TFT_WHITE);
    tft.drawCircle(centerX, centerY, 7, TFT_BLACK);
  }
}

void DisplayRound::drawNavigationGuidanceOverlay(uint8_t iconId,
                                                 uint16_t distanceMeters) {
  if (!frameActive) {
    return;
  }
  frameLineCount += 12;
  if (!initialized) {
    return;
  }

  const int16_t panelY = (height * 2) / 3;
  const int16_t panelHeight = height - panelY;
  tft.fillRect(0, panelY, width, panelHeight, GUIDANCE_PANEL_COLOR);
  tft.drawFastHLine(0, panelY, width, GUIDANCE_DIM_COLOR);

  drawManeuverArrow(iconId, 50, panelY + 45, TFT_WHITE);

  char value[12];
  char unit[4];
  if (distanceMeters >= 1000) {
    snprintf(value, sizeof(value), "%u.%u", distanceMeters / 1000,
             (distanceMeters % 1000) / 100);
    snprintf(unit, sizeof(unit), "km");
  } else {
    snprintf(value, sizeof(value), "%u", distanceMeters);
    snprintf(unit, sizeof(unit), "m");
  }

  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, GUIDANCE_PANEL_COLOR);
  tft.setTextSize(5);
  tft.drawString(value, 100, panelY + 14);
  tft.setTextSize(2);
  tft.drawString(unit, 104, panelY + 58);
}

void DisplayRound::endMapFrame(const char *label, uint32_t elapsedMs) {
  Serial.print("DisplayRound: map frame ");
  Serial.print(label == nullptr ? "preview" : label);
  Serial.print(" lines=");
  Serial.print(frameLineCount);
  Serial.print(" elapsed_ms=");
  Serial.println(elapsedMs);
  frameActive = false;
  statusOverlayPending = true;
}

} // namespace xiao_round
