#pragma once

#include <Arduino.h>
#include <SD.h>
#include <lvgl.h>

struct DeviceMapSettings {
  uint8_t minPolygonSize = 0;
  uint8_t detailLevel = 2;
  uint8_t routeLineWidth = 4;
  uint8_t displayRotation = 0;
  uint8_t mapRotationMode = 0;
  uint8_t zoomLevel = 2;
  uint32_t visibilityMask = 0xFFFFFFFF;
};

class DeviceMapRenderer {
public:
  void init(lv_obj_t *parent, uint16_t width, uint16_t height);
  void setVisible(bool visible);
  void toggleVisible();
  bool isVisible() const { return mapVisible; }

  void setSdAvailable(bool available) { sdAvailable = available; }
  void setRouteGeometry(const uint8_t *data, size_t len);
  void clearRoute();
  void setGpsPosition(int32_t latMicro, int32_t lonMicro, uint16_t headingDeg);
  void setSetting(uint8_t settingId, int32_t value);
  void requestRedraw();
  void update();

private:
  struct GeoPoint {
    int32_t latMicro = 0;
    int32_t lonMicro = 0;
  };

  static constexpr size_t MAX_ROUTE_POINTS = 96;
  static constexpr uint8_t MAPBLOCK_SIZE_BITS = 12;
  static constexpr uint8_t MAPFOLDER_SIZE_BITS = 4;
  static constexpr int32_t MAPBLOCK_SIZE = 1 << MAPBLOCK_SIZE_BITS;
  static constexpr int32_t MAPBLOCK_MASK = MAPBLOCK_SIZE - 1;
  static constexpr int32_t MAPFOLDER_MASK = (1 << MAPFOLDER_SIZE_BITS) - 1;

  lv_obj_t *canvas = nullptr;
  lv_color_t *canvasBuffer = nullptr;
  uint16_t canvasWidth = 0;
  uint16_t canvasHeight = 0;
  bool mapVisible = false;
  bool sdAvailable = false;
  volatile bool redrawRequested = true;

  portMUX_TYPE stateMux = portMUX_INITIALIZER_UNLOCKED;
  DeviceMapSettings settings;
  GeoPoint routePoints[MAX_ROUTE_POINTS];
  size_t routePointCount = 0;
  GeoPoint gpsPoint;
  bool hasGpsPoint = false;
  uint16_t gpsHeadingDeg = 0;

  void draw();
  void drawNoMapMessage();
  void drawMapBlocks(int32_t centerX, int32_t centerY, double metersPerPixel);
  void drawBinaryMapBlock(const char *path, int32_t blockMinX, int32_t blockMinY,
                          int32_t centerX, int32_t centerY,
                          double metersPerPixel);
  void skipBinaryFeature(File &file, uint16_t pointCount);
  void drawRouteOverlay(int32_t centerX, int32_t centerY, double metersPerPixel);
  void drawGpsMarker(int32_t centerX, int32_t centerY, double metersPerPixel);

  bool readInt16(File &file, int16_t &value);
  bool readUInt16(File &file, uint16_t &value);
  bool readUInt8(File &file, uint8_t &value);
  bool featureVisible(uint8_t typeId) const;
  bool findBlockPath(int32_t blockMinX, int32_t blockMinY, char *path,
                     size_t pathSize) const;
  double metersPerPixel() const;
  int16_t screenX(int32_t mercatorX, int32_t centerX, double metersPerPixel) const;
  int16_t screenY(int32_t mercatorY, int32_t centerY, double metersPerPixel) const;
  static int32_t lonToMercatorX(int32_t lonMicro);
  static int32_t latToMercatorY(int32_t latMicro);
  static uint16_t clampRgb565(uint16_t color);
};

extern DeviceMapRenderer deviceMapRenderer;

