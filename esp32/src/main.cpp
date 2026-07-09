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

extern xSemaphoreHandle gpsMutex;

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
#include "guiLayout.hpp"
#include "mainScr.hpp"
#include "route_overlay.hpp"
#include "waitingScr.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "WAVESHARE_AMOLED_175.hpp"
#include "i2c_bus.hpp"
#include "pcf85063.hpp"
#include "qmi8658.hpp"
#include "waveshare_board.hpp"
#endif

extern Storage storage;
extern Battery battery;
extern Power power;
extern Maps mapView;
device_transfer::HttpTransferServer deviceTransferHttp;
map_transfer::MapTransferHttpServer mapTransferHttp;
firmware_update::FirmwareUpdateHttpServer firmwareUpdateHttp;

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
static void processWaveshareBootButton() {
  constexpr uint32_t DEBOUNCE_MS = 50;

  static bool lastPressed = false;
  static bool stablePressed = false;
  static uint32_t lastChangeMs = 0;
  static uint32_t pressStartMs = 0;

  const uint32_t now = millis();
  const bool pressed = digitalRead(BOARD_BOOT_PIN) == LOW;

  if (pressed != lastPressed) {
    lastPressed = pressed;
    lastChangeMs = now;
    return;
  }

  if (pressed == stablePressed || now - lastChangeMs < DEBOUNCE_MS) {
    return;
  }

  stablePressed = pressed;
  if (stablePressed) {
    pressStartMs = now;
    return;
  }

  const uint32_t pressDurationMs = now - pressStartMs;
  log_i("Waveshare BOOT released after %lu ms; cycling main screen",
        static_cast<unsigned long>(pressDurationMs));
  toggleNavigationScreen();
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
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const waveshare_board::i2c::Stats &i2cStats = waveshare_board::i2c::stats();
  const waveshare_board::rtc::Status &rtcStatus =
      waveshare_board::rtc::status();
  const waveshare_board::imu::Status &imuStatus =
      waveshare_board::imu::status();
  const waveshare_board::imu::Sample &imuSample =
      waveshare_board::imu::lastSample();
#endif
  const char *screenName = "unknown";
  lv_obj_t *activeScreen = lv_scr_act();
  if (activeScreen == waitingScreen) {
    screenName = "waiting";
  } else if (isMainScreen) {
    screenName = "main";
  }

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
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
  static uint32_t disconnectedSinceMs = 0;
  static uint32_t lastTimeoutSeconds = 120;
  static bool shutdownAnnounced = false;

  if (bleNavServer.isConnected()) {
    disconnectedSinceMs = 0;
    lastTimeoutSeconds = mapRenderSettings.disconnectedSleepTimeoutSeconds;
    shutdownAnnounced = false;
    return;
  }

  const uint32_t timeoutSeconds =
      mapRenderSettings.disconnectedSleepTimeoutSeconds;
  if (timeoutSeconds == 0) {
    disconnectedSinceMs = 0;
    lastTimeoutSeconds = 0;
    shutdownAnnounced = false;
    return;
  }

  if (timeoutSeconds != lastTimeoutSeconds) {
    disconnectedSinceMs = 0;
    lastTimeoutSeconds = timeoutSeconds;
    shutdownAnnounced = false;
  }

  const uint32_t now = millis();
  if (disconnectedSinceMs == 0) {
    disconnectedSinceMs = now;
    Serial.printf("Power: app not connected; shutdown in %lu seconds if still "
                  "disconnected\n",
                  (unsigned long)timeoutSeconds);
    return;
  }

  if (now - disconnectedSinceMs < timeoutSeconds * 1000UL) {
    return;
  }

  if (!shutdownAnnounced) {
    shutdownAnnounced = true;
    Serial.printf("Power: app was disconnected for %lu seconds; entering deep "
                  "sleep\n",
                  (unsigned long)timeoutSeconds);
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
  gpsMutex = xSemaphoreCreateMutex();
  esp_log_level_set("*", ESP_LOG_DEBUG);
  esp_log_level_set("storage", ESP_LOG_DEBUG);

  // Initialize Serial for debug
  Serial.begin(115200);
  Serial.setTxTimeoutMs(0); // Prevent blocking if no host connected
  delay(2000);              // Give time for USB CDC to attach
  log_i("Starting Setup...");
  Serial.printf("Reset reason: CPU0=%d CPU1=%d\n", esp_reset_reason(),
                esp_reset_reason());

#ifdef WAVESHARE_AMOLED_175
  waveshare_board::recoverI2CBus();
#endif
#if defined(POWER_SAVE) || defined(WAVESHARE_AMOLED_175) ||                   \
    defined(WAVESHARE_AMOLED_206)
  pinMode(BOARD_BOOT_PIN, INPUT_PULLUP);
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
  waveshare_board::imu::begin();
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
    std::string activeMapId;
    map_transfer::InstallStatus activeStatus =
        mapInstaller.readActiveMapId(activeMapId);
    if (activeStatus.ok) {
      Serial.printf("MAP_TRANSFER: activeMapId=%s\n", activeMapId.c_str());
    } else {
      Serial.printf("MAP_TRANSFER: activeMap unavailable code=%s message=%s\n",
                    activeStatus.code.c_str(), activeStatus.message.c_str());
    }
  }
  deviceTransferHttp.configure(8080, "BikeComputer-Transfer");
  mapTransferHttp.configure("/sdcard", 8080, &deviceTransferHttp);
  firmwareUpdateHttp.configure(&deviceTransferHttp);

  createGpxFolders();

  mapView.initMap(gui_layout::mapViewportHeight(TFT_HEIGHT), TFT_WIDTH,
                  TFT_HEIGHT);

  loadPreferences();
  gps.init();
  initLVGL();
  log_i("Checkpoint A: LVGL Init Done");

  // Get init Latitude and Longitude
  gps.gpsData.latitude = gps.getLat();
  gps.gpsData.longitude = gps.getLon();
  log_i("Checkpoint B: GPS Data Retrieved");

  initGpsTask();
  log_i("Checkpoint C: GPS Task Init Done");

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

  // Process app-provided GPS transitions before any periodic work that can
  // briefly block on display, sensor, BLE, or debug output.
  checkPendingMapTransition();

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
  }

  // Process BLE events
  bleNavServer.process();
  processDisconnectedShutdown();

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  waveshare_board::imu::process();
  processWaveshareBootButton();
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
