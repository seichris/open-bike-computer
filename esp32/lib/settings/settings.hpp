/**
 * @file settings.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  Settings functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include <Arduino.h> // For String class

/**
 * @brief Structure for map settings
 *
 */
struct MapSettings {
  bool showMapCompass;  // Compass in map screen
  bool compassRotation; // Compass rotation in map screen
  bool mapRotationComp; // Rotate map with compass
  bool mapFullScreen;   // Full Screen map
  bool showMapSpeed;    // Speed in map screen
  bool vectorMap;       // Map type (vector/render)
  bool showMapScale;    // Scale in map screen
};

#ifndef USE_ARDUINO_GFX
#include <EasyPreferences.hpp>
#else
// Dummy enums and constants for Arduino_GFX compatibility
enum class PKEYS {
  KCOMP_OFFSET_X,
  KCOMP_OFFSET_Y,
  KDECL_ANG,
  KKALM_FIL,
  KKALM_Q,
  KKALM_R,
  KMAP_ROT_MODE,
  KMAP_COMPASS,
  KMAP_COMP_ROT,
  KMAP_MODE,
  KMAP_SPEED,
  KMAP_VECTOR,
  KMAP_SCALE,
  KGPS_SPEED,
  KGPS_RATE,
  KCOMP_X,
  KCOMP_Y,
  KCOORD_X,
  KCOORD_Y,
  KALTITUDE_X,
  KALTITUDE_Y,
  KSPEED_X,
  KSPEED_Y,
  KSUN_X,
  KSUN_Y,
  KDEF_BRIGT,
  KDEF_ZOOM,
  KGPS_TX,
  KGPS_RX,
  KWEB_FILE,
  KTEMP_OFFS,
  KVMAX_BATT,
  KVMIN_BATT,
  KUSER,
  KLAT_DFL,
  KLON_DFL // Added for GPS default coordinates
};

enum class CONFKEYS {
  KCOMP_X,
  KCOMP_Y,
  KCOORD_X,
  KCOORD_Y,
  KALTITUDE_X,
  KALTITUDE_Y,
  KSPEED_X,
  KSPEED_Y,
  KSUN_X,
  KSUN_Y,
  KDEF_TZ // Added for timezone
};

const int KCOUNT = 1;
const int PREF_LCOUNT =
    1; // Renamed from LCOUNT to avoid xtensa system define conflict

// Dummy EasyPreferences class for Arduino_GFX compatibility
class EasyPreferencesDummy {
public:
  void init(const char *name) {}

  // Methods that accept PKEYS enum
  float getFloat(PKEYS key, float defaultVal) { return defaultVal; }
  double getDouble(PKEYS key, double defaultVal) { return defaultVal; }
  bool getBool(PKEYS key, bool defaultVal) { return defaultVal; }
  short getShort(PKEYS key, short defaultVal) { return defaultVal; }
  int getInt(PKEYS key, int defaultVal) { return defaultVal; }
  unsigned int getUInt(PKEYS key, unsigned int defaultVal) {
    return defaultVal;
  }
  String getString(CONFKEYS key, String defaultVal) { return defaultVal; }
  void saveFloat(PKEYS key, float value) {}
  void saveBool(PKEYS key, bool value) {}
  void saveShort(PKEYS key, short value) {}
  void saveInt(PKEYS key, int value) {}
  void saveUInt(PKEYS key, unsigned int value) {}

  // Methods that accept const char* (for custom keys)
  void saveInt(const char *key, int value) {}
  void saveUInt(const char *key, unsigned int value) {}

  // Additional methods used by the code
  String getKey(CONFKEYS index) { return String(""); }
  String getValue(String key) { return String(""); }
  bool isKey(String key) { return false; }
  bool isKey(CONFKEYS key) { return false; }
};

extern EasyPreferencesDummy cfg;
#endif
#include "battery.hpp"
#include "gps.hpp"
#include "tft.hpp"
#include <NMEAGPS.h>
#ifndef DISABLE_COMPASS
#include "compass.hpp"
#endif

extern uint8_t minZoom;       // Min Zoom Level
extern uint8_t maxZoom;       // Max Zoom Level
extern uint8_t defZoomRender; // Default Zoom Level for render map
extern uint8_t defZoomVector; // Default Zoom Level for vector map
extern uint8_t zoom;          // Actual Zoom Level
extern uint8_t defBright;     // Default brightness
extern uint8_t defaultZoom;   // Default Zoom Value

extern bool showMapToolBar;   // Show Map Toolbar
extern uint16_t gpsBaud;      // GPS Speed
extern uint16_t gpsUpdate;    // GPS Update rate
extern uint16_t compassPosX;  // Compass widget position X
extern uint16_t compassPosY;  // Compass widget position Y
extern uint16_t coordPosX;    // Coordinates widget position X
extern uint16_t coordPosY;    // Coordinates widget position Y
extern uint16_t altitudePosX; // Altitude widget position X
extern uint16_t altitudePosY; // Altitude widget position Y
extern uint16_t speedPosX;    // Speed widget position X
extern uint16_t speedPosY;    // Speed widget position Y
extern uint16_t sunPosX;      // Sunrise/sunset position X
extern uint16_t sunPosY;      // Sunrise/sunset position Y
extern bool enableWeb;        // Enable/disable web file server
extern int8_t tempOffset;     // BME Temperature offset
extern bool calculateDST;     // Calculate DST flag

extern MapSettings mapSet;

void loadPreferences();

void saveGPSBaud(uint16_t gpsBaud);
void saveGPSUpdateRate(uint16_t gpsUpdateRate);
void saveWidgetPos(char *widget, uint16_t posX, uint16_t posY);
void printSettings();