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

// BLE Navigation for iOS route overlay
#include "ble_navigation.hpp"
#include "mainScr.hpp"
#include "route_overlay.hpp"
#include "waitingScr.hpp"
#ifdef WAVESHARE_AMOLED_175
#include "WAVESHARE_AMOLED_175.hpp"
#endif

extern Storage storage;
extern Battery battery;
extern Power power;
extern Maps mapView;
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
  case NAV:
    return "NAV";
  case SATTRACK:
    return "SATTRACK";
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
  const char *screenName = "unknown";
  lv_obj_t *activeScreen = lv_scr_act();
  if (activeScreen == waitingScreen) {
    screenName = "waiting";
  } else if (isMainScreen) {
    screenName = "main";
  }

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
#ifdef WAVESHARE_AMOLED_175
                (unsigned long)loopCount, (unsigned long)maxLoopGapMs,
                (unsigned long)lvglHandlerCount,
                (unsigned long)lastLvglHandlerMs,
                (unsigned long)lastLvglHandlerDurationUs,
                (unsigned long)maxLvglHandlerDurationUs,
                (unsigned long)displayFlushCount,
                (unsigned long)lastDisplayFlushMs,
                (unsigned long)lastDisplayFlushDurationUs,
                (unsigned long)maxDisplayFlushDurationUs,
#else
                (unsigned long)loopCount, (unsigned long)maxLoopGapMs,
                (unsigned long)lvglHandlerCount,
                (unsigned long)lastLvglHandlerMs,
                (unsigned long)lastLvglHandlerDurationUs,
                (unsigned long)maxLvglHandlerDurationUs, 0UL, 0UL, 0UL, 0UL,
#endif
                bleStats.connected, bleStats.authenticated,
                (unsigned long)bleStats.navPacketCount,
                (unsigned long)bleStats.routePacketCount,
                (unsigned long)bleStats.gpsPacketCount,
                (unsigned long)bleStats.settingsPacketCount);
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
  // =========================================================
  // I2C Bus Recovery - CRITICAL for stuck bus
  // Must run BEFORE any other I2C/SD operations
  // =========================================================
  log_i("Performing I2C bus recovery...");

  // Configure pins as GPIO for manual control (Wire not started yet)
  pinMode(I2C_SDA_PIN, INPUT_PULLUP);
  pinMode(I2C_SCL_PIN, OUTPUT);

  // Clock SCL up to 9 times while monitoring SDA
  // This releases any slave holding SDA low
  int clockCount = 0;
  for (int i = 0; i < 9; i++) {
    digitalWrite(I2C_SCL_PIN, LOW);
    delayMicroseconds(5);
    digitalWrite(I2C_SCL_PIN, HIGH);
    delayMicroseconds(5);
    clockCount++;

    // If SDA is released (high), we might be done
    if (digitalRead(I2C_SDA_PIN) == HIGH) {
      break;
    }
  }

  // Generate STOP condition: SDA low-to-high while SCL high
  pinMode(I2C_SDA_PIN, OUTPUT);
  digitalWrite(I2C_SDA_PIN, LOW);
  delayMicroseconds(5);
  digitalWrite(I2C_SCL_PIN, HIGH);
  delayMicroseconds(5);
  digitalWrite(I2C_SDA_PIN, HIGH);
  delayMicroseconds(5);

  log_i("I2C bus recovery done (%d clocks)", clockCount);
#endif
#ifdef POWER_SAVE
  pinMode(BOARD_BOOT_PIN, INPUT_PULLUP);
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

  Wire.setPins(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.begin();

#ifdef WAVESHARE_AMOLED_175
  // Initialize AXP2101 Power Management - CRITICAL for display power!
  Serial.println("Enabling display power via AXP2101...");
  Wire.beginTransmission(0x34); // AXP2101 I2C address
  if (Wire.endTransmission() == 0) {
    Serial.println("✓ AXP2101 found!");

    // Enable DLDO1 output (3.3V for display) - exact same as working demo
    Wire.beginTransmission(0x34);
    Wire.write(0x90); // DLDO1 voltage setting register
    Wire.write(0x1C); // Set to 3.3V
    Wire.endTransmission();

    Wire.beginTransmission(0x34);
    Wire.write(0x90); // Enable DLDO1
    Wire.write(0x9C); // Enable bit + 3.3V
    Wire.endTransmission();

    // Enable other LDOs (ALDO1-4, BLDO1-2) to ensure SD Card and other
    // peripherals are powered Register map typically: 0x92=ALDO1, 0x93=ALDO2,
    // 0x94=ALDO3, 0x95=ALDO4, 0x96=BLDO1, 0x97=BLDO2

    uint8_t ldo_regs[] = {0x92, 0x93, 0x94, 0x95, 0x96, 0x97};

    // 1. Turn OFF all peripheral LDOs to force reset
    Serial.println("Resetting Peripheral Power...");
    for (uint8_t reg : ldo_regs) {
      Wire.beginTransmission(0x34);
      Wire.write(reg);
      Wire.write(0x1C); // Disable (Bit 7=0) + Voltage 3.3V (Just in case)
      Wire.endTransmission();
    }
    delay(500); // Wait for capacitors to discharge

    // 2. Turn ON all peripheral LDOs
    Serial.println("Enabling Peripheral Power...");
    for (uint8_t reg : ldo_regs) {
      Wire.beginTransmission(0x34);
      Wire.write(reg);
      Wire.write(0x1C); // Set to 3.3V
      Wire.endTransmission();

      Wire.beginTransmission(0x34);
      Wire.write(reg);
      Wire.write(0x9C); // Enable (Bit 7=1) + 3.3V
      Wire.endTransmission();
    }

    delay(500); // Wait for power to stabilize (Longer delay)
    Serial.println("✓ AXP2101 display power enabled");
    // I2C Bus kept enabled for Touch Controller and Power Management

  } else {
    Serial.println("✗ AXP2101 not found - display may not work!");
  }
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
  initTFT();

  // Now initialize SD card after display is fully configured
  esp_err_t sdResult = storage.initSD();
  if (sdResult != ESP_OK) {
    // SD card failed - fall back to internal FFat storage
    Serial.println("SD Card failed, falling back to FFat...");
    storage.initSPIFFS();
  }

  createGpxFolders();

  mapView.initMap(TFT_HEIGHT - 100, TFT_WIDTH, TFT_HEIGHT);

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

  // Check if we need to transition from waiting screen to map
  checkPendingMapTransition();

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
}
