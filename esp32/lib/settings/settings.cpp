/**
 * @file settings.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Settings functions
 * @version 0.2.2
 * @date 2025-05
 */

#include "settings.hpp"
#include "../board/board.hpp"

static const char *TAG PROGMEM = "Settings";

EasyPreferencesDummy cfg;

/**
 * @brief Structure for map settings
 *
 */
MapSettings mapSet;

/**
 * @brief Zoom Levels and Default zoom
 *
 */
uint8_t minZoom = 0;        // Min Zoom Level
uint8_t maxZoom = 0;        // Max Zoom Level
uint8_t defZoomRender = 15; // Default Zoom Level for render map
uint8_t defZoomVector = 2;  // Default Zoom Level for vector map (max zoom)
uint8_t zoom = 0;           // Actual Zoom Level

static const float scale = 0.75f;

/**
 * @brief Global Variables definition for device preferences & config.
 *
 */
uint8_t defaultZoom = 0;     // Default Zoom Value
uint8_t defBright = 255;     // Default Brightness
uint16_t gpsBaud = 0;        // GPS Speed
uint16_t gpsUpdate = 0;      // GPS Update rate
uint16_t compassPosX = 0;    // Compass widget position X
uint16_t compassPosY = 0;    // Compass widget position Y
uint16_t coordPosX = 0;      // Coordinates widget position X
uint16_t coordPosY = 0;      // Coordinates widget position Y
uint16_t altitudePosX = 0;   // Altitude widget position X
uint16_t altitudePosY = 0;   // Altitude widget position Y
uint16_t speedPosX = 0;      // Speed widget position X
uint16_t speedPosY = 0;      // Speed widget position Y
uint16_t sunPosX = 0;        // Sunrise/sunset position X
uint16_t sunPosY = 0;        // Sunrise/sunset position Y
bool showMapToolBar = false; // Show Map Toolbar
extern Battery battery;
extern Gps gps;
bool calculateDST = false; // Calculate DST flag

static uint16_t defaultCompassX() {
  return (TFT_WIDTH / 2) - (100 * scale);
}

static uint16_t defaultCompassY() { return board::layout::compassY; }

static uint16_t defaultCoordX() {
  return (TFT_WIDTH / 2) - (90 * scale);
}

static uint16_t defaultCoordY() { return board::layout::coordY; }

static uint16_t defaultAltitudeX() { return board::layout::altitudeX; }

static uint16_t defaultAltitudeY() {
  return TFT_HEIGHT - board::layout::altitudeBottomInset;
}

static uint16_t defaultSpeedX() { return board::layout::speedX; }

static uint16_t defaultSpeedY() {
  return TFT_HEIGHT - board::layout::speedBottomInset;
}

static uint16_t defaultSunX() { return board::layout::sunX; }

static uint16_t defaultSunY() {
  return TFT_HEIGHT - board::layout::sunBottomInset;
}

/**
 * @brief Load stored preferences
 *
 */
void loadPreferences() {
  cfg.init("ICENAV");
  mapSet.mapRotationComp = cfg.getBool(PKEYS::KMAP_ROT_MODE, false);
  mapSet.showMapCompass = cfg.getBool(PKEYS::KMAP_COMPASS, true);
  mapSet.compassRotation = cfg.getBool(PKEYS::KMAP_COMP_ROT, true);
  mapSet.mapFullScreen = cfg.getBool(PKEYS::KMAP_MODE, true);
  mapSet.showMapSpeed = cfg.getBool(PKEYS::KMAP_SPEED, true);
  mapSet.vectorMap = cfg.getBool(PKEYS::KMAP_VECTOR, true);
  mapSet.showMapScale = cfg.getBool(PKEYS::KMAP_SCALE, true);
  gpsBaud = cfg.getShort(PKEYS::KGPS_SPEED, 4);
  gpsUpdate = cfg.getShort(PKEYS::KGPS_RATE, 3);
  compassPosX = cfg.getInt(PKEYS::KCOMP_X, defaultCompassX());
  compassPosY = cfg.getInt(PKEYS::KCOMP_Y, defaultCompassY());
  coordPosX = cfg.getInt(PKEYS::KCOORD_X, defaultCoordX());
  coordPosY = cfg.getInt(PKEYS::KCOORD_Y, defaultCoordY());
  altitudePosX = cfg.getInt(PKEYS::KALTITUDE_X, defaultAltitudeX());
  altitudePosY = cfg.getInt(PKEYS::KALTITUDE_Y, defaultAltitudeY());
  speedPosX = cfg.getInt(PKEYS::KSPEED_X, defaultSpeedX());
  speedPosY = cfg.getInt(PKEYS::KSPEED_Y, defaultSpeedY());
  sunPosX = cfg.getInt(PKEYS::KSUN_X, defaultSunX());
  sunPosY = cfg.getInt(PKEYS::KSUN_Y, defaultSunY());
  defBright = cfg.getUInt(PKEYS::KDEF_BRIGT, 254);
  if (mapSet.vectorMap) {
    minZoom = 1;
    maxZoom = 5;
    defaultZoom = cfg.getUInt(PKEYS::KDEF_ZOOM, defZoomVector);
  } else {
    minZoom = 6;
    maxZoom = 17;
    defaultZoom = cfg.getUInt(PKEYS::KDEF_ZOOM, defZoomRender);
  }
  zoom = defaultZoom;
  GPS_TX = cfg.getUInt(PKEYS::KGPS_TX, GPS_TX);
  GPS_RX = cfg.getUInt(PKEYS::KGPS_RX, GPS_RX);

// Default Widgets positions

  battery.setBatteryLevels(cfg.getFloat(PKEYS::KVMAX_BATT, 4.2),
                           cfg.getFloat(PKEYS::KVMIN_BATT, 3.6));
  printSettings();
}

/**
 * @brief Save GPS speed
 *
 * @param gpsBaud
 */
void saveGPSBaud(uint16_t gpsBaud) {
#ifdef HAS_HARDWARE_GPS
  cfg.saveShort(PKEYS::KGPS_SPEED, gpsBaud);
  if (gpsBaud != 4) {
#ifdef AT6558D_GPS
    gpsPort.flush();
    gpsPort.println(GPS_BAUD_PCAS[gpsBaud]);
    gpsPort.flush();
    gpsPort.println("$PCAS00*01\r\n");
    gpsPort.flush();
    delay(500);
#endif
    gpsPort.flush();
    gpsPort.end();
    delay(500);
    gpsPort.setRxBufferSize(1024);
    gpsPort.begin(GPS_BAUD[gpsBaud], SERIAL_8N1, GPS_RX, GPS_TX);
    delay(500);
  } else {
    gpsBaudDetected = gps.autoBaud();

    if (gpsBaudDetected != 0) {
      gpsPort.flush();
      gpsPort.end();
      delay(500);
      gpsPort.setRxBufferSize(1024);
      gpsPort.begin(gpsBaudDetected, SERIAL_8N1, GPS_RX, GPS_TX);
      delay(500);
    }
  }
#else
  (void)gpsBaud;
#endif
}

/**
 * @brief Save GPS Update rate
 *
 * @param gpsUpdateRate
 */
void saveGPSUpdateRate(uint16_t gpsUpdateRate) {
#ifdef HAS_HARDWARE_GPS
  cfg.saveShort(PKEYS::KGPS_RATE, gpsUpdateRate);
#ifdef AT6558D_GPS
  gpsPort.flush();
  gpsPort.println(GPS_RATE_PCAS[gpsUpdateRate]);
  gpsPort.flush();
  gpsPort.println("$PCAS00*01\r\n");
  gpsPort.flush();
  delay(500);
#endif
#else
  (void)gpsUpdateRate;
#endif
}

/**
 * @brief Save Widget position
 *
 * @param posX
 * @param posY
 */
void saveWidgetPos(char *widget, uint16_t posX, uint16_t posY) {
  const char *strX = "X";
  const char *strY = "Y";
  char widgetX[30] = "";
  char widgetY[30] = "";
  strcat(widgetX, widget);
  strcat(widgetX, strX);
  strcat(widgetY, widget);
  strcat(widgetY, strY);

  cfg.saveInt(widgetX, posX);
  cfg.saveInt(widgetY, posY);
}

/**
 * @brief Utility to show all settings
 */
void printSettings() {
  // printSettings disabled when using dummy EasyPreferences
  ESP_LOGV(TAG, "printSettings() unavailable without a preferences store");
}
