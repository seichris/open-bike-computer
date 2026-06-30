/**
 * @file WAVESHARE_AMOLED_175.hpp
 * @brief Waveshare 1.75 AMOLED (CO5300) pin definition for IceNav
 */

#pragma once

#ifdef USE_ARDUINO_GFX
// Use Arduino_GFX for CO5300 AMOLED (like working esp32 project)
#include <Arduino_GFX_Library.h>
#include <lvgl.h>

// Display dimensions
#define SCREEN_WIDTH  466
#define SCREEN_HEIGHT 466

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
#define CST9217_ADDRESS 0x5A
extern bool touchPressed;
extern uint16_t touchX, touchY;

// Function declarations
void setupDisplay();
void setupLVGLforArduinoGFX();
void readTouch();

#else
// Use LovyanGFX for other displays
#define LGFX_USE_V1
#include <LovyanGFX.hpp>

// CO5300 AMOLED configuration using QSPI
class LGFX : public lgfx::LGFX_Device {
  lgfx::Panel_ILI9488 _panel_instance; // Use ILI9488 as base (QSPI compatible)
  lgfx::Bus_QSPI    _bus_instance;    // QSPI Bus for CO5300
  lgfx::Touch_CST816S _touch_instance; // Capacitive Touch
 
 public:
   LGFX(void) {
     {
       auto cfg = _bus_instance.config();
       cfg.freq_write = 40000000; // 40MHz QSPI
       cfg.freq_read  = 16000000;
       cfg.spi_3wire  = false;     // QSPI is 4-wire
       cfg.use_lock   = true;
       cfg.dma_channel = SPI_DMA_CH_AUTO;

       // Waveshare 1.75 QSPI Pinout (CO5300) - matches working project
       cfg.pin_sclk = 38;  // SCK
       cfg.pin_io0  = 4;   // D0
       cfg.pin_io1  = 5;   // D1
       cfg.pin_io2  = 6;   // D2
       cfg.pin_io3  = 7;   // D3

       _bus_instance.config(cfg);
       _panel_instance.setBus(&_bus_instance);
     }

     {
       auto cfg = _panel_instance.config();
       cfg.pin_cs           = 12;  // CS
       cfg.pin_rst          = 39;  // RST
       cfg.pin_busy         = -1;

       cfg.panel_width      = 450;  // Use 450x600 for ILI9488 compatibility
       cfg.panel_height     = 600;
       cfg.offset_x         = 0;
       cfg.offset_y         = 0;
       cfg.offset_rotation  = 0;
       cfg.dummy_read_pixel = 8;
       cfg.dummy_read_bits  = 1;
       cfg.readable         = false;
       cfg.invert           = false;
       cfg.rgb_order        = false;
       cfg.dlen_16bit       = false;
       cfg.bus_shared       = true;

       _panel_instance.config(cfg);
     }
 
     {
       auto cfg = _touch_instance.config();
       cfg.x_min      = 0;
       cfg.x_max      = 465;  // 466px width
       cfg.y_min      = 0;
       cfg.y_max      = 465;  // 466px height
       cfg.pin_int    = 21;
       cfg.pin_rst    = 20;
       cfg.bus_shared = true;
       cfg.i2c_port   = 0; // I2C Port 0
       cfg.i2c_addr   = 0x5A;  // CST9217 address (not CST816S)
       cfg.pin_sda    = 15;
       cfg.pin_scl    = 16;
       cfg.freq       = 400000;

       _touch_instance.config(cfg);
       _panel_instance.setTouch(&_touch_instance);
     }
 
     setPanel(&_panel_instance);
   }
 };
#endif // USE_ARDUINO_GFX
