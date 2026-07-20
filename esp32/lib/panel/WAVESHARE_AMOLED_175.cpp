/**
 * @file WAVESHARE_AMOLED_175.cpp
 * @brief Waveshare AMOLED (CO5300) implementation for IceNav using Arduino_GFX.
 * Shared by the 1.75 and 2.06 variants.
 */

#include "WAVESHARE_AMOLED_175.hpp"

#ifdef USE_ARDUINO_GFX

#include <cstring>

// Include HAL for pin definitions
#include "../../include/hal.hpp"
#include "display.hpp"
#include "i2c_bus.hpp"
#include "touch.hpp"
#include "waveshare_board.hpp"

extern void appDisplayFlushCompleted();

// Define Global Variables declared extern in hal.hpp
uint8_t GPS_TX = GPIO_NUM_43;
uint8_t GPS_RX = GPIO_NUM_44;

// ============================================================================
// DISPLAY CONFIGURATION (Arduino_GFX)
// ============================================================================

// QSPI Bus for CO5300.
Arduino_ESP32QSPI *bus = new Arduino_ESP32QSPI(TFT_QSPI_CS,  // CS
                                               TFT_QSPI_CLK, // SCK
                                               TFT_QSPI_D0,  // D0
                                               TFT_QSPI_D1,  // D1
                                               TFT_QSPI_D2,  // D2
                                               TFT_QSPI_D3   // D3
);

// CO5300 Display Driver. Match the vendor dimensions and panel gap for the
// selected Waveshare AMOLED variant.
Arduino_CO5300 *gfx = new Arduino_CO5300(bus,
                                         TFT_QSPI_RST, // RST
                                         0,  // Rotation
                                         waveshare_board::display::
                                             LOGICAL_WIDTH,
                                         waveshare_board::display::
                                             LOGICAL_HEIGHT,
                                         waveshare_board::display::
                                             ARDUINO_CO5300_COL_OFFSET1,
                                         waveshare_board::display::
                                             ARDUINO_CO5300_ROW_OFFSET1,
                                         waveshare_board::display::
                                             ARDUINO_CO5300_COL_OFFSET2,
                                         waveshare_board::display::
                                             ARDUINO_CO5300_ROW_OFFSET2);

// ============================================================================
// LVGL 9 DISPLAY BUFFER
// ============================================================================

extern lv_display_t *display;
static lv_color_t *disp_draw_buf = NULL;
static lv_color_t *disp_rotation_buf = NULL;
static uint8_t displayRotation = waveshare_board::display::DEFAULT_ROTATION;
volatile uint32_t displayFlushCount = 0;
volatile uint32_t lastDisplayFlushMs = 0;
volatile uint32_t lastDisplayFlushDurationUs = 0;
volatile uint32_t maxDisplayFlushDurationUs = 0;

static uint8_t sanitizeDisplayRotation(uint8_t requestedRotation) {
  using namespace waveshare_board::display;

  if (requestedRotation > MAX_SUPPORTED_ROTATION) {
    Serial.printf("CO5300: unsupported display rotation %u, using 0\n",
                  requestedRotation);
    return ROTATION_0;
  }

  if (requestedRotation == ROTATION_90 && !ROTATION_90_ENABLED) {
    Serial.println("CO5300: 90-degree display rotation is only enabled for "
                   "the 1.75-inch target; using 0");
    return ROTATION_0;
  }

  return requestedRotation;
}

static void applyCo5300Rotation(uint8_t rotation) {
  using namespace waveshare_board::display;

  Serial.printf("CO5300: logical=%ux%u active=%ux%u constructorGap=(%u,%u,%u,%u) "
                "rotation=%u rotation90Enabled=%d method=%s\n",
                LOGICAL_WIDTH, LOGICAL_HEIGHT, ACTIVE_WIDTH, ACTIVE_HEIGHT,
                ARDUINO_CO5300_COL_OFFSET1, ARDUINO_CO5300_ROW_OFFSET1,
                ARDUINO_CO5300_COL_OFFSET2, ARDUINO_CO5300_ROW_OFFSET2,
                rotation, ROTATION_90_ENABLED ? 1 : 0,
                rotation == ROTATION_90 ? "LVGL software" : "native");

  // Keep the CO5300 in its vendor-verified native orientation. Raw MADCTL MV
  // rotation swaps the controller axes without swapping Arduino_GFX's hidden
  // 480x480 RAM offsets, exposing clipped pixels along two physical edges.
  // The 1.75-inch target is square, so rotate each LVGL flush in software while
  // retaining the known-good 466x466 window and 6 px column gap.
  gfx->setRotation(0);
}

#ifdef WAVESHARE_DISPLAY_TEST
static void drawVendorWindowMarker(uint8_t rotation, uint16_t fillColor,
                                   uint16_t borderColor) {
  using namespace waveshare_board::display;

  gfx->fillScreen(0x0000);
  gfx->fillRect(0, 0, ACTIVE_WIDTH, ACTIVE_HEIGHT, fillColor);
  gfx->drawRect(0, 0, ACTIVE_WIDTH, ACTIVE_HEIGHT, borderColor);
  gfx->drawRect(1, 1, ACTIVE_WIDTH - 2, ACTIVE_HEIGHT - 2, borderColor);
  gfx->drawFastHLine(0, ACTIVE_HEIGHT / 2, ACTIVE_WIDTH, 0x8410);
  gfx->drawFastVLine(ACTIVE_WIDTH / 2, 0, ACTIVE_HEIGHT, 0x8410);
  gfx->fillRect(0, 0, 24, 24, 0xF800);
  gfx->fillRect(ACTIVE_WIDTH - 24, 0, 24, 24, 0x07E0);
  gfx->fillRect(0, ACTIVE_HEIGHT - 24, 24, 24, 0x001F);
  gfx->fillRect(ACTIVE_WIDTH - 24, ACTIVE_HEIGHT - 24, 24, 24, 0xFFE0);
  Serial.printf("CO5300 display test: rotation=%u vendorGap=(%u,%u,%u,%u) "
                "active=%ux%u fill=0x%04X\n",
                rotation, ARDUINO_CO5300_COL_OFFSET1,
                ARDUINO_CO5300_ROW_OFFSET1, ARDUINO_CO5300_COL_OFFSET2,
                ARDUINO_CO5300_ROW_OFFSET2, ACTIVE_WIDTH, ACTIVE_HEIGHT,
                fillColor);
}

static void drawDisplayTestPatterns(uint8_t appliedRotation) {
  // Direct Arduino_GFX diagnostics intentionally remain in the native panel
  // orientation. The requested target rotation is applied later to LVGL flushes.
  applyCo5300Rotation(appliedRotation);
  const uint16_t fills[] = {0x0000, 0xFFFF, 0xF800, 0x07E0, 0x001F};
  for (uint16_t fill : fills) {
    drawVendorWindowMarker(waveshare_board::display::ROTATION_0, fill, 0xFFFF);
    delay(2500);
  }
#ifdef WAVESHARE_DISPLAY_PROBE
  drawVendorWindowMarker(waveshare_board::display::ROTATION_0, 0x001F,
                         0xFFFF);
#else
  gfx->fillScreen(0x0000);
#endif
}
#endif

// ============================================================================
// LVGL 9 DISPLAY FLUSH CALLBACK
// Using low-level methods for proper partial update handling
// ============================================================================

void my_disp_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map) {
  uint32_t startUs = micros();
  uint32_t w = (area->x2 - area->x1 + 1);
  uint32_t h = (area->y2 - area->y1 + 1);
  uint16_t *pixels = reinterpret_cast<uint16_t *>(px_map);
  int32_t targetX = area->x1;
  int32_t targetY = area->y1;
  uint32_t targetW = w;
  uint32_t targetH = h;

  if (displayRotation == waveshare_board::display::ROTATION_90) {
    if (disp_rotation_buf == NULL) {
      Serial.println("ERROR: missing LVGL software-rotation buffer");
      lv_display_flush_ready(disp);
      return;
    }

    // Rotate the packed RGB565 update 90 degrees clockwise, matching the prior
    // MADCTL orientation. This also handles partial areas if the render mode
    // changes in the future.
    targetX = SCREEN_HEIGHT - area->y2 - 1;
    targetY = area->x1;
    targetW = h;
    targetH = w;
    lv_draw_sw_rotate(px_map, disp_rotation_buf, w, h,
                      w * sizeof(uint16_t), targetW * sizeof(uint16_t),
                      LV_DISPLAY_ROTATION_270, LV_COLOR_FORMAT_RGB565);
    pixels = reinterpret_cast<uint16_t *>(disp_rotation_buf);
  }

  gfx->startWrite();
  gfx->writeAddrWindow(targetX, targetY, targetW, targetH);
  gfx->writePixels(pixels, targetW * targetH);
  gfx->endWrite();

#ifdef WAVESHARE_AMOLED_206
  // The 2.06-inch CO5300 presents the completed frame after a following window
  // write. Rewriting the first framebuffer pixel commits it without changing
  // the rendered image and leaves Arduino_GFX ready to resend the full window.
  gfx->fillRect(area->x1, area->y1, 1, 1,
                reinterpret_cast<uint16_t *>(px_map)[0]);
#endif

  // Notify application policy only after the physical panel write (including
  // the 2.06-inch commit write) has completed.
  appDisplayFlushCompleted();

  // Inform LVGL 9 that flushing is complete
  lv_display_flush_ready(disp);
  uint32_t durationUs = micros() - startUs;
  displayFlushCount++;
  lastDisplayFlushMs = millis();
  lastDisplayFlushDurationUs = durationUs;
  if (durationUs > maxDisplayFlushDurationUs) {
    maxDisplayFlushDurationUs = durationUs;
  }
}

// ============================================================================
// TOUCH DRIVER
// 1.75: CST9217 reset through TCA9554. 2.06: FT3168 direct reset GPIO.
// ============================================================================

bool touchPressed = false;
uint16_t touchX = 0, touchY = 0;

#ifdef WAVESHARE_AMOLED_206

static bool touchInitialized = false;
static bool touchHintConfigured = false;
static uint32_t lastTouchInitAttemptMs = 0;
static uint32_t lastTouchReadMs = 0;
static uint32_t touchBackoffUntilMs = 0;
static uint32_t lastTouchErrorLogMs = 0;
static uint32_t lastTouchDebugLogMs = 0;
static uint32_t lastValidTouchMs = 0;
static uint32_t touchFastPollUntilMs = 0;
static bool lastTouchHintActive = false;
static bool touchHintStateKnown = false;
static uint8_t consecutiveTouchReadFailures = 0;

static bool isValidTouchCoordinate(uint16_t x, uint16_t y) {
  return x < waveshare_board::touch::ACTIVE_WIDTH &&
         y < waveshare_board::touch::ACTIVE_HEIGHT;
}

static void setTouchPressed(bool pressed) {
  if (pressed != touchPressed) {
    if (pressed) {
      Serial.printf("Touch: press x=%u y=%u\n", touchX, touchY);
    } else {
      Serial.println("Touch: release");
    }
  }
  touchPressed = pressed;
}

static void configureTouchHintPin() {
  if (touchHintConfigured) {
    return;
  }
  pinMode(waveshare_board::touch::FT3168_INT_PIN, INPUT_PULLUP);
  touchHintConfigured = true;
}

static bool isTouchHintActive() {
  configureTouchHintPin();
  return digitalRead(waveshare_board::touch::FT3168_INT_PIN) == LOW;
}

static void updateTouchHintState(bool active, uint32_t now) {
  bool changed = !touchHintStateKnown || active != lastTouchHintActive;
  bool heartbeat = now - lastTouchDebugLogMs > 10000;
  if (changed || heartbeat) {
    Serial.printf("Touch debug: init=%d ft3168_int=%s pressed=%d\n",
                  touchInitialized, active ? "LOW(active)" : "HIGH(idle)",
                  touchPressed);
    lastTouchDebugLogMs = now;
  }
  lastTouchHintActive = active;
  touchHintStateKnown = true;
  if (changed && active) {
    touchFastPollUntilMs =
        now + waveshare_board::touch::HINT_FAST_POLL_WINDOW_MS;
  }
}

static uint32_t touchReadInterval(bool hintActive, uint32_t now) {
  if (hintActive) {
    return waveshare_board::touch::HINT_ACTIVE_READ_INTERVAL_MS;
  }
  if (touchPressed) {
    return waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
  }
  if (now < touchFastPollUntilMs) {
    return waveshare_board::touch::FAST_FALLBACK_READ_INTERVAL_MS;
  }
  return waveshare_board::touch::IDLE_FALLBACK_READ_INTERVAL_MS;
}

static void noteTouchReadFailure(const char *reason, uint32_t now) {
  consecutiveTouchReadFailures++;
  if (now - lastTouchErrorLogMs > 5000) {
    Serial.printf("Touch read failed: %s (failures=%u)\n", reason,
                  consecutiveTouchReadFailures);
    lastTouchErrorLogMs = now;
  }
  if (touchPressed &&
      now - lastValidTouchMs < waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
    touchBackoffUntilMs =
        now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
    return;
  }
  setTouchPressed(false);
  touchBackoffUntilMs = now + 250;
  if (consecutiveTouchReadFailures >= 5) {
    touchInitialized = false;
    touchBackoffUntilMs = now + waveshare_board::touch::REINIT_BACKOFF_MS;
    consecutiveTouchReadFailures = 0;
  }
}

void initTouchController() {
  if (touchInitialized) {
    return;
  }

  uint32_t now = millis();
  if (lastTouchInitAttemptMs != 0 && now - lastTouchInitAttemptMs < 5000) {
    return;
  }
  lastTouchInitAttemptMs = now;
  configureTouchHintPin();

  pinMode(waveshare_board::touch::FT3168_RST_PIN, OUTPUT);
  digitalWrite(waveshare_board::touch::FT3168_RST_PIN, HIGH);
  delay(1);
  digitalWrite(waveshare_board::touch::FT3168_RST_PIN, LOW);
  delay(20);
  digitalWrite(waveshare_board::touch::FT3168_RST_PIN, HIGH);
  delay(50);

  if (!waveshare_board::i2c::probe(waveshare_board::touch::FT3168_ADDR,
                                   "FT3168", 3)) {
    Serial.println("FT3168: not found");
    return;
  }

  uint8_t deviceId = 0;
  if (waveshare_board::i2c::readRegister8(
          waveshare_board::touch::FT3168_ADDR,
          waveshare_board::touch::FT3168_DEVICE_ID_REG, deviceId, "FT3168")) {
    Serial.printf("FT3168: found deviceId=0x%02X\n", deviceId);
  } else {
    Serial.println("FT3168: found");
  }

  waveshare_board::i2c::writeRegister8(
      waveshare_board::touch::FT3168_ADDR,
      waveshare_board::touch::FT3168_POWER_MODE_REG,
      waveshare_board::touch::FT3168_MONITOR_MODE, "FT3168 power", 3);
  touchInitialized = true;
}

void readTouch() {
  uint32_t now = millis();
  bool touchHintActive = isTouchHintActive();
  updateTouchHintState(touchHintActive, now);

  if (now < touchBackoffUntilMs) {
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      return;
    }
    setTouchPressed(false);
    return;
  }

  if (!touchInitialized) {
    initTouchController();
    if (!touchInitialized) {
      setTouchPressed(false);
      return;
    }
  }

  if (!touchHintActive && !touchPressed && now >= touchFastPollUntilMs) {
    setTouchPressed(false);
    return;
  }

  if (now - lastTouchReadMs < touchReadInterval(touchHintActive, now)) {
    return;
  }
  lastTouchReadMs = now;

  uint8_t data[waveshare_board::touch::FT3168_TOUCH_DATA_LENGTH] = {0};
  if (!waveshare_board::i2c::readRegisterBlock8(
          waveshare_board::touch::FT3168_ADDR,
          waveshare_board::touch::FT3168_FINGER_REG, data, sizeof(data),
          "FT3168 touch")) {
    noteTouchReadFailure("data read", now);
    return;
  }
  consecutiveTouchReadFailures = 0;

  uint8_t points = data[0] & 0x0F;
  if (points == 0) {
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }

  uint16_t rawX = ((data[1] & 0x0F) << 8) | data[2];
  uint16_t rawY = ((data[3] & 0x0F) << 8) | data[4];
  if (!isValidTouchCoordinate(rawX, rawY)) {
    Serial.printf("Touch raw: ignored-invalid raw=(%u,%u) bytes=%02X %02X "
                  "%02X %02X %02X\n",
                  rawX, rawY, data[0], data[1], data[2], data[3], data[4]);
    setTouchPressed(false);
    return;
  }

  touchX = rawX;
  touchY = rawY;
  lastValidTouchMs = now;
  touchFastPollUntilMs =
      now + waveshare_board::touch::TOUCH_FAST_POLL_WINDOW_MS;
  setTouchPressed(true);
}

#else

static bool touchInitialized = false;
static bool touchHintConfigured = false;
static uint32_t lastTouchInitAttemptMs = 0;
static uint32_t lastTouchReadMs = 0;
static uint32_t touchBackoffUntilMs = 0;
static uint32_t lastTouchErrorLogMs = 0;
static uint32_t lastTouchDebugLogMs = 0;
static uint32_t lastTouchRawLogMs = 0;
static uint32_t touchFastPollUntilMs = 0;
static uint32_t lastValidTouchMs = 0;
static uint32_t lastTouchHintActiveMs = 0;
static uint32_t lastTouchHintChangeMs = 0;
static uint8_t consecutiveTouchReadFailures = 0;
static uint8_t tca9554OutputShadow = 0xFF;
static uint8_t tca9554ConfigShadow = 0xFF;
static bool lastTouchHintActive = false;
static bool touchHintStateKnown = false;

static bool isValidTouchCoordinate(uint16_t x, uint16_t y) {
  return x < waveshare_board::touch::ACTIVE_WIDTH &&
         y < waveshare_board::touch::ACTIVE_HEIGHT;
}

static bool readCst9217Register(uint16_t reg, uint8_t *data, uint8_t len) {
  return waveshare_board::i2c::readRegister16(
      waveshare_board::touch::CST9217_ADDR, reg, data, len, "CST9217");
}

static void logTouchPacket(const char *label, const uint8_t *data,
                           uint8_t length, uint16_t rawX, uint16_t rawY,
                           bool interruptActive, uint32_t now) {
  bool isPoint = strncmp(label, "point", 5) == 0;
  uint32_t minInterval = isPoint ? 1000 : 10000;
  if (now - lastTouchRawLogMs <= minInterval) {
    return;
  }

  Serial.printf("Touch raw: %s raw=(%u,%u) int=%s bytes=", label, rawX, rawY,
                interruptActive ? "LOW(active)" : "HIGH(idle)");
  for (uint8_t i = 0; i < length && i < 7; i++) {
    Serial.printf("%02X", data[i]);
    if (i + 1 < length && i < 6) {
      Serial.print(" ");
    }
  }
  Serial.println();
  lastTouchRawLogMs = now;
}

static void setTouchPressed(bool pressed) {
  if (pressed != touchPressed) {
    if (pressed) {
      Serial.printf("Touch: press x=%u y=%u\n", touchX, touchY);
    } else {
      Serial.println("Touch: release");
    }
  }
  touchPressed = pressed;
}

static void configureTouchHintPin() {
  if (touchHintConfigured) {
    return;
  }

  pinMode(waveshare_board::touch::CST9217_INT_PIN, INPUT_PULLUP);
  touchHintConfigured = true;
}

static bool isTouchHintActive() {
  configureTouchHintPin();
  return digitalRead(waveshare_board::touch::CST9217_INT_PIN) == LOW;
}

static bool updateTouchHintState(bool active, uint32_t now) {
  bool changed = !touchHintStateKnown || active != lastTouchHintActive;
  bool heartbeat = now - lastTouchDebugLogMs > 10000;

  if (active) {
    lastTouchHintActiveMs = now;
  }
  if (changed) {
    lastTouchHintChangeMs = now;
    if (active) {
      touchFastPollUntilMs =
          now + waveshare_board::touch::HINT_FAST_POLL_WINDOW_MS;
    }
  }

  if (changed || heartbeat) {
    uint32_t msSinceHintChange =
        lastTouchHintChangeMs == 0 ? 0 : now - lastTouchHintChangeMs;
    Serial.printf("Touch debug: init=%d int=%s pressed=%d hint_age_ms=%lu\n",
                  touchInitialized, active ? "LOW(active)" : "HIGH(idle)",
                  touchPressed, static_cast<unsigned long>(msSinceHintChange));
    lastTouchDebugLogMs = now;
    lastTouchHintActive = active;
    touchHintStateKnown = true;
  }

  return changed;
}

static uint32_t idleFailureRetryMs() {
  uint32_t retryMs = waveshare_board::touch::IDLE_FAILURE_BASE_RETRY_MS;
  if (consecutiveTouchReadFailures > 1) {
    retryMs += static_cast<uint32_t>(consecutiveTouchReadFailures - 1) * 75;
  }
  if (retryMs > waveshare_board::touch::IDLE_FAILURE_MAX_RETRY_MS) {
    retryMs = waveshare_board::touch::IDLE_FAILURE_MAX_RETRY_MS;
  }
  return retryMs;
}

static uint32_t touchReadInterval(bool hintActive, bool hintChanged,
                                  uint32_t now) {
  if (hintChanged && hintActive) {
    return 0;
  }
  if (hintActive) {
    return waveshare_board::touch::HINT_ACTIVE_READ_INTERVAL_MS;
  }
  if (touchPressed) {
    return waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
  }
  if (lastTouchHintActiveMs != 0 &&
      now - lastTouchHintActiveMs <
          waveshare_board::touch::HINT_FAST_POLL_WINDOW_MS) {
    return waveshare_board::touch::RECENT_HINT_READ_INTERVAL_MS;
  }
  if (now < touchFastPollUntilMs) {
    return waveshare_board::touch::FAST_FALLBACK_READ_INTERVAL_MS;
  }
  return waveshare_board::touch::IDLE_FALLBACK_READ_INTERVAL_MS;
}

static void noteTouchReadFailure(const char *reason, uint32_t now) {
  consecutiveTouchReadFailures++;

  if (now - lastTouchErrorLogMs > 5000) {
    Serial.printf("Touch read failed: %s (failures=%u)\n", reason,
                  consecutiveTouchReadFailures);
    lastTouchErrorLogMs = now;
  }

  if (touchPressed &&
      now - lastValidTouchMs < waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
    touchBackoffUntilMs =
        now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
    return;
  }

  if (!touchPressed) {
    touchBackoffUntilMs = now + idleFailureRetryMs();
    if (consecutiveTouchReadFailures > 20) {
      consecutiveTouchReadFailures = 0;
    }
    return;
  }

  setTouchPressed(false);
  touchBackoffUntilMs = now + 250;
  if (consecutiveTouchReadFailures >= 5) {
    touchInitialized = false;
    touchBackoffUntilMs = now + waveshare_board::touch::REINIT_BACKOFF_MS;
    consecutiveTouchReadFailures = 0;
  }
}

// TCA9554 helper functions
static bool tca9554SetPin(uint8_t pin, bool level) {
  if (level) {
    tca9554OutputShadow |= (1 << pin);
  } else {
    tca9554OutputShadow &= ~(1 << pin);
  }

  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, waveshare_board::touch::TCA9554_OUTPUT_REG,
      tca9554OutputShadow, "TCA9554");
}

static bool tca9554ConfigureOutput(uint8_t pin) {
  tca9554ConfigShadow &= ~(1 << pin); // Clear bit = Output

  return waveshare_board::i2c::writeRegister8(
      waveshare_board::TCA9554_ADDR, waveshare_board::touch::TCA9554_CONFIG_REG,
      tca9554ConfigShadow, "TCA9554");
}

void initTouchController() {
  if (touchInitialized)
    return;

  uint32_t now = millis();
  if (lastTouchInitAttemptMs != 0 && now - lastTouchInitAttemptMs < 5000) {
    return;
  }
  lastTouchInitAttemptMs = now;
  configureTouchHintPin();

  // Check for TCA9554 and reset touch controller
  if (waveshare_board::i2c::probe(waveshare_board::TCA9554_ADDR, "TCA9554")) {
    Serial.println("✓ TCA9554 found - resetting touch controller");
    bool resetOk =
        tca9554ConfigureOutput(waveshare_board::touch::TCA9554_TOUCH_RST_BIT);
    resetOk =
        tca9554SetPin(waveshare_board::touch::TCA9554_TOUCH_RST_BIT, false) &&
        resetOk; // RST low
    delay(20);
    resetOk =
        tca9554SetPin(waveshare_board::touch::TCA9554_TOUCH_RST_BIT, true) &&
        resetOk; // RST high
    delay(100); // Wait for touch controller to boot
    touchInitialized = resetOk;
    if (!resetOk) {
      Serial.println("Touch reset failed through TCA9554");
    }
  } else {
    Serial.println("✗ TCA9554 not found - touch may not work");
  }
}

void readTouch() {
  uint32_t now = millis();
  bool touchHintActive = isTouchHintActive();
  bool touchHintChanged = updateTouchHintState(touchHintActive, now);

  if (now < touchBackoffUntilMs && !(touchHintChanged && touchHintActive)) {
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      return;
    }
    setTouchPressed(false);
    return;
  }

  // Initialize touch on first read
  if (!touchInitialized) {
    initTouchController();
    if (!touchInitialized) {
      setTouchPressed(false);
      return;
    }
  }

  uint32_t readInterval =
      touchReadInterval(touchHintActive, touchHintChanged, now);
  if (now - lastTouchReadMs < readInterval) {
    return;
  }
  lastTouchReadMs = now;

  uint8_t data[waveshare_board::touch::CST9217_DATA_LENGTH] = {0};
  if (!readCst9217Register(waveshare_board::touch::CST9217_DATA_REG, data,
                           sizeof(data))) {
    noteTouchReadFailure("data read", now);
    return;
  }
  consecutiveTouchReadFailures = 0;

  if (data[6] != waveshare_board::touch::CST9217_ACK) {
    logTouchPacket("ignored-no-ack", data, sizeof(data), 0, 0,
                   touchHintActive, now);
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }

  uint8_t points = data[5] & 0x7F;
  if (points == 0) {
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }

  uint8_t status = data[0] & 0x0F;
  uint16_t rawX = (data[1] << 4) | (data[3] >> 4);
  uint16_t rawY = (data[2] << 4) | (data[3] & 0x0F);
  if (status != 0x00 && status != 0x06) {
    logTouchPacket("ignored-status", data, sizeof(data), rawX, rawY,
                   touchHintActive, now);
    if (touchPressed && now - lastValidTouchMs <
                            waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
      touchBackoffUntilMs =
          now + waveshare_board::touch::ACTIVE_READ_INTERVAL_MS;
      return;
    }
    setTouchPressed(false);
    return;
  }
  if (!isValidTouchCoordinate(rawX, rawY)) {
    logTouchPacket("ignored-invalid", data, sizeof(data), rawX, rawY,
                   touchHintActive, now);
    setTouchPressed(false);
    return;
  }

  bool moved = rawX != touchX || rawY != touchY;
  if (status == 0x00 && !touchPressed) {
    logTouchPacket("ignored-stale-start", data, sizeof(data), rawX, rawY,
                   touchHintActive, now);
    setTouchPressed(false);
    return;
  }
  if (status == 0x00 && !moved &&
      now - lastValidTouchMs >= waveshare_board::touch::ACTIVE_FAILURE_GRACE_MS) {
    setTouchPressed(false);
    return;
  }

  touchX = rawX;
  touchY = rawY;
  if (status == 0x06 || moved) {
    lastValidTouchMs = now;
  }
  touchFastPollUntilMs =
      now + waveshare_board::touch::TOUCH_FAST_POLL_WINDOW_MS;
  logTouchPacket(status == 0x06 ? "point" : "point-status0", data,
                 sizeof(data), touchX, touchY, touchHintActive, now);

  // Clamp to screen bounds
  if (touchX >= waveshare_board::touch::ACTIVE_WIDTH)
    touchX = waveshare_board::touch::MAX_X;
  if (touchY >= waveshare_board::touch::ACTIVE_HEIGHT)
    touchY = waveshare_board::touch::MAX_Y;

  setTouchPressed(true);
}

#endif // WAVESHARE_AMOLED_206

void my_touchpad_read(lv_indev_t *indev_driver, lv_indev_data_t *data) {
  readTouch();

  if (touchPressed) {
    data->state = LV_INDEV_STATE_PRESSED;
    // Rotate touch coordinates to match display rotation
    uint16_t rotatedX = touchX;
    uint16_t rotatedY = touchY;
    switch (displayRotation) {
    case 1: // Inverse of the clockwise framebuffer rotation
      rotatedX = touchY;
      rotatedY = waveshare_board::touch::MAX_Y - touchX;
      break;
    case 2: // 180°: flip both
      rotatedX = waveshare_board::touch::MAX_X - touchX;
      rotatedY = waveshare_board::touch::MAX_Y - touchY;
      break;
    case 3: // 270° CCW: swap X/Y and flip new Y
      rotatedX = waveshare_board::touch::MAX_X - touchY;
      rotatedY = touchX;
      break;
    }
    data->point.x = rotatedX;
    data->point.y = rotatedY;
  } else {
    data->state = LV_INDEV_STATE_RELEASED;
  }
}

// ============================================================================
// DISPLAY SETUP FUNCTIONS
// ============================================================================

void setupDisplay() {
  Serial.println("Initializing Arduino_GFX display...");

  // Initialize display
  gfx->begin();
  delay(100); // Let display stabilize

  // Rotation is a hardware-target choice. The square 1.75-inch device boots
  // at 90 degrees; the rectangular 2.06-inch device remains at 0 degrees.
  // Ignore legacy NVS values written by older versions of the iOS app.
  uint8_t rotation = sanitizeDisplayRotation(
      waveshare_board::display::DEFAULT_ROTATION);
  displayRotation = rotation; // Store globally for touch coordinate rotation
  Serial.printf("Loaded target display rotation: %u\n", rotation);

  // ============================================================================
  // DISPLAY ROTATION
  // ============================================================================
  // Arduino_GFX's CO5300 driver does not support axis-swapping rotation. Keep
  // the controller at the vendor-verified native orientation and rotate the
  // 1.75-inch target's LVGL framebuffer during flush instead. The rectangular
  // 2.06-inch target remains native.
  applyCo5300Rotation(rotation);

  // Turn on display and set brightness (CRITICAL for AMOLED!)
  Serial.println("Turning on display and setting brightness...");
  gfx->displayOn();
  delay(50);
  gfx->setBrightness(255); // Maximum brightness 0-255
  delay(50);

#ifdef WAVESHARE_DISPLAY_TEST
  drawDisplayTestPatterns(rotation);
#endif

  // Clear screen for LVGL
  gfx->fillScreen(0x0000); // BLACK
  Serial.println("Arduino_GFX display ready");
}

void setupLVGLforArduinoGFX() {
  Serial.println("Initializing LVGL 9 with Arduino_GFX...");

  lv_init();

  // Create display using LVGL 9 API
  display = lv_display_create(SCREEN_WIDTH, SCREEN_HEIGHT);
  if (display == NULL) {
    Serial.println("ERROR: LVGL display creation failed!");
    while (1)
      delay(1000);
  }

  // Set flush callback
  lv_display_set_flush_cb(display, my_disp_flush);

  // Allocate FULL SCREEN buffer to avoid stripe artifacts at partial flush
  // boundaries With PSRAM available, we can afford the full 466x466x2 = 434312
  // bytes
  size_t bufSize = SCREEN_WIDTH * SCREEN_HEIGHT; // Full screen
#ifdef BOARD_HAS_PSRAM
  Serial.printf("DEBUG: LV_COLOR_DEPTH=%d, sizeof(lv_color_t)=%d (Using "
                "RGB565=2 bytes)\n",
                LV_COLOR_DEPTH, sizeof(lv_color_t));
  Serial.printf("Allocating FULL SCREEN LVGL buffer: %d bytes (using PSRAM)\n",
                bufSize * sizeof(uint16_t)); // Use 2 bytes for RGB565!
  // Allocate full screen buffer from PSRAM
  disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
      16, bufSize * sizeof(uint16_t), MALLOC_CAP_SPIRAM); // RGB565 = 2 bytes
  if (!disp_draw_buf) {
    Serial.println("PSRAM allocation failed, trying internal RAM...");
    bufSize =
        SCREEN_WIDTH * SCREEN_HEIGHT / 10; // Smaller buffer for internal RAM
    disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
        16, bufSize * sizeof(uint16_t), // RGB565 = 2 bytes
        MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  }
#else
  bufSize = SCREEN_WIDTH * SCREEN_HEIGHT / 10;
  Serial.printf("Allocating LVGL buffer: %d bytes (internal RAM)\n",
                bufSize * sizeof(uint16_t)); // RGB565 = 2 bytes
  disp_draw_buf = (lv_color_t *)heap_caps_aligned_alloc(
      16, bufSize * sizeof(uint16_t),
      MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT); // RGB565 = 2 bytes
#endif

  if (!disp_draw_buf) {
    Serial.println("ERROR: LVGL buffer allocation failed!");
    while (1)
      delay(1000); // Halt - this is fatal
  }

  Serial.printf("✓ LVGL buffer allocated: %d bytes\n",
                bufSize * sizeof(uint16_t)); // RGB565 = 2 bytes

  if (displayRotation == waveshare_board::display::ROTATION_90) {
    const size_t rotationBufSize =
        SCREEN_WIDTH * SCREEN_HEIGHT * sizeof(uint16_t);
    disp_rotation_buf = (lv_color_t *)heap_caps_aligned_alloc(
        16, rotationBufSize, MALLOC_CAP_SPIRAM);
    if (!disp_rotation_buf) {
      Serial.println("ERROR: LVGL software-rotation buffer allocation failed!");
      while (1)
        delay(1000); // A native framebuffer would have the wrong orientation.
    }
    Serial.printf("✓ LVGL software-rotation buffer allocated: %u bytes\n",
                  static_cast<unsigned>(rotationBufSize));
  }

  // FORCE Display Color Format to RGB565
  lv_display_set_color_format(display, LV_COLOR_FORMAT_RGB565);
  Serial.printf("Display Color Format set to: %d (RGB565=%d)\n",
                lv_display_get_color_format(display), LV_COLOR_FORMAT_RGB565);

  // Set display buffers using LVGL 9 API - FULL mode to avoid stripe artifacts
  lv_display_set_buffers(display, disp_draw_buf, NULL,
                         bufSize * sizeof(uint16_t), // RGB565 = 2 bytes
                         LV_DISPLAY_RENDER_MODE_FULL);

  Serial.println("✓ LVGL 9 Display registered");

#ifndef DISABLE_TOUCH
  // Initialize touch driver using LVGL 9 API
  lv_indev_t *indev_drv = lv_indev_create();
  lv_indev_set_type(indev_drv, LV_INDEV_TYPE_POINTER);
  lv_indev_set_read_cb(indev_drv, my_touchpad_read);

  Serial.println("✓ LVGL 9 Touch driver registered");
#else
  Serial.println(
      "! TOUCH DISABLED via DISABLE_TOUCH flag (Required for SD Card usage)");
#endif
  Serial.println("LVGL 9 initialized with Arduino_GFX");
}

#endif // USE_ARDUINO_GFX
