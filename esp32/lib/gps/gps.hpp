/**
 * @file gps.hpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  GPS definition and functions
 * @version 0.2.2
 * @date 2025-05
 */

#pragma once

#include "gps_ride_observation.hpp"
#include "gps_sample_timing.hpp"
#include <NMEAGPS.h>
#include <Streamers.h>
#include <hal.hpp>

#define DEG2RAD(a) ((a) / (180 / M_PI)) // Convert degrees to radians
#define RAD2DEG(a) ((a) * (180 / M_PI)) // Convert radians to degrees

#define MAX_SATELLITES 120
#define MAX_SATELLLITES_IN_VIEW 32

#define DEBUG_PORT Serial
extern gps_fix fix;
extern NMEAGPS GPS;

extern bool setTime;
void calculateSun();
const char *getPosixTZ(const char *name);

extern bool isGpsFixed;
extern bool isTimeFixed;

/**
 * @brief Satellite Constellation Canvas Definition
 *
 */
static const uint8_t canvasOffset = 15;
static const uint8_t canvasSize = 180;
static const uint8_t canvasCenter_X = canvasSize / 2;
static const uint8_t canvasCenter_Y = canvasSize / 2;
static const uint8_t canvasRadius = canvasCenter_X - canvasOffset;

/**
 * @brief The parser's satellite table as of one completed interval
 *
 * Copied by the task that parses NMEA, so the task that owns gpsData can
 * apply it without reading the parser while it runs.
 */
struct GpsSatelliteSnapshot {
#ifdef NMEAGPS_PARSE_SATELLITES
  uint8_t count = 0;
  NMEAGPS::satellite_view_t views[NMEAGPS_MAX_SATELLITES];
#endif
};

class Gps {
public:
  Gps();
  double getLat();
  double getLon();
  // Applies the parser's `fix` global and an interval's satellite table to
  // gpsData. Call it only from the task that owns gpsData and the LVGL
  // objects (the main loop): it also sets the clock and sends an LVGL event.
  void getGPSData(const GpsSatelliteSnapshot &satellites);
  bool isSpeedChanged();
  bool isAltitudeChanged();
  bool hasLocationChange();
  bool isDOPChanged();
  void setLocalTime(NeoGPS::time_t gpsTime, const char *tz);

  struct GPSDATA {
    uint8_t satellites;
    uint8_t fixMode;
    int16_t altitude;
    uint16_t speed;
    uint32_t distanceTraveled;
    uint32_t elapsedSeconds;
    uint32_t routeRemaining;
    bool hasRouteRemaining;
    double latitude;
    double longitude;
    uint16_t heading;
    bool headingValid;
    float hdop;
    float pdop;
    float vdop;
    uint8_t satInView;
    char sunriseHour[6];
    char sunsetHour[6];
    int UTC;
  } gpsData{};
  GpsSampleTiming presentationSample{};

  struct SV {
    bool active;
    uint8_t satNum;
    uint8_t elev;
    uint16_t azim;
    uint8_t snr;
    uint16_t posX;
    uint16_t posY;
    char talker_id[3];
  } satTracker[MAX_SATELLITES];

private:
  uint16_t previousSpeed;
  int16_t previousAltitude;
  double previousLatitude;
  double previousLongitude;
  float previousHdop;
  float previousPdop;
  float previousVdop;
};
