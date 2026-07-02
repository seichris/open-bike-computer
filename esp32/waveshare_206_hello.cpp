#include <Arduino.h>
#include <Arduino_GFX_Library.h>

#if ARDUINO_USB_CDC_ON_BOOT
#define TEST_SERIAL Serial
#else
#include "HWCDC.h"
HWCDC USBSerial;
#define TEST_SERIAL USBSerial
#endif

namespace {
constexpr int LCD_SDIO0 = 4;
constexpr int LCD_SDIO1 = 5;
constexpr int LCD_SDIO2 = 6;
constexpr int LCD_SDIO3 = 7;
constexpr int LCD_SCLK = 11;
constexpr int LCD_CS = 12;
constexpr int LCD_RESET = 8;
constexpr int LCD_WIDTH = 410;
constexpr int LCD_HEIGHT = 502;
constexpr uint16_t COLOR_BLACK = 0x0000;
constexpr uint16_t COLOR_WHITE = 0xFFFF;
constexpr uint16_t COLOR_RED = 0xF800;
constexpr uint16_t COLOR_GREEN = 0x07E0;
constexpr uint16_t COLOR_BLUE = 0x001F;
constexpr uint16_t COLOR_YELLOW = 0xFFE0;

Arduino_DataBus *bus = new Arduino_ESP32QSPI(
    LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);

Arduino_GFX *gfx = new Arduino_CO5300(bus, LCD_RESET, 0, LCD_WIDTH, LCD_HEIGHT,
                                      22, 0, 0, 0);
} // namespace

void setup() {
  TEST_SERIAL.begin(115200);
  delay(1500);
  TEST_SERIAL.println("Waveshare 2.06 vendor-shaped HelloWorld display test");
  TEST_SERIAL.printf("pins cs=%d sclk=%d d0=%d d1=%d d2=%d d3=%d rst=%d\n",
                     LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2,
                     LCD_SDIO3, LCD_RESET);
  TEST_SERIAL.printf("panel %dx%d gap=(22,0,0,0)\n", LCD_WIDTH, LCD_HEIGHT);

#ifdef GFX_EXTRA_PRE_INIT
  GFX_EXTRA_PRE_INIT();
#endif

  if (!gfx->begin()) {
    TEST_SERIAL.println("gfx->begin() failed");
  } else {
    TEST_SERIAL.println("gfx->begin() ok");
  }

  gfx->fillScreen(COLOR_WHITE);
  gfx->setCursor(10, 10);
  gfx->setTextColor(COLOR_RED);
  gfx->setTextSize(3);
  gfx->println("Hello");
  gfx->setCursor(10, 50);
  gfx->setTextColor(COLOR_BLUE);
  gfx->println("2.06");
  TEST_SERIAL.println("white fill + text written");
}

void loop() {
  static uint32_t last = 0;
  if (millis() - last < 1000) {
    return;
  }
  last = millis();

  static uint8_t colorIndex = 0;
  static constexpr uint16_t colors[] = {
      COLOR_WHITE, COLOR_RED, COLOR_GREEN, COLOR_BLUE, COLOR_YELLOW};
  uint16_t color = colors[colorIndex % (sizeof(colors) / sizeof(colors[0]))];
  colorIndex++;

  gfx->fillScreen(color);
  gfx->drawRect(0, 0, gfx->width(), gfx->height(), COLOR_BLACK);
  gfx->drawFastHLine(0, gfx->height() / 2, gfx->width(), COLOR_BLACK);
  gfx->drawFastVLine(gfx->width() / 2, 0, gfx->height(), COLOR_BLACK);
  gfx->setCursor(10, 10);
  gfx->setTextColor(COLOR_BLACK);
  gfx->setTextSize(3);
  gfx->printf("0x%04X", color);
  TEST_SERIAL.printf("fill 0x%04X width=%d height=%d\n", color, gfx->width(),
                     gfx->height());
}
