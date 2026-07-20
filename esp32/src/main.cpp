/**
 * @file main.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ICENAV - ESP32 GPS Navigator main code
 * @version 0.2.2
 * @date 2025-05
 */

#include <Arduino.h>
#include <SPI.h>
#include <WiFi.h>
#include <Wire.h>
#include <esp_bt.h>
#include <esp_log.h>
#include <esp_system.h>
#include <esp_wifi.h>
#include <stdint.h>
#ifndef DISABLE_WEB_SERVER
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#endif
#include <SolarCalculator.h>

// Hardware includes
#include "gps.hpp"
#include "hal.hpp"
#include "storage.hpp"
#include "tft.hpp"

#ifdef HMC5883L
#include "compass.hpp"
#endif

#ifdef QMC5883
#include "compass.hpp"
#endif

#ifdef IMU_MPU9250
#include "compass.hpp"
#endif

#ifdef BME280
#include "bme.hpp"
#endif

#ifdef MPU6050
#include "imu.hpp"
#endif

#ifdef HAS_HARDWARE_GPS
extern xSemaphoreHandle gpsMutex;
#endif

#ifndef DISABLE_WEB_SERVER
#include "webpage.h"
#include "webserver.h"
#endif

#include "battery.hpp"
#include "gpxParser.hpp"
#include "power.hpp"

#include "maps.hpp"
#include "device_transfer_http.hpp"
#include "firmware_update_http.hpp"
#include "map_transfer.hpp"
#include "map_transfer_http.hpp"

// BLE Navigation for iOS route overlay
#include "ble_navigation.hpp"
#include "disconnected_shutdown_policy.hpp"
#include "ownership_button_policy.hpp"
#include "guiLayout.hpp"
#include "mainScr.hpp"
#include "route_overlay.hpp"
#include "waitingScr.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "WAVESHARE_AMOLED_175.hpp"
#include "axp2101.hpp"
#include "i2c_bus.hpp"
#include "pcf85063.hpp"
#include "qmi8658.hpp"
#include "speaker.hpp"
#include "waveshare_board.hpp"
#endif

extern Storage storage;
extern Battery battery;
extern Power power;
extern Maps mapView;
device_transfer::HttpTransferServer deviceTransferHttp;
map_transfer::MapTransferHttpServer mapTransferHttp;
firmware_update::FirmwareUpdateHttpServer firmwareUpdateHttp;

static lv_obj_t *mapActivationProgressPanel = nullptr;
static lv_obj_t *mapActivationProgressLabel = nullptr;
static lv_obj_t *mapActivationProgressBar = nullptr;

static void updateMapActivationProgressOverlay() {
  static uint32_t lastUpdateMs = 0;
  const uint32_t now = millis();
  if (now - lastUpdateMs < 250)
    return;
  lastUpdateMs = now;

  const map_transfer::MapActivationSnapshot activation =
      mapTransferHttp.activationSnapshot();
  if (!activation.running) {
    if (mapActivationProgressPanel != nullptr)
      lv_obj_add_flag(mapActivationProgressPanel, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  if (mapActivationProgressPanel == nullptr) {
    mapActivationProgressPanel = lv_obj_create(lv_layer_top());
    lv_obj_set_size(mapActivationProgressPanel, TFT_WIDTH - 32, 120);
    lv_obj_align(mapActivationProgressPanel, LV_ALIGN_BOTTOM_MID, 0, -24);
    lv_obj_set_style_bg_color(mapActivationProgressPanel,
                              lv_color_hex(0x101010), 0);
    lv_obj_set_style_bg_opa(mapActivationProgressPanel, 235, 0);
    lv_obj_set_style_border_color(mapActivationProgressPanel,
                                  lv_color_hex(0x4A90E2), 0);
    lv_obj_set_style_border_width(mapActivationProgressPanel, 2, 0);
    lv_obj_set_style_radius(mapActivationProgressPanel, 14, 0);
    lv_obj_set_style_pad_all(mapActivationProgressPanel, 14, 0);
    lv_obj_clear_flag(mapActivationProgressPanel, LV_OBJ_FLAG_SCROLLABLE);

    mapActivationProgressLabel = lv_label_create(mapActivationProgressPanel);
    lv_obj_set_style_text_font(mapActivationProgressLabel,
                               &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(mapActivationProgressLabel,
                                lv_color_white(), 0);
    lv_obj_set_width(mapActivationProgressLabel, LV_PCT(100));
    lv_obj_set_style_text_align(mapActivationProgressLabel,
                                LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(mapActivationProgressLabel, LV_ALIGN_TOP_MID, 0, -2);

    mapActivationProgressBar = lv_bar_create(mapActivationProgressPanel);
    lv_obj_set_size(mapActivationProgressBar, LV_PCT(100), 12);
    lv_obj_align(mapActivationProgressBar, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_bar_set_range(mapActivationProgressBar, 0, 100);
    lv_obj_set_style_bg_color(mapActivationProgressBar,
                              lv_color_hex(0x303030), LV_PART_MAIN);
    lv_obj_set_style_bg_color(mapActivationProgressBar,
                              lv_color_hex(0x4A90E2), LV_PART_INDICATOR);
  }

  lv_label_set_text_fmt(mapActivationProgressLabel,
                        "Map Upload Progress:\nStep %u - %u%%",
                        static_cast<unsigned>(activation.step),
                        static_cast<unsigned>(activation.progress));
  lv_bar_set_value(mapActivationProgressBar, activation.progress, LV_ANIM_OFF);
  lv_obj_clear_flag(mapActivationProgressPanel, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(mapActivationProgressPanel);
}

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
volatile bool waveshareBootScreenCyclePending = false;
static portMUX_TYPE waveshareBootButtonMux = portMUX_INITIALIZER_UNLOCKED;
static ownership_button_policy::FreshBootButtonGate waveshareBootPairingGate;
static bool waveshareBootWaitingForRelease = false;
static bool waveshareBootHandledPairingConfirmation = false;
static uint32_t waveshareBootReleaseStartMs = 0;
static uint32_t waveshareBootPressStartMs = 0;
static ownership_button_policy::FreshPowerButtonGate
    wavesharePowerPairingGate;
static uint32_t wavesharePowerPairingGeneration = 0;

// Called by the panel driver only after a frame has reached the display. This
// keeps physical confirmation disabled until the comparison code is visible.
void appDisplayFlushCompleted() {
  bleNavServer.noteOwnershipDisplayFlushCompleted();
}

static void IRAM_ATTR latchWaveshareBootScreenCycle() {
  portENTER_CRITICAL_ISR(&waveshareBootButtonMux);
  waveshareBootScreenCyclePending = true;
  portEXIT_CRITICAL_ISR(&waveshareBootButtonMux);
}

static bool takeWaveshareBootScreenCycle() {
  portENTER_CRITICAL(&waveshareBootButtonMux);
  const bool pending = waveshareBootScreenCyclePending;
  waveshareBootScreenCyclePending = false;
  portEXIT_CRITICAL(&waveshareBootButtonMux);
  return pending;
}

static void processWaveshareBootButton() {
  constexpr uint32_t DEBOUNCE_MS = 50;

  const uint32_t now = millis();
  const bool pressed = digitalRead(BOARD_BOOT_PIN) == LOW;
  const bool latchedPress = takeWaveshareBootScreenCycle();

  if (waveshareBootPairingGate.blocksInput(pressed, now, DEBOUNCE_MS)) {
    return;
  }

  if (!waveshareBootWaitingForRelease) {
    if (!latchedPress && !pressed) {
      return;
    }

    waveshareBootWaitingForRelease = true;
    waveshareBootHandledPairingConfirmation = false;
    waveshareBootReleaseStartMs = 0;
    waveshareBootPressStartMs = now;
    waveshareBootHandledPairingConfirmation =
        ownership_button_policy::handleShortPress(
            [] { return bleNavServer.confirmOwnershipPairing(); },
            [] {
              if (!bleNavServer.hasOwnershipPairingCode()) {
                toggleNavigationScreen();
              }
            });
    if (waveshareBootHandledPairingConfirmation) {
      log_i("Waveshare BOOT pressed; handled ownership pairing");
    } else if (bleNavServer.hasOwnershipPairingCode()) {
      log_i("Waveshare BOOT press ignored until comparison is ready");
    } else {
      log_i("Waveshare BOOT pressed; handling forward action");
    }
    return;
  }

  if (pressed) {
    waveshareBootReleaseStartMs = 0;
    return;
  }

  if (waveshareBootReleaseStartMs == 0) {
    waveshareBootReleaseStartMs = now;
    return;
  }

  if (now - waveshareBootReleaseStartMs < DEBOUNCE_MS) {
    return;
  }

  waveshareBootWaitingForRelease = false;
  const uint32_t pressDurationMs = now - waveshareBootPressStartMs;
  log_i("Waveshare BOOT released after %lu ms",
        static_cast<unsigned long>(pressDurationMs));
  if (ownership_button_policy::shouldRecoverOwner(
          pressDurationMs, waveshareBootHandledPairingConfirmation)) {
    if (bleNavServer.forgetOwner()) {
      log_i("Waveshare BOOT long press cleared the registered iPhone");
    } else {
      log_i("Waveshare BOOT long press: no registered iPhone to clear");
    }
  }
}

static void processWavesharePowerButton() {
  constexpr uint32_t POLL_INTERVAL_MS = 100;
  static uint32_t lastPollMs = 0;

  const uint32_t now = millis();
  if (now - lastPollMs < POLL_INTERVAL_MS) {
    return;
  }
  lastPollMs = now;

  waveshare_board::axp2101::PowerButtonEvents events;
  if (!waveshare_board::axp2101::readAndClearPowerButtonEvents(events)) {
    return;
  }

  if (bleNavServer.hasOwnershipPairingCode()) {
    if (wavesharePowerPairingGate.acceptEvents(
            wavesharePowerPairingGeneration, events.negativeEdge,
            events.positiveEdge, events.shortPress) &&
        bleNavServer.confirmOwnershipPairing()) {
      log_i("Waveshare PWR pressed; handled ownership pairing");
    }
    // Never honk while a pairing comparison is active, including before the
    // screen has flushed and the fresh-edge gate has been armed.
    return;
  }

  wavesharePowerPairingGate.cancel();
  wavesharePowerPairingGeneration = 0;
  if (events.shortPress) {
    waveshare_board::speaker::handlePowerButtonHonkPress();
  }
}

static void armOwnershipPairingAfterRenderedComparison() {
  uint32_t pairingGeneration = 0;
  if (!bleNavServer.ownershipPairingRenderedRequest(pairingGeneration)) {
    return;
  }

  // A registration can only consume input generated after this comparison
  // screen was rendered. Discard both hardware latches and require BOOT to be
  // observed released before its next press.
  (void)takeWaveshareBootScreenCycle();
  waveshareBootPairingGate.arm();
  waveshareBootWaitingForRelease = false;
  waveshareBootHandledPairingConfirmation = false;
  waveshareBootReleaseStartMs = 0;
  waveshareBootPressStartMs = 0;
  waveshare_board::axp2101::PowerButtonEvents stalePowerButtonEvents;
  if (!waveshare_board::axp2101::readAndClearPowerButtonEvents(
          stalePowerButtonEvents)) {
    return;
  }

  wavesharePowerPairingGate.arm(pairingGeneration);
  wavesharePowerPairingGeneration = pairingGeneration;
  if (bleNavServer.armOwnershipPairingConfirmation(pairingGeneration)) {
    log_i("Ownership pairing buttons armed after comparison render");
  } else {
    wavesharePowerPairingGate.cancel();
    wavesharePowerPairingGeneration = 0;
  }
}
#endif
extern Gps gps;
#ifdef ENABLE_COMPASS
Compass compass;
#endif

std::vector<wayPoint> trackData;

/**
 * @brief Sunrise and Sunset
 *
 */
static double transit, sunrise, sunset;
static uint32_t loopCount = 0;
static uint32_t lastLoopMs = 0;
static uint32_t maxLoopGapMs = 0;
static uint32_t lvglHandlerCount = 0;
static uint32_t lastLvglHandlerMs = 0;
static uint32_t lastLvglHandlerDurationUs = 0;
static uint32_t maxLvglHandlerDurationUs = 0;
#include "lvglSetup.hpp"
#include "settings.hpp"
#include "tasks.hpp"
#include "timezone.c"

/**
 * @brief Calculate Sunrise and Sunset
 *        Must be a global function
 *
 */
void calculateSun() {
  calcSunriseSunset(2000 + fix.dateTime.year, fix.dateTime.month,
                    fix.dateTime.date, gps.gpsData.latitude,
                    gps.gpsData.longitude, transit, sunrise, sunset);
  int hours = (int)sunrise + gps.gpsData.UTC;
  int minutes = (int)round(((sunrise + gps.gpsData.UTC) - hours) * 60);
  snprintf(gps.gpsData.sunriseHour, 6, "%02d:%02d", hours, minutes);
  hours = (int)sunset + gps.gpsData.UTC;
  minutes = (int)round(((sunset + gps.gpsData.UTC) - hours) * 60);
  snprintf(gps.gpsData.sunsetHour, 6, "%02d:%02d", hours, minutes);
  log_i("Sunrise: %s", gps.gpsData.sunriseHour);
  log_i("Sunset: %s", gps.gpsData.sunsetHour);
}

static const char *debugTileName(uint8_t tile) {
  switch (tile) {
  case COMPASS:
    return "COMPASS";
  case MAP:
    return "MAP";
  case MAP_GUIDANCE:
    return "MAP_GUIDANCE";
  case NAV:
    return "NAV";
  case SATTRACK:
    return "SATTRACK";
  case RIDESTATS:
    return "RIDESTATS";
  case BATTERY_STATUS:
    return "BATTERY_STATUS";
  default:
    return "UNKNOWN";
  }
}

static void logSystemDebugHeartbeat() {
  static uint32_t lastLogMs = 0;
  uint32_t now = millis();
  if (now - lastLogMs < 5000) {
    return;
  }
  lastLogMs = now;

  BLEDebugStats bleStats = bleNavServer.getDebugStats();
#if (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)) &&       \
    defined(WAVESHARE_IMU_DIAGNOSTICS)
  const waveshare_board::i2c::Stats &i2cStats = waveshare_board::i2c::stats();
  const waveshare_board::rtc::Status &rtcStatus =
      waveshare_board::rtc::status();
  const waveshare_board::imu::Status &imuStatus =
      waveshare_board::imu::status();
  const waveshare_board::imu::Sample &imuSample =
      waveshare_board::imu::lastSample();
#elif defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const waveshare_board::i2c::Stats &i2cStats = waveshare_board::i2c::stats();
  const waveshare_board::rtc::Status &rtcStatus =
      waveshare_board::rtc::status();
#endif
  const char *screenName = "unknown";
  lv_obj_t *activeScreen = lv_scr_act();
  if (activeScreen == waitingScreen) {
    screenName = "waiting";
  } else if (isMainScreen) {
    screenName = "main";
  }

#if (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)) &&       \
    defined(WAVESHARE_IMU_DIAGNOSTICS)
  Serial.printf("IMU: p=%d cfg=%d valid=%d addr=0x%02X n=%lu zero=%lu fail=%lu "
                "a=%.0f,%.0f,%.0f g=%.1f,%.1f,%.1f mag=%.0f vib=%.1f "
                "orient=%s moving=%d\n",
                imuStatus.present, imuStatus.configured, imuStatus.dataValid,
                imuStatus.address,
                (unsigned long)imuStatus.sampleCount,
                (unsigned long)imuStatus.zeroSamples,
                (unsigned long)imuStatus.failedReads, imuSample.accelMg[0],
                imuSample.accelMg[1], imuSample.accelMg[2],
                imuSample.gyroDps[0], imuSample.gyroDps[1],
                imuSample.gyroDps[2], imuStatus.accelMagnitudeMg,
                imuStatus.vibrationDps,
                waveshare_board::imu::orientationName(imuStatus.orientation),
                imuStatus.moving);
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  Serial.printf("SYS: up=%lus heap=%lu psram=%lu screen=%s tile=%s "
                "waitRefresh=%d gpsFromApp=%d pendingMap=%d lat=%.6f "
                "lon=%.6f heading=%u routePts=%u mapFound=%d mapBlocks=%u "
                "mapFlags[pos=%d redraw=%d follow=%d vector=%d zoom=%u] "
                "ui[loop=%lu maxGapMs=%lu lvgl=%lu lastLvglMs=%lu "
                "lvglUs=%lu/%lu flush=%lu lastFlushMs=%lu flushUs=%lu/%lu] "
                "ble[conn=%d auth=%d nav=%lu route=%lu gps=%lu settings=%lu] "
                "i2c[fail=%lu recover=%lu recovered=%lu missing=%lu] "
                "rtc[present=%d valid=%d source=%s unix=%lld]\n",
                (unsigned long)(now / 1000),
                (unsigned long)ESP.getFreeHeap(),
                (unsigned long)ESP.getFreePsram(), screenName,
                debugTileName(activeTile), waitScreenRefresh,
                gpsReceivedFromApp, pendingTransitionToMap,
                gps.gpsData.latitude, gps.gpsData.longitude,
                (unsigned)gps.gpsData.heading,
                (unsigned)routeOverlay.getPointCount(),
                mapView.debugIsMapFound(),
                (unsigned)mapView.debugCachedBlockCount(), mapView.isPosMoved,
                mapView.redrawMap, mapView.followGps, mapSet.vectorMap, zoom,
                (unsigned long)loopCount, (unsigned long)maxLoopGapMs,
                (unsigned long)lvglHandlerCount,
                (unsigned long)lastLvglHandlerMs,
                (unsigned long)lastLvglHandlerDurationUs,
                (unsigned long)maxLvglHandlerDurationUs,
                (unsigned long)displayFlushCount,
                (unsigned long)lastDisplayFlushMs,
                (unsigned long)lastDisplayFlushDurationUs,
                (unsigned long)maxDisplayFlushDurationUs,
                bleStats.connected, bleStats.authenticated,
                (unsigned long)bleStats.navPacketCount,
                (unsigned long)bleStats.routePacketCount,
                (unsigned long)bleStats.gpsPacketCount,
                (unsigned long)bleStats.settingsPacketCount,
                (unsigned long)i2cStats.failedTransactions,
                (unsigned long)i2cStats.recoveryAttempts,
                (unsigned long)i2cStats.recoveredTransactions,
                (unsigned long)i2cStats.missingDevices, rtcStatus.present,
                rtcStatus.timeValid,
                waveshare_board::rtc::sourceName(rtcStatus.source),
                static_cast<long long>(rtcStatus.unixTime));
#else
  Serial.printf("SYS: up=%lus heap=%lu psram=%lu screen=%s tile=%s "
                "waitRefresh=%d gpsFromApp=%d pendingMap=%d lat=%.6f "
                "lon=%.6f heading=%u routePts=%u mapFound=%d mapBlocks=%u "
                "mapFlags[pos=%d redraw=%d follow=%d vector=%d zoom=%u] "
                "ui[loop=%lu maxGapMs=%lu lvgl=%lu lastLvglMs=%lu "
                "lvglUs=%lu/%lu flush=%lu lastFlushMs=%lu flushUs=%lu/%lu] "
                "ble[conn=%d auth=%d nav=%lu route=%lu gps=%lu settings=%lu]\n",
                (unsigned long)(now / 1000),
                (unsigned long)ESP.getFreeHeap(),
                (unsigned long)ESP.getFreePsram(), screenName,
                debugTileName(activeTile), waitScreenRefresh,
                gpsReceivedFromApp, pendingTransitionToMap,
                gps.gpsData.latitude, gps.gpsData.longitude,
                (unsigned)gps.gpsData.heading,
                (unsigned)routeOverlay.getPointCount(),
                mapView.debugIsMapFound(),
                (unsigned)mapView.debugCachedBlockCount(), mapView.isPosMoved,
                mapView.redrawMap, mapView.followGps, mapSet.vectorMap, zoom,
                (unsigned long)loopCount, (unsigned long)maxLoopGapMs,
                (unsigned long)lvglHandlerCount,
                (unsigned long)lastLvglHandlerMs,
                (unsigned long)lastLvglHandlerDurationUs,
                (unsigned long)maxLvglHandlerDurationUs, 0UL, 0UL, 0UL, 0UL,
                bleStats.connected, bleStats.authenticated,
                (unsigned long)bleStats.navPacketCount,
                (unsigned long)bleStats.routePacketCount,
                (unsigned long)bleStats.gpsPacketCount,
                (unsigned long)bleStats.settingsPacketCount);
#endif
}

static void processDisconnectedShutdown() {
  static disconnected_shutdown_policy::Tracker shutdownTracker;
  const bool connected = bleNavServer.isConnected();
  const bool ownershipClaimed = bleNavServer.isOwnershipClaimed();
  const disconnected_shutdown_policy::UpdateResult result =
      shutdownTracker.update(
          millis(), connected,
          mapRenderSettings.disconnectedSleepTimeoutSeconds,
          ownershipClaimed);

  if (result.action ==
      disconnected_shutdown_policy::Action::CountdownStarted) {
    Serial.printf(
        "Power: app not connected; shutdown in %lu seconds if still "
        "disconnected%s\n",
        (unsigned long)result.timeoutSeconds,
        result.waitingForRegistration ? " (registration grace)" : "");
    return;
  }

  if (result.action != disconnected_shutdown_policy::Action::ShutdownDue &&
      result.action != disconnected_shutdown_policy::Action::ShutdownRetry) {
    return;
  }

  if (result.action == disconnected_shutdown_policy::Action::ShutdownDue) {
    Serial.printf("Power: app was disconnected for %lu seconds; entering deep "
                  "sleep\n",
                  (unsigned long)result.timeoutSeconds);
    Serial.println("Power: press BOOT to wake the device");
    Serial.flush();
  }

  power.deviceShutdown();
}

/**
 * @brief Setup
 *
 */
void setup() {
#ifdef HAS_HARDWARE_GPS
  gpsMutex = xSemaphoreCreateMutex();
#endif
  esp_log_level_set("*", ESP_LOG_DEBUG);
  esp_log_level_set("storage", ESP_LOG_DEBUG);

  // Initialize Serial for debug
  Serial.begin(115200);
  // HWCDC uses this value as both a timeout and a retry counter. Zero
  // underflows that counter when the USB host stops reading and stalls the UI.
  Serial.setTxTimeoutMs(1);
  delay(2000);              // Give time for USB CDC to attach
  log_i("Starting Setup...");
  Serial.printf("Reset reason: CPU0=%d CPU1=%d\n", esp_reset_reason(),
                esp_reset_reason());

#ifdef WAVESHARE_AMOLED_175
  // Configure Wire directly below; do not preemptively bit-bang the shared bus.
#endif
#if defined(POWER_SAVE) || defined(WAVESHARE_AMOLED_175) ||                   \
    defined(WAVESHARE_AMOLED_206)
  pinMode(BOARD_BOOT_PIN, INPUT_PULLUP);
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  attachInterrupt(digitalPinToInterrupt(BOARD_BOOT_PIN),
                  latchWaveshareBootScreenCycle, FALLING);
#endif
#ifdef POWER_SAVE
#ifdef ICENAV_BOARD
  gpio_hold_dis(GPIO_NUM_46);
  gpio_hold_dis((gpio_num_t)BOARD_BOOT_PIN);
  gpio_deep_sleep_hold_dis();
#endif
#endif

#ifdef TDECK_ESP32S3
  pinMode(BOARD_POWERON, OUTPUT);
  digitalWrite(BOARD_POWERON, HIGH);
  pinMode(GPIO_NUM_16, INPUT);
  pinMode(SD_CS, OUTPUT);
  pinMode(RADIO_CS_PIN, OUTPUT);
  pinMode(TFT_SPI_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  digitalWrite(RADIO_CS_PIN, HIGH);
  digitalWrite(TFT_SPI_CS, HIGH);
  pinMode(SPI_MISO, INPUT_PULLUP);
#endif

#ifdef ICENAV_BOARD
  // Initialize SD card CS pin
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
#endif

#ifdef WAVESHARE_AMOLED_206
  // OTA rollback/recovery can leave the PMU display rail off. Bring the rail
  // up before CO5300 init so the panel does not stay black after a bad image.
  waveshare_board::recoverI2CBus();
  waveshare_board::i2c::configureBus();
  waveshare_board::enablePowerRails();
  initTFT();
#ifdef WAVESHARE_DISPLAY_PROBE
  Serial.println("Waveshare 2.06 display probe complete; holding before I2C/PMU/SD/LVGL/BLE/touch init");
  while (true) {
    delay(1000);
  }
#endif
#endif

#if defined(WAVESHARE_AMOLED_175)
  waveshare_board::i2c::configureBus();
#elif !defined(WAVESHARE_AMOLED_206)
  Wire.setPins(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.begin();
#endif

#if defined(WAVESHARE_AMOLED_175)
  waveshare_board::enablePowerRails();
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#ifdef WAVESHARE_DISPLAY_PROBE
  Serial.println("Waveshare display probe: skipping RTC and IMU init");
#else
  waveshare_board::rtc::restoreSystemTimeFromRtc();
#ifdef WAVESHARE_IMU_DIAGNOSTICS
  waveshare_board::imu::begin();
#else
  waveshare_board::imu::disable();
#endif
#endif
#endif

#ifdef BME280
  initBME();
#endif

#ifdef ENABLE_COMPASS
  compass.init();
#endif

#ifdef ENABLE_IMU
  initIMU();
#endif

  battery.initADC();

  // IMPORTANT: Initialize TFT BEFORE SD card!
  // The QSPI display init can disrupt SPI bus settings.
  // By initializing display first, the SPI buses are settled
  // before we configure the SD card.
#ifndef WAVESHARE_AMOLED_206
  initTFT();

#ifdef WAVESHARE_DISPLAY_PROBE
  Serial.println("Waveshare display probe complete; holding before SD/LVGL/BLE/touch init");
  while (true) {
    delay(1000);
  }
#endif
#endif

  // Now initialize SD card after display is fully configured
  esp_err_t sdResult = storage.initSD();
  if (sdResult != ESP_OK) {
    // SD card failed - fall back to internal FFat storage
    Serial.println("SD Card failed, falling back to FFat...");
    storage.initSPIFFS();
  }

  {
    map_transfer::MapTransferInstaller mapInstaller("/sdcard");
    map_transfer::InstallStatus recoveryStatus =
        mapInstaller.recoverInterruptedActivation();
    if (!recoveryStatus.ok) {
      Serial.printf("MAP_TRANSFER: recovery failed code=%s message=%s\n",
                    recoveryStatus.code.c_str(), recoveryStatus.message.c_str());
    } else if (recoveryStatus.code != "ok") {
      Serial.printf("MAP_TRANSFER: %s\n", recoveryStatus.message.c_str());
    }
    map_transfer::ActiveMapSelection activeMap;
    map_transfer::InstallStatus activeStatus =
        mapInstaller.readActiveMap(activeMap);
    if (activeStatus.ok) {
      const auto loadSelection =
          [&](const map_transfer::ActiveMapSelection &selection) {
            const std::string root = std::string("/sdcard") + selection.root;
            return mapView.probeVectorMapFolder(root) &&
                   mapView.setVectorMapFolder(root);
          };
      if (loadSelection(activeMap)) {
        Serial.printf("MAP_TRANSFER: activeMapId=%s root=%s\n",
                      activeMap.mapId.c_str(), activeMap.root.c_str());
      } else if (!activeMap.sessionId.empty()) {
        const map_transfer::InstallStatus rollback =
            mapInstaller.rollbackActiveMap(activeMap.sessionId);
        map_transfer::ActiveMapSelection restored;
        const map_transfer::InstallStatus restoredStatus =
            mapInstaller.readActiveMap(restored);
        const bool restoredLoaded =
            rollback.ok && restoredStatus.ok && loadSelection(restored);
        Serial.printf("MAP_TRANSFER: boot renderer probe failed session=%s "
                      "rollback=%s restored=%d\n",
                      activeMap.sessionId.c_str(), rollback.code.c_str(),
                      restoredLoaded);
      } else {
        Serial.printf("MAP_TRANSFER: legacy renderer probe failed root=%s\n",
                      activeMap.root.c_str());
      }
    } else {
      Serial.printf("MAP_TRANSFER: activeMap unavailable code=%s message=%s\n",
                    activeStatus.code.c_str(), activeStatus.message.c_str());
    }
  }
  deviceTransferHttp.configure(8080, "BikeComputer-Transfer");
  mapTransferHttp.configure("/sdcard", 8080, &deviceTransferHttp);
  mapTransferHttp.setStreamStorageProbe(
      [] { return storage.getSdLoaded(); });
  mapTransferHttp.setStreamStorageAvailable(sdResult == ESP_OK &&
                                            storage.getSdLoaded());
  firmwareUpdateHttp.configure(&deviceTransferHttp);

  createGpxFolders();

  mapView.initMap(gui_layout::mapViewportHeight(TFT_HEIGHT), TFT_WIDTH,
                  TFT_HEIGHT);

  loadPreferences();
#ifdef HAS_HARDWARE_GPS
  gps.init();
#endif
  initLVGL();
  log_i("Checkpoint A: LVGL Init Done");

  // Get init Latitude and Longitude
  gps.gpsData.latitude = gps.getLat();
  gps.gpsData.longitude = gps.getLon();
  log_i("Checkpoint B: Position Data Initialized");

#ifdef HAS_HARDWARE_GPS
  initGpsTask();
  log_i("Checkpoint C: GPS Task Init Done");
#endif

#ifndef DISABLE_CLI
  initCLI();
  log_i("Checkpoint D: CLI Init Done");
  initCLITask();
  log_i("Checkpoint E: CLI Task Init Done");
#endif

#ifndef DISABLE_WEB_SERVER
  if (WiFi.status() == WL_CONNECTED) {
    if (!MDNS.begin(hostname))
      log_e("nDNS init error");

    log_i("mDNS initialized");
  }
#endif

#ifndef DISABLE_WEB_SERVER
  if (WiFi.status() == WL_CONNECTED && enableWeb) {
    configureWebServer();
    server.begin();
  }
#endif

  if (WiFi.getMode() == WIFI_OFF)
    ESP_ERROR_CHECK(esp_event_loop_create_default());

  log_i("Loading Splash Screen...");
  splashScreen();

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  waveshare_board::speaker::begin();
  if (!waveshare_board::axp2101::setPowerButtonEventMonitoring(true)) {
    Serial.println("AXP2101: PWR button-event monitoring unavailable");
  }
#endif

  // Initialize BLE early so device is discoverable while showing waiting screen
  bleNavServer.init("BikeComputer");

  // Set default coordinates as fallback (will be overwritten by BLE GPS)
#if defined(DEFAULT_LAT) && defined(DEFAULT_LON)
  gps.gpsData.latitude = DEFAULT_LAT;
  gps.gpsData.longitude = DEFAULT_LON;
  gps.gpsData.satellites = 0;
  gps.gpsData.fixMode = 0;
  log_i("Default coordinates set: %f, %f (waiting for app GPS)", DEFAULT_LAT,
        DEFAULT_LON);
#endif

  // Show waiting screen - will transition to map when GPS is received via BLE
  log_i("Loading Waiting Screen...");
  lv_screen_load(waitingScreen);

  log_i("Setup Complete");
  firmwareUpdateHttp.markRunningAppValid();
  mapTransferHttp.resumePendingActivations();
}

/**
 * @brief Main Loop
 *
 */
void loop() {
  uint32_t now = millis();
  if (lastLoopMs != 0) {
    uint32_t gap = now - lastLoopMs;
    if (gap > maxLoopGapMs) {
      maxLoopGapMs = gap;
    }
  }
  lastLoopMs = now;
  loopCount++;

  std::string activatedMapRoot;
  if (mapTransferHttp.takeActivatedMapRoot(activatedMapRoot)) {
    const std::string rendererRoot = std::string("/sdcard") + activatedMapRoot;
    const bool loaded = mapView.probeVectorMapFolder(rendererRoot) &&
                        mapView.setVectorMapFolder(rendererRoot);
    mapTransferHttp.acknowledgeActivatedMapRoot(activatedMapRoot, loaded);
  }
  if (mapTransferHttp.takeAutomaticExitRequest()) {
    const bool disabled = mapTransferHttp.setEnabled(false);
    Serial.printf("MAP_TRANSFER_HTTP: automatic exit applied disabled=%d\n",
                  disabled);
  }

  // Process app-provided GPS transitions before any periodic work that can
  // briefly block on display, sensor, BLE, or debug output.
  checkPendingMapTransition();
  updateMapActivationProgressOverlay();

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  // Sample the screen-cycle button before LVGL can start a synchronous vector
  // redraw. updateMainScreen() also defers while the raw input is active.
  processWaveshareBootButton();
#endif

  if (!waitScreenRefresh) {
    uint32_t startUs = micros();
    lv_timer_handler();
    lastLvglHandlerDurationUs = micros() - startUs;
    if (lastLvglHandlerDurationUs > maxLvglHandlerDurationUs) {
      maxLvglHandlerDurationUs = lastLvglHandlerDurationUs;
    }
    lvglHandlerCount++;
    lastLvglHandlerMs = millis();
    vTaskDelay(pdMS_TO_TICKS(TASK_SLEEP_PERIOD_MS));
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    armOwnershipPairingAfterRenderedComparison();
#endif
  }

  // Process BLE events
  bleNavServer.process();
  processDisconnectedShutdown();

#if (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)) &&       \
    defined(WAVESHARE_IMU_DIAGNOSTICS)
  waveshare_board::imu::process();
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  processWavesharePowerButton();
#endif

  logSystemDebugHeartbeat();

#ifndef DISABLE_WEB_SERVER
  // Deleting recursive directories in webfile server
  if (enableWeb && deleteDir) {
    deleteDir = false;
    if (deleteDirRecursive(deletePath.c_str())) {
      updateList = true;
      eventRefresh.send("refresh", nullptr, millis());
      eventRefresh.send("Folder deleted", "updateStatus", millis());
    }
  }
#endif

  deviceTransferHttp.process();
}
