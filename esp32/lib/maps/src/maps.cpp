/**
 * @file maps.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com) - Render Maps
 * @author @aresta - https://github.com/aresta/ESP32_GPS - Vector Maps
 * @brief  Maps draw class
 * @version 0.2.2
 * @date 2025-05
 */

#include "maps.hpp"
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../gui/src/guiLayout.hpp"
// #include "../../compass/compass.hpp"
extern Gps gps;
extern Storage storage;
extern std::vector<wayPoint> trackData;
const char *TAG PROGMEM = "Maps";

#ifdef WAVESHARE_MAPIO_TIMING_LOG
#define MAPIO_LOG(...) Serial.printf(__VA_ARGS__)
#define MAPIO_TIME_MS() millis()
#else
#define MAPIO_LOG(...)                                                        \
  do {                                                                        \
  } while (0)
#define MAPIO_TIME_MS() 0
#endif

#include "../../gui/src/mainScr.hpp"
#include "../../route_overlay/route_overlay.hpp"
#include <esp_heap_caps.h>

enum class VisibilityClass : uint8_t {
  Always,
  MajorRoad,
  LocalStreet,
  Building,
  GreenSpace,
  Water,
  Path,
  Rail,
  OtherArea,
};

static inline bool isClassVisible(VisibilityClass visibilityClass,
                                  const MapRenderSettings &settings) {
  if (visibilityClass == VisibilityClass::Always)
    return true;

  uint32_t visMask = settings.visibilityMask;
  switch (visibilityClass) {
  case VisibilityClass::MajorRoad:
    return (visMask & (1 << 3)) != 0;
  case VisibilityClass::LocalStreet:
    return (visMask & (1 << 4)) != 0;
  case VisibilityClass::Building:
    return (visMask & (1 << 0)) != 0;
  case VisibilityClass::GreenSpace:
    return (visMask & (1 << 1)) != 0;
  case VisibilityClass::Water:
    return (visMask & (1 << 5)) != 0;
  case VisibilityClass::Path:
    return (visMask & (1 << 2)) != 0;
  case VisibilityClass::Rail:
    return (visMask & (1 << 6)) != 0;
  case VisibilityClass::OtherArea:
    return (visMask & (1 << 7)) != 0;
  case VisibilityClass::Always:
  default:
    return true;
  }
}

static inline VisibilityClass visibilityClassForTypeId(uint8_t typeId) {
  if (typeId >= 1 && typeId <= 5)
    return VisibilityClass::MajorRoad;
  if (typeId >= 6 && typeId < 50)
    return VisibilityClass::LocalStreet;
  if (typeId >= 50 && typeId < 100)
    return VisibilityClass::Path;
  if (typeId >= 100 && typeId < 150)
    return VisibilityClass::Building;
  if (typeId == 152 || typeId == 153)
    return VisibilityClass::Water;
  if (typeId >= 150 && typeId < 200)
    return VisibilityClass::GreenSpace;
  if (typeId == 210)
    return VisibilityClass::Rail;
  if (typeId >= 200)
    return VisibilityClass::OtherArea;
  return VisibilityClass::Always;
}

static inline VisibilityClass legacyPolygonVisibilityClass(uint16_t color) {
  switch (color) {
  case 0xAD55: // grayclear
  case 0xDED6: // apple_building
    return VisibilityClass::Building;
  case 0x9F93: // greenclear
  case 0xCF6E: // greenclear2
  case 0x76EE: // green
  case 0xB713: // apple_park
  case 0xD757: // apple_farm
    return VisibilityClass::GreenSpace;
  case 0x6D3E: // blueclear
  case 0x227E: // blue
  case 0xFFF1: // yellow/beach
  case 0xA6DE: // apple_water
    return VisibilityClass::Water;
  case 0xD69A: // grayclear2
  case 0xC618: // apple_land_gray
    return VisibilityClass::OtherArea;
  default:
    return VisibilityClass::Always;
  }
}

static inline VisibilityClass legacyLineVisibilityClass(uint16_t color,
                                                        uint8_t width) {
  if (color == 0xFA45 || color == 0xAB00 || color == 0xA42B)
    return VisibilityClass::Path;
  if (color == 0x632C && width <= 1)
    return VisibilityClass::Path;
  if ((color == 0xAA1F || color == 0xA6DE) && width <= 2)
    return VisibilityClass::Water;
  if (color == 0x0000 || (color == 0x632C && width >= 2))
    return VisibilityClass::Rail;
  if ((color == 0xFFF1 || color == 0xFF36 || color == 0xFCC2 ||
       color == 0xF567) &&
      width >= 5)
    return VisibilityClass::MajorRoad;
  if (color == 0xFFFF && width >= 3)
    return VisibilityClass::LocalStreet;
  if ((color == 0xFCC2 || color == 0xF567) && width <= 3)
    return VisibilityClass::Path;
  return VisibilityClass::Always;
}

// Helper: Check if a typeId is visible based on detail level and visibilityMask.
// Bits: 0 buildings, 1 green space, 2 paths, 3 major roads, 4 local streets,
// 5 water, 6 rail, 7 other areas.
static inline bool isTypeVisible(uint8_t typeId,
                                 const MapRenderSettings &settings) {
  if (typeId == 0)
    return true; // Unknown types always visible
  return isClassVisible(visibilityClassForTypeId(typeId), settings);
}

static inline uint8_t detailPolygonSizeFloor(uint8_t detailLevel) {
  switch (detailLevel) {
  case 0:
    return 24;
  case 1:
    return 12;
  default:
    return 0;
  }
}

static inline uint8_t effectiveMinPolygonSize(
    const MapRenderSettings &settings) {
  return std::max(settings.minPolygonSize,
                  detailPolygonSizeFloor(settings.detailLevel));
}

static inline bool isPolygonVisible(uint8_t typeId, uint16_t color,
                                    const MapRenderSettings &settings) {
  if (typeId != 0)
    return isTypeVisible(typeId, settings);
  return isClassVisible(legacyPolygonVisibilityClass(color), settings);
}

static inline bool isLineVisible(uint8_t typeId, uint16_t color, uint8_t width,
                                 const MapRenderSettings &settings) {
  if (typeId != 0)
    return isTypeVisible(typeId, settings);
  return isClassVisible(legacyLineVisibilityClass(color, width), settings);
}

static inline bool isRouteOverlayVisible(const MapRenderSettings &settings) {
  return (settings.visibilityMask & (1 << 8)) != 0;
}

static inline bool isCurrentPositionVisible(const MapRenderSettings &settings) {
  return (settings.visibilityMask & (1 << 9)) != 0;
}

static inline bool shouldBoostLineWidth(uint8_t typeId, uint8_t styleWidth) {
  if (typeId >= 1 && typeId < 100)
    return true;

  // Older/unknown map blocks may not carry type IDs. In our styles, ordinary
  // roads are 3px or wider, while waterways/rail/coastline are normally 1-2px.
  return typeId == 0 && styleWidth >= 3;
}

static void *bufMapTemp = nullptr;
static void *bufMapIcon = nullptr;
static void *bufArrow = nullptr;

static void *ensureArrowBuffer() {
  if (bufArrow != nullptr)
    return bufArrow;

  const size_t arrowStride =
      lv_draw_buf_width_to_stride(48, LV_COLOR_FORMAT_ARGB8888);
  const size_t arrowSize = arrowStride * 48;
  bufArrow = heap_caps_malloc(arrowSize, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  const char *source = "internal";
  if (bufArrow == nullptr) {
    bufArrow = heap_caps_malloc(arrowSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    source = "psram";
  }
  ESP_LOGI(TAG, "MapBuff: arrow ARGB stride=%u size=%u ptr=%p source=%s",
           (unsigned)arrowStride, (unsigned)arrowSize, bufArrow, source);
  return bufArrow;
}

static void plotMarkerPixel(lv_obj_t *canvas, int16_t x, int16_t y,
                            lv_color_t color) {
  if (x < 0 || x >= 48 || y < 0 || y >= 48)
    return;

  lv_canvas_set_px(canvas, x, y, color, LV_OPA_COVER);
}

static void drawThickMarkerLine(lv_obj_t *canvas, int16_t x0, int16_t y0,
                                int16_t x1, int16_t y1, lv_color_t color,
                                uint8_t thickness) {
  int16_t dx = abs(x1 - x0);
  int16_t sx = x0 < x1 ? 1 : -1;
  int16_t dy = -abs(y1 - y0);
  int16_t sy = y0 < y1 ? 1 : -1;
  int16_t err = dx + dy;
  const int16_t radius = thickness / 2;

  while (true) {
    for (int16_t oy = -radius; oy <= radius; oy++) {
      for (int16_t ox = -radius; ox <= radius; ox++) {
        if (ox * ox + oy * oy <= radius * radius)
          plotMarkerPixel(canvas, x0 + ox, y0 + oy, color);
      }
    }

    if (x0 == x1 && y0 == y1)
      break;

    int16_t e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x0 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y0 += sy;
    }
  }
}

static uint8_t lineClipOutCode(float x, float y, float minX, float minY,
                               float maxX, float maxY) {
  uint8_t code = 0;
  if (x < minX)
    code |= 1;
  else if (x > maxX)
    code |= 2;
  if (y < minY)
    code |= 4;
  else if (y > maxY)
    code |= 8;
  return code;
}

static bool clipLineToRect(int16_t &x1, int16_t &y1, int16_t &x2, int16_t &y2,
                           int32_t minX, int32_t minY, int32_t maxX,
                           int32_t maxY) {
  float fx1 = x1;
  float fy1 = y1;
  float fx2 = x2;
  float fy2 = y2;
  uint8_t code1 = lineClipOutCode(fx1, fy1, minX, minY, maxX, maxY);
  uint8_t code2 = lineClipOutCode(fx2, fy2, minX, minY, maxX, maxY);

  while (true) {
    if ((code1 | code2) == 0) {
      x1 = (int16_t)roundf(fx1);
      y1 = (int16_t)roundf(fy1);
      x2 = (int16_t)roundf(fx2);
      y2 = (int16_t)roundf(fy2);
      return true;
    }

    if ((code1 & code2) != 0)
      return false;

    uint8_t outsideCode = code1 != 0 ? code1 : code2;
    float x = 0;
    float y = 0;

    if (outsideCode & 8) {
      if (fy2 == fy1)
        return false;
      x = fx1 + (fx2 - fx1) * (maxY - fy1) / (fy2 - fy1);
      y = maxY;
    } else if (outsideCode & 4) {
      if (fy2 == fy1)
        return false;
      x = fx1 + (fx2 - fx1) * (minY - fy1) / (fy2 - fy1);
      y = minY;
    } else if (outsideCode & 2) {
      if (fx2 == fx1)
        return false;
      y = fy1 + (fy2 - fy1) * (maxX - fx1) / (fx2 - fx1);
      x = maxX;
    } else {
      if (fx2 == fx1)
        return false;
      y = fy1 + (fy2 - fy1) * (minX - fx1) / (fx2 - fx1);
      x = minX;
    }

    if (outsideCode == code1) {
      fx1 = x;
      fy1 = y;
      code1 = lineClipOutCode(fx1, fy1, minX, minY, maxX, maxY);
    } else {
      fx2 = x;
      fy2 = y;
      code2 = lineClipOutCode(fx2, fy2, minX, minY, maxX, maxY);
    }
  }
}

static bool isInsideNavigationMarker(int16_t x, int16_t y) {
  constexpr int16_t px[] = {24, 38, 24, 10};
  constexpr int16_t py[] = {4, 42, 34, 42};
  bool inside = false;

  for (uint8_t i = 0, j = 3; i < 4; j = i++) {
    const bool crosses = ((py[i] > y) != (py[j] > y)) &&
                         (x < (px[j] - px[i]) * (y - py[i]) /
                                      (py[j] - py[i]) +
                                  px[i]);
    if (crosses)
      inside = !inside;
  }

  return inside;
}

static void drawNavigationMarker(lv_obj_t *canvas) {
  if (!canvas)
    return;

  lv_canvas_fill_bg(canvas, lv_color_hex(0x000000), LV_OPA_TRANSP);

  const lv_color_t color = lv_color_white();

  // 24x24 lucide-style navigation polygon scaled to this 48x48 marker:
  // points="12 2 19 21 12 17 5 21 12 2"
  for (int16_t y = 0; y < 48; y++) {
    for (int16_t x = 0; x < 48; x++) {
      if (isInsideNavigationMarker(x, y))
        plotMarkerPixel(canvas, x, y, color);
    }
  }

  // Stroke the edges in the same color so the filled marker stays crisp.
  constexpr uint8_t strokeWidth = 3;
  drawThickMarkerLine(canvas, 24, 4, 38, 42, color, strokeWidth);
  drawThickMarkerLine(canvas, 38, 42, 24, 34, color, strokeWidth);
  drawThickMarkerLine(canvas, 24, 34, 10, 42, color, strokeWidth);
  drawThickMarkerLine(canvas, 10, 42, 24, 4, color, strokeWidth);

  lv_obj_invalidate(canvas);
}

static void drawPositionDotMarker(lv_obj_t *canvas) {
  if (!canvas)
    return;

  lv_canvas_fill_bg(canvas, lv_color_hex(0x000000), LV_OPA_TRANSP);

  const lv_color_t color = lv_color_white();
  constexpr int16_t center = 24;
  constexpr int16_t radius = 8;

  for (int16_t y = center - radius; y <= center + radius; y++) {
    for (int16_t x = center - radius; x <= center + radius; x++) {
      const int16_t dx = x - center;
      const int16_t dy = y - center;
      if (dx * dx + dy * dy <= radius * radius)
        plotMarkerPixel(canvas, x, y, color);
    }
  }

  lv_obj_invalidate(canvas);
}

static uint8_t currentMarkerScale() {
  return (uint8_t)std::min(std::max((int)mapRenderSettings.positionMarkerScale,
                                    1),
                           5);
}

static void applyNavigationMarkerScale(lv_obj_t *canvas) {
  if (!canvas)
    return;

  const int32_t scale = currentMarkerScale() * 256;
  lv_obj_set_style_transform_pivot_x(canvas, 24, 0);
  lv_obj_set_style_transform_pivot_y(canvas, 24, 0);
  lv_obj_set_style_transform_scale_x(canvas, scale, 0);
  lv_obj_set_style_transform_scale_y(canvas, scale, 0);
}

static void updateCurrentPositionMarker(lv_obj_t *canvas, bool force = false) {
  if (!canvas || bufArrow == nullptr)
    return;

  static bool hasLastShape = false;
  static bool lastWasNavigating = false;
  static uint8_t lastScale = 0;

  const bool isNavigating = routeOverlay.hasRoute();
  const uint8_t scale = currentMarkerScale();
  if (!force && hasLastShape && lastWasNavigating == isNavigating &&
      lastScale == scale) {
    applyNavigationMarkerScale(canvas);
    return;
  }

  if (isNavigating) {
    drawNavigationMarker(canvas);
  } else {
    drawPositionDotMarker(canvas);
  }

  applyNavigationMarkerScale(canvas);
  hasLastShape = true;
  lastWasNavigating = isNavigating;
  lastScale = scale;
  log_i("Position marker updated: %s scale=%u",
        isNavigating ? "navigation arrow" : "location dot", scale);
}

static int16_t mapAnchorXForWidth(uint16_t width) {
  return gui_layout::mapAnchorX(width);
}

static int16_t mapAnchorYForHeight(uint16_t height) {
  return gui_layout::mapAnchorY(height);
}

extern Point16::Point16(char *coordsPair) {
  char *next;
  x = (int16_t)round(strtod(
      coordsPair, &next)); // 1st coord // TODO: change by strtol and test
  y = (int16_t)round(strtod(++next, NULL)); // 2nd coord
}

bool BBox::containsPoint(const Point32 p) const {
  return p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y;
}

bool BBox::intersects(const BBox b) const {
  if (b.min.x > max.x || b.max.x < min.x || b.min.y > max.y || b.max.y < min.y)
    return false;
  return true;
}

/**
 * @brief Map Class constructor
 *
 */
Maps::Maps() {}

// Render Map Private section

#ifndef TFT_BLACK
#define TFT_BLACK 0x0000
#endif
#ifndef TFT_WHITE
#define TFT_WHITE 0xFFFF
#endif
#ifndef TFT_BLUE
#define TFT_BLUE 0x001F
#endif
#ifndef TFT_RED
#define TFT_RED 0xF800
#endif
#ifndef TFT_LIGHTGREY
#define TFT_LIGHTGREY 0xC618
#endif
#ifndef BACKGROUND_COLOR
#define BACKGROUND_COLOR 0x0000
#endif

// Stubbed out render map functions for now to focus on vector maps
uint16_t Maps::lon2posx(float f_lon, uint8_t zoom, uint16_t tileSize) {
  return 0;
}
uint16_t Maps::lat2posy(float f_lat, uint8_t zoom, uint16_t tileSize) {
  return 0;
}

/**
 * @brief Get TileX for OpenStreetMap files
 *
 * @param f_lon -> longitude
 * @param zoom -> zoom
 * @return X value (folder)
 */
uint32_t Maps::lon2tilex(double f_lon, uint8_t zoom) {
  double rawTile = (f_lon + 180.0) / 360.0 * pow(2.0, zoom);
  rawTile += 1e-6;
  return (uint32_t)(floor(rawTile));
}

/**
 * @brief Get TileY for OpenStreetMap files
 *
 * @param f_lat -> latitude
 * @param zoom  -> zoom
 * @return Y value (file)
 */
uint32_t Maps::lat2tiley(double f_lat, uint8_t zoom) {
  double rawTile =
      (1.0 - log(tan(f_lat * M_PI / 180.0) + 1.0 / cos(f_lat * M_PI / 180.0)) /
                 M_PI) /
      2.0 * pow(2.0, zoom);
  rawTile += 1e-6;
  return (uint32_t)(floor(rawTile));
}

/**
 * @brief Get Longitude from OpenStreetMap files
 *
 * @param tileX -> tile X
 * @param zoom  -> zoom
 * @return longitude
 */
double Maps::tilex2lon(uint32_t tileX, uint8_t zoom) {
  return tileX / pow(2.0, zoom) * 360.0 - 180.0;
}

/**
 * @brief Get Latitude from OpenStreetMap files
 *
 * @param tileX -> tile Y
 * @param zoom  -> zoom
 * @return latitude
 */
double Maps::tiley2lat(uint32_t tileY, uint8_t zoom) {
  double n = M_PI - 2.0 * M_PI * tileY / pow(2.0, zoom);
  return 180.0 / M_PI * atan(sinh(n));
}

/**
 * @brief Get the map tile structure from GPS Coordinates
 *
 * @param lon -> Longitude
 * @param lat -> Latitude
 * @param zoomLevel -> zoom level
 * @param offsetX -> Tile Offset X
 * @param offsetY -> Tile Offset Y
 * @return MapTile -> Map Tile structure
 */
// Maps::MapTile Maps::getMapTile(double lon, double lat, uint8_t zoomLevel,
//                                int8_t offsetX, int8_t offsetY) {
//   char tileFile[255];
//   uint32_t x = Maps::lon2tilex(lon, zoomLevel) + offsetX;
//   uint32_t y = Maps::lat2tiley(lat, zoomLevel) + offsetY;
//
//   sprintf(tileFile, mapRenderFolder, zoomLevel, x, y);
//   MapTile data;
//   strcpy(data.file, tileFile);
//   data.tilex = x;
//   data.tiley = y;
//   data.zoom = zoomLevel;
//   data.lat = lat;
//   data.lon = lon;
//   return data;
// }

Maps::MapTile Maps::getMapTile(double lon, double lat, uint8_t zoomLevel,
                               int8_t offsetX, int8_t offsetY) {
  // Stub or implementation for vector maps if needed?
  // Vector maps use memory blocks, not "tiles" in the same way
  // (renderMapTileSize). But generateVectorMap calls getMapBlocks which
  // computes map blocks. The original getMapTile was for RENDER maps (images).
  // We can return an empty tile or stub it properly.
  // Since we stubbed it at the top, we should keep ONE definition.
  // I will just use the implementation here (stubbed) and remove the top one or
  // vice versa. In the first chunk I am REMOVING the stub from the top (lines
  // 51-81 in previous edit). Wait, I see I replaced lines 54-64 in the previous
  // chunk. I REMOVED the getMapTile stub from the top block in the first chunk
  // above. So I should keep this one but stub it out or make it useful?
  // Actually, I should probably just comment it out effectively or return valid
  // dummy.
  return {};
}

// Vector Map Private section

/**
 * @brief Get pixel Y position from OpenStreetMap Vector map latitude
 *
 * @param lat -> latitude
 * @return Y position
 */
double Maps::lat2y(double lat) {
  return log(tan(DEG2RAD(lat) / 2 + M_PI / 4)) * EARTH_RADIUS;
}

/**
 * @brief Get pixel X position from OpenStreetMap Vector map longitude
 *
 * @param lon -> longitude
 * @return X position
 */
double Maps::lon2x(double lon) { return DEG2RAD(lon) * EARTH_RADIUS; }

/**
 * @brief Get longitude from X position in Vector Map (Mercator projection)
 *
 * @param x -> X position
 * @return longitude
 */
double Maps::mercatorX2lon(double x) {
  return (x / EARTH_RADIUS) * (180.0 / M_PI);
}

/**
 * @brief Get latitude from Y position in Vector Map (Mercator projection)
 *
 * @param y -> Y position
 * @return latitude
 */
double Maps::mercatorY2lat(double y) {
  return (atan(sinh(y / EARTH_RADIUS))) * (180.0 / M_PI);
}

/**
 * @brief Points to screen coordinates
 *
 * @param pxy
 * @param screenCenterxy
 * @return int16_t
 */
int16_t Maps::toScreenCoord(const int32_t pxy, const int32_t screenCenterxy) {
  int16_t result = round((double)(pxy - screenCenterxy) / zoom) +
                   (double)Maps::mapScrWidth / 2;
  return result;
}

/**
 * @brief Returns int16 or 0 if empty
 *
 * @param file
 * @return int16_t
 */
int16_t Maps::parseInt16(char *file) {
  char num[16];
  uint8_t i;
  char c;
  i = 0;
  c = file[Maps::idx];
  if (c == '\n')
    return 0;
  while (c >= '0' && c <= '9') {
    assert(i < 15);
    c = file[Maps::idx];
    num[i] = c;
    Maps::idx++;
    i++;

    c = file[Maps::idx];
  }
  num[i] = '\0';

  if (c != ';' && c != ',' && c != '\n') {
    ESP_LOGE(TAG, "parseInt16 error: %c %i", c, c);
    ESP_LOGE(TAG, "Num: [%s]", num);
    while (1)
      ;
  }
  try {
    Maps::idx++;
    return std::stoi(num);
  } catch (std::invalid_argument) {
    ESP_LOGE(TAG, "parseInt16 invalid_argument: [%c] [%s]", c, num);
  } catch (std::out_of_range) {
    ESP_LOGE(TAG, "parseInt16 out_of_range: [%c] [%s]", c, num);
  }
  return -1;
}

/**
 * @brief Returns the string until terminator char or newline. The terminator
 * character is not included but consumed from stream.
 *
 * @param file
 * @param terminator
 * @param str
 */
void Maps::parseStrUntil(char *file, char terminator, char *str) {
  uint8_t i;
  char c;
  i = 0;
  c = file[Maps::idx];
  while (c != terminator && c != '\n') {
    assert(i < 29);
    str[i] = c;
    Maps::idx++;
    i++;
    c = file[Maps::idx];
  }
  str[i] = '\0';
  Maps::idx++;
}

/**
 * @brief Parse vector file to coords
 *
 * @param file
 * @param points
 */
void Maps::parseCoords(char *file,
                       std::vector<Point16, PsramAllocator<Point16>> &points) {
  char str[30];
  assert(points.size() == 0);
  Point16 point;
  while (true) {
    try {
      parseStrUntil(file, ',', str);
      if (str[0] == '\0')
        break;
      point.x = (int16_t)std::stoi(str);
      parseStrUntil(file, ';', str);
      assert(str[0] != '\0');
      point.y = (int16_t)std::stoi(str);
    } catch (std::invalid_argument) {
      ESP_LOGE(TAG, "parseCoords invalid_argument: %s", str);
    } catch (std::out_of_range) {
      ESP_LOGE(TAG, "parseCoords out_of_range: %s", str);
    }
    points.push_back(point);
  }
}

/**
 * @brief Parse Mapbox
 *
 * @param str
 * @return BBox
 */
BBox Maps::parseBbox(String str) {
  char *next;
  int32_t x1 = (int32_t)strtol(str.c_str(), &next, 10);
  int32_t y1 = (int32_t)strtol(++next, &next, 10);
  int32_t x2 = (int32_t)strtol(++next, &next, 10);
  int32_t y2 = (int32_t)strtol(++next, NULL, 10);
  return BBox(Point32(x1, y1), Point32(x2, y2));
}

/**
 * @brief Read vector map file to memory block
 *
 * @param fileName
 * @return MapBlock*
 */
Maps::MapBlock *Maps::readMapBlock(String fileName) {
  ESP_LOGI(TAG, "readMapBlock: %s", fileName.c_str());
  char str[30];
  MapBlock *mblock = new MapBlock();
  const uint32_t blockStartMs = MAPIO_TIME_MS();

  // Try Binary first (.fmb) then ASCII (.fmp)
  std::string filePath = fileName.c_str() + std::string(".fmb");
  bool isBinary = true;

  const uint32_t openStartMs = MAPIO_TIME_MS();
  int fd = ::open(filePath.c_str(), O_RDONLY);

  if (fd < 0) {
    filePath = fileName.c_str() + std::string(".fmp");
    isBinary = false;
    fd = ::open(filePath.c_str(), O_RDONLY);
  }
  const uint32_t openMs = MAPIO_TIME_MS() - openStartMs;

  if (fd < 0) {
    ESP_LOGE(TAG, "Failed to open file: %s", filePath.c_str());
    MAPIO_LOG("MAPIO: block-open ok=0 base=%s openMs=%lu\n", fileName.c_str(),
              (unsigned long)openMs);
    Maps::isMapFound = false;
    mblock->inView = false;
    return mblock;
  } else {
    ESP_LOGI(TAG, "Loading %s (%s)", filePath.c_str(),
             isBinary ? "Binary" : "ASCII");
    // Get file size
    struct stat st;
    const uint32_t statStartMs = MAPIO_TIME_MS();
    if (fstat(fd, &st) != 0) {
      ESP_LOGE(TAG, "Failed to get file size: %s", filePath.c_str());
      ::close(fd);
      MAPIO_LOG("MAPIO: block-stat ok=0 file=%s openMs=%lu statMs=%lu\n",
                filePath.c_str(), (unsigned long)openMs,
                (unsigned long)(MAPIO_TIME_MS() - statStartMs));
      Maps::isMapFound = false;
      mblock->inView = false;
      return mblock;
    }
    const uint32_t statMs = MAPIO_TIME_MS() - statStartMs;
    size_t fileSize = st.st_size;

#ifdef BOARD_HAS_PSRAM
    char *file = (char *)heap_caps_malloc(fileSize + 1, MALLOC_CAP_SPIRAM);
#else
    char *file = (char *)malloc(fileSize + 1);
#endif

    if (!file) {
      ESP_LOGE(TAG, "Failed to allocate memory for map file (%u bytes)",
               fileSize);
      Maps::isMapFound = false;
      ::close(fd);
      return mblock;
    }

    const uint32_t readStartMs = MAPIO_TIME_MS();
    ssize_t bytesRead = ::read(fd, file, fileSize);
    ::close(fd);
    const uint32_t readMs = MAPIO_TIME_MS() - readStartMs;

    if (bytesRead != (ssize_t)fileSize) {
      ESP_LOGE(TAG, "Failed to read file completely: got %d of %u bytes",
               bytesRead, fileSize);
      MAPIO_LOG("MAPIO: block-read ok=0 file=%s size=%u got=%d "
                "openMs=%lu statMs=%lu readMs=%lu\n",
                filePath.c_str(), (unsigned)fileSize, (int)bytesRead,
                (unsigned long)openMs, (unsigned long)statMs,
                (unsigned long)readMs);
      free(file);
      Maps::isMapFound = false;
      return mblock;
    }

    if (isBinary) {
      const uint32_t parseStartMs = MAPIO_TIME_MS();
      delete mblock; // readMapBlockBinary creates a new one
      mblock = readMapBlockBinary(file, fileSize);
      const uint32_t parseGridMs = MAPIO_TIME_MS() - parseStartMs;
      MAPIO_LOG("MAPIO: block ok=1 file=%s format=binary size=%u "
                "openMs=%lu statMs=%lu readMs=%lu parseGridMs=%lu "
                "totalMs=%lu polygons=%u lines=%u\n",
                filePath.c_str(), (unsigned)fileSize, (unsigned long)openMs,
                (unsigned long)statMs, (unsigned long)readMs,
                (unsigned long)parseGridMs,
                (unsigned long)(MAPIO_TIME_MS() - blockStartMs),
                (unsigned)mblock->polygons.size(),
                (unsigned)mblock->polylines.size());
      free(file);
      return mblock;
    }

    file[fileSize] = '\0'; // Null terminate
    Maps::isMapFound = true;

    uint32_t line = 0;
    Maps::idx = 0;
    const uint32_t parseStartMs = MAPIO_TIME_MS();

    // read polygons
    Maps::parseStrUntil(file, ':', str);
    if (strcmp(str, "Polygons") != 0) {
      ESP_LOGE(TAG, "Map error. Expected Polygons instead of: %s", str);
      free(file);
      Maps::isMapFound = false;
      return mblock;
    }

    int16_t count = Maps::parseInt16(file);
    if (count <= 0) {
      ESP_LOGW(TAG, "No polygons in map block: %s", fileName.c_str());
      // Continue to lines anyway, or return? For now let's be safe.
      if (count < 0) {
        // fd already closed after read()
        free(file);
        Maps::isMapFound = false;
        return mblock;
      }
    }
    line++;

    uint32_t totalPoints = 0;
    Polygon polygon;
    Point16 p;
    while (count > 0) {
      Maps::parseStrUntil(file, '\n', str); // color
      if (str[0] != '0' || str[1] != 'x') {
        ESP_LOGE(TAG, "Expected hex color at line %i: %s", line, str);
        break;
      }
      polygon.color = (uint16_t)std::stoul(str, nullptr, 16);
      line++;

      Maps::parseStrUntil(file, '\n', str); // maxZoom
      polygon.maxZoom = str[0] ? (uint8_t)std::stoi(str) : MAX_ZOOM;
      line++;

      Maps::parseStrUntil(file, ':', str);
      if (strcmp(str, "bbox") != 0) {
        ESP_LOGE(TAG, "bbox error tag. Line %i : %s", line, str);
        break;
      }
      polygon.bbox.min.x = Maps::parseInt16(file);
      polygon.bbox.min.y = Maps::parseInt16(file);
      polygon.bbox.max.x = Maps::parseInt16(file);
      polygon.bbox.max.y = Maps::parseInt16(file);

      line++;
      polygon.points.clear();
      Maps::parseStrUntil(file, ':', str);
      if (strcmp(str, "coords") != 0) {
        ESP_LOGE(TAG, "coords error tag. Line %i : %s", line, str);
        break;
      }

      Maps::parseCoords(file, polygon.points);
      line++;
      mblock->polygons.push_back(polygon);
      totalPoints += polygon.points.size();
      count--;
    }

    // read lines
    Maps::parseStrUntil(file, ':', str);
    if (strcmp(str, "Polylines") != 0) {
      ESP_LOGW(TAG, "Expected Polylines instead of: %s", str);
    } else {
      count = Maps::parseInt16(file);
      line++;

      Polyline polyline;
      while (count > 0) {
        Maps::parseStrUntil(file, '\n', str); // color
        if (str[0] != '0' || str[1] != 'x')
          break;
        polyline.color = (uint16_t)std::stoul(str, nullptr, 16);
        line++;
        Maps::parseStrUntil(file, '\n', str); // width
        polyline.width = str[0] ? (uint8_t)std::stoi(str) : 1;
        line++;
        Maps::parseStrUntil(file, '\n', str); // maxZoom
        polyline.maxZoom = str[0] ? (uint8_t)std::stoi(str) : MAX_ZOOM;
        line++;

        Maps::parseStrUntil(file, ':', str);
        if (strcmp(str, "bbox") != 0)
          break;

        polyline.bbox.min.x = Maps::parseInt16(file);
        polyline.bbox.min.y = Maps::parseInt16(file);
        polyline.bbox.max.x = Maps::parseInt16(file);
        polyline.bbox.max.y = Maps::parseInt16(file);

        line++;

        polyline.points.clear();
        Maps::parseStrUntil(file, ':', str);
        if (strcmp(str, "coords") != 0)
          break;
        Maps::parseCoords(file, polyline.points);
        line++;
        mblock->polylines.push_back(polyline);
        totalPoints += polyline.points.size();
        count--;
      }
    }
    // File descriptor was already closed via ::close(fd) after reading
    free(file);
    // Build spatial grid for polygon culling optimization
    const uint32_t gridStartMs = MAPIO_TIME_MS();
    buildPolygonGrid(mblock);
    const uint32_t gridMs = MAPIO_TIME_MS() - gridStartMs;
    MAPIO_LOG("MAPIO: block ok=1 file=%s format=ascii size=%u openMs=%lu "
              "statMs=%lu readMs=%lu parseMs=%lu gridMs=%lu totalMs=%lu "
              "polygons=%u lines=%u\n",
              filePath.c_str(), (unsigned)fileSize, (unsigned long)openMs,
              (unsigned long)statMs, (unsigned long)readMs,
              (unsigned long)(gridStartMs - parseStartMs),
              (unsigned long)gridMs,
              (unsigned long)(MAPIO_TIME_MS() - blockStartMs),
              (unsigned)mblock->polygons.size(),
              (unsigned)mblock->polylines.size());
    return mblock;
  }
}

/**
 * @brief High performance binary map block reader
 * Supports both v1 (legacy) and v2 (with typeId) formats
 */
Maps::MapBlock *Maps::readMapBlockBinary(char *file, size_t fileSize) {
  const uint32_t parseStartMs = MAPIO_TIME_MS();
  MapBlock *mblock = new MapBlock();
  size_t offset = 0;

  // Check Magic (first 3 bytes must be "FMB")
  if (fileSize < 4 || memcmp(file, "FMB", 3) != 0) {
    ESP_LOGE(TAG, "Invalid Binary Map Header");
    delete mblock;
    Maps::isMapFound = false;
    return new MapBlock();
  }

  // Get version from 4th byte
  uint8_t version = (uint8_t)file[3];
  bool hasTypeId = (version >= 2);
  ESP_LOGI(TAG, "Map file version: %d (typeId: %s)", version,
           hasTypeId ? "yes" : "no");
  offset += 4;

  // Polygons
  uint16_t polyCount = *(uint16_t *)(file + offset);
  offset += 2;
  mblock->polygons.reserve(polyCount);

  for (int i = 0; i < polyCount; i++) {
    Polygon poly;
    poly.color = *(uint16_t *)(file + offset);
    offset += 2;
    poly.maxZoom = *(uint8_t *)(file + offset);
    offset += 1;

    // V2: Read typeId after maxZoom
    if (hasTypeId) {
      poly.typeId = *(uint8_t *)(file + offset);
      offset += 1;
    } else {
      poly.typeId = 0; // Unknown for legacy maps
    }

    poly.bbox.min.x = *(int16_t *)(file + offset);
    offset += 2;
    poly.bbox.min.y = *(int16_t *)(file + offset);
    offset += 2;
    poly.bbox.max.x = *(int16_t *)(file + offset);
    offset += 2;
    poly.bbox.max.y = *(int16_t *)(file + offset);
    offset += 2;

    uint16_t pointCount = *(uint16_t *)(file + offset);
    offset += 2;
    poly.points.resize(pointCount);
    memcpy(poly.points.data(), file + offset, pointCount * 4);
    offset += pointCount * 4;
    mblock->polygons.push_back(poly);
  }

  // Polylines
  uint16_t lineCount = *(uint16_t *)(file + offset);
  offset += 2;
  mblock->polylines.reserve(lineCount);

  for (int i = 0; i < lineCount; i++) {
    Polyline line;
    line.color = *(uint16_t *)(file + offset);
    offset += 2;
    line.width = *(uint8_t *)(file + offset);
    offset += 1;
    line.maxZoom = *(uint8_t *)(file + offset);
    offset += 1;

    // V2: Read typeId after maxZoom
    if (hasTypeId) {
      line.typeId = *(uint8_t *)(file + offset);
      offset += 1;
    } else {
      line.typeId = 0; // Unknown for legacy maps
    }

    line.bbox.min.x = *(int16_t *)(file + offset);
    offset += 2;
    line.bbox.min.y = *(int16_t *)(file + offset);
    offset += 2;
    line.bbox.max.x = *(int16_t *)(file + offset);
    offset += 2;
    line.bbox.max.y = *(int16_t *)(file + offset);
    offset += 2;

    uint16_t pointCount = *(uint16_t *)(file + offset);
    offset += 2;
    line.points.resize(pointCount);
    memcpy(line.points.data(), file + offset, pointCount * 4);
    offset += pointCount * 4;
    mblock->polylines.push_back(line);
  }

  Maps::isMapFound = true;
  // Build spatial grid for polygon culling optimization
  const uint32_t gridStartMs = MAPIO_TIME_MS();
  buildPolygonGrid(mblock);
  const uint32_t gridMs = MAPIO_TIME_MS() - gridStartMs;
  MAPIO_LOG("MAPIO: vector-parse format=binary size=%u version=%u "
            "polygons=%u lines=%u parseMs=%lu gridMs=%lu totalMs=%lu\n",
            (unsigned)fileSize, version, (unsigned)mblock->polygons.size(),
            (unsigned)mblock->polylines.size(),
            (unsigned long)(gridStartMs - parseStartMs),
            (unsigned long)gridMs,
            (unsigned long)(MAPIO_TIME_MS() - parseStartMs));
  return mblock;
}

/**
 * @brief Build spatial grid index for polygon culling optimization.
 * Divides block into 16x16 grid cells and assigns polygon indices to cells
 * based on bounding box overlap. This reduces polygon iteration from O(n)
 * to O(cells_in_viewport * polygons_per_cell).
 *
 * @param mblock The map block to build the grid for
 */
void Maps::buildPolygonGrid(MapBlock *mblock) {
  // Initialize grid with GRID_SIZE * GRID_SIZE cells (16x16 = 256 cells)
  mblock->polygonGrid.clear();
  mblock->polygonGrid.resize(GRID_SIZE * GRID_SIZE);

  for (uint16_t i = 0; i < mblock->polygons.size(); i++) {
    const auto &poly = mblock->polygons[i];

    // Calculate which grid cells this polygon's bounding box overlaps
    // CELL_SHIFT converts from block coords (0-4095) to cell index (0-15)
    int minCX = std::max(0, (int)(poly.bbox.min.x >> CELL_SHIFT));
    int maxCX = std::min(GRID_SIZE - 1, (int)(poly.bbox.max.x >> CELL_SHIFT));
    int minCY = std::max(0, (int)(poly.bbox.min.y >> CELL_SHIFT));
    int maxCY = std::min(GRID_SIZE - 1, (int)(poly.bbox.max.y >> CELL_SHIFT));

    // Add polygon index to all overlapping cells
    for (int cy = minCY; cy <= maxCY; cy++) {
      for (int cx = minCX; cx <= maxCX; cx++) {
        mblock->polygonGrid[cy * GRID_SIZE + cx].push_back(i);
      }
    }
  }

  // Log grid stats for debugging
  size_t totalEntries = 0;
  for (const auto &cell : mblock->polygonGrid) {
    totalEntries += cell.size();
  }
  log_d("Built polygon grid: %d polygons -> %d cell entries (%.1fx expansion)",
        mblock->polygons.size(), totalEntries,
        mblock->polygons.size() > 0
            ? (float)totalEntries / mblock->polygons.size()
            : 0.0f);
}

/**
 * @brief Fill polygon routine
 *
 * @param points
 * @param color
 */
/**
 * @brief Fill polygon routine
 *
 * @param points
 * @param color
 */
void Maps::fillPolygon(const Polygon &p,
                       lv_obj_t *canvas) // scanline fill algorithm
{
  int16_t maxY = p.bbox.max.y;
  int16_t minY = p.bbox.min.y;

  // Retrieve canvas buffer and dimensions
  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  if (draw_buf == NULL)
    return;
  uint16_t *buf =
      (uint16_t *)draw_buf->data; // Assuming RGB565 and direct access
  int32_t buf_w = draw_buf->header.w;
  int32_t buf_h = draw_buf->header.h;
  uint32_t stride_pixels =
      draw_buf->header.stride / 2; // Stride in uint16 pixels

  // Clip to actual buffer dimensions, not mapScrHeight (critical for FULL
  // render mode)
  if (maxY >= buf_h)
    maxY = buf_h - 1;
  if (minY < 0)
    minY = 0;
  if (minY >= maxY)
    return;

  int16_t nodeX[p.points.size()], pixelY;

  //  Loop through the rows of the image.
  int16_t nodes, i, swap;

  if (p.points.size() < 2)
    return;

  for (pixelY = minY; pixelY <= maxY; pixelY++) { //  Build a list of nodes.
    nodes = 0;
    for (int i = 0; i < (int)p.points.size() - 1; i++) {
      if ((p.points[i].y < pixelY && p.points[i + 1].y >= pixelY) ||
          (p.points[i].y >= pixelY && p.points[i + 1].y < pixelY)) {
        nodeX[nodes++] =
            p.points[i].x + double(pixelY - p.points[i].y) /
                                double(p.points[i + 1].y - p.points[i].y) *
                                double(p.points[i + 1].x - p.points[i].x);
      }
    }
    assert(nodes < p.points.size());

    //  Sort the nodes, via a simple “Bubble” sort.
    i = 0;
    while (i < nodes - 1) { // TODO: rework
      if (nodeX[i] > nodeX[i + 1]) {
        swap = nodeX[i];
        nodeX[i] = nodeX[i + 1];
        nodeX[i + 1] = swap;
        i = 0;
      } else
        i++;
    }

    //  Fill the pixels between node pairs.
    for (i = 0; i <= nodes - 2; i += 2) {
      if (nodeX[i] > buf_w)
        break;
      if (nodeX[i + 1] < 0)
        continue;
      if (nodeX[i] < 0)
        nodeX[i] = 0;
      if (nodeX[i + 1] > buf_w)
        nodeX[i + 1] = buf_w;

      // Draw horizontal line directly to buffer (RGB565)
      int32_t y = pixelY;

      // CRITICAL FIX: Clip y to buffer height
      if (y < 0 || y >= buf_h)
        continue;

      int32_t startX = nodeX[i];
      int32_t endX = nodeX[i + 1];

      // Horizontal clipping
      if (startX >= buf_w)
        continue;
      if (endX <= 0)
        continue;

      if (endX > buf_w)
        endX = buf_w;
      if (startX < 0)
        startX = 0;

      uint16_t color = p.color; // Use color directly (RGB565)

      uint32_t row_offset = y * stride_pixels;

      for (int cx = startX; cx < endX; cx++) {
        buf[row_offset + cx] = color; // Use stride and swapped color
      }
    }
  }
}

/**
 * @brief Draw line directly to canvas buffer (Bresenham's algorithm)
 *
 * @param canvas
 * @param x1
 * @param y1
 * @param x2
 * @param y2
 * @param color (Already swapped for RGB565 if needed)
 */
void Maps::drawLine(lv_obj_t *canvas, int16_t x1, int16_t y1, int16_t x2,
                    int16_t y2, uint16_t color, uint8_t width) {
  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  if (draw_buf == NULL)
    return;
  uint16_t *buf = (uint16_t *)draw_buf->data;
  int32_t buf_w = draw_buf->header.w;
  int32_t buf_h = draw_buf->header.h;
  uint32_t stride_pixels = draw_buf->header.stride / 2;
  const int32_t clipMargin = (int32_t)width + 2;
  if (!clipLineToRect(x1, y1, x2, y2, -clipMargin, -clipMargin,
                      buf_w - 1 + clipMargin, buf_h - 1 + clipMargin))
    return;

  if (width < 2) {
    drawLineSegment(buf, buf_w, buf_h, stride_pixels, x1, y1, x2, y2, color);
    return;
  }

  float dx = x2 - x1;
  float dy = y2 - y1;
  float len = sqrtf(dx * dx + dy * dy);
  if (len < 1.0f) {
    if (x1 >= 0 && x1 < buf_w && y1 >= 0 && y1 < buf_h) {
      buf[y1 * stride_pixels + x1] = color;
    }
    return;
  }

  dx /= len;
  dy /= len;
  float px = -dy;
  float py = dx;

  int16_t start = -((int16_t)width - 1) / 2;
  int16_t end = (int16_t)width / 2;
  for (int16_t t = start; t <= end; t++) {
    int16_t ox = (int16_t)roundf(px * t);
    int16_t oy = (int16_t)roundf(py * t);
    drawLineSegment(buf, buf_w, buf_h, stride_pixels, x1 + ox, y1 + oy,
                    x2 + ox, y2 + oy, color);
  }
}

void Maps::drawLineSegment(uint16_t *buf, int32_t buf_w, int32_t buf_h,
                           uint32_t stride_pixels, int16_t x1, int16_t y1,
                           int16_t x2, int16_t y2, uint16_t color) {
  // Bresenham's Line Algorithm
  int dx = abs(x2 - x1), sx = x1 < x2 ? 1 : -1;
  int dy = -abs(y2 - y1), sy = y1 < y2 ? 1 : -1;
  int err = dx + dy, e2;

  while (true) {
    if (x1 >= 0 && x1 < buf_w && y1 >= 0 && y1 < buf_h) {
      buf[y1 * stride_pixels + x1] = color;
    }
    if (x1 == x2 && y1 == y2)
      break;
    e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x1 += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y1 += sy;
    }
  }
}

/**
 * @brief Get bounding objects in memory block
 *
 * @param memBlocks
 * @param bbox
 */
void Maps::getMapBlocks(BBox &bbox, Maps::MemCache &memCache) {
  ESP_LOGI(TAG, "getMapBlocks %i", millis());
  const uint32_t blocksStartMs = MAPIO_TIME_MS();
  uint16_t cacheHits = 0;
  uint16_t loadedBlocks = 0;
  uint16_t evictedBlocks = 0;
  for (MapBlock *block : memCache.blocks) {
    block->inView = false;
  }

  // 1. Identify all required block offsets for the current viewport
  std::vector<Point32> requiredOffsets;
  for (Point32 point : {bbox.min, bbox.max, Point32(bbox.min.x, bbox.max.y),
                        Point32(bbox.max.x, bbox.min.y)}) {
    int32_t blockMinX = point.x & (~MAPBLOCK_MASK);
    int32_t blockMinY = point.y & (~MAPBLOCK_MASK);
    Point32 offset(blockMinX, blockMinY);

    bool alreadyListed = false;
    for (const auto &req : requiredOffsets) {
      if (req.x == offset.x && req.y == offset.y) {
        alreadyListed = true;
        break;
      }
    }
    if (!alreadyListed) {
      requiredOffsets.push_back(offset);
    }
  }

  // 2. Mark existing blocks as inView if they are in the required set
  for (MapBlock *memblock : memCache.blocks) {
    for (const auto &req : requiredOffsets) {
      if (memblock->offset.x == req.x && memblock->offset.y == req.y) {
        memblock->inView = true;
        break;
      }
    }
  }

  // 3. Load missing blocks
  for (const auto &req : requiredOffsets) {
    bool found = false;
    for (MapBlock *memblock : memCache.blocks) {
      if (memblock->offset.x == req.x && memblock->offset.y == req.y) {
        found = true;
        break;
      }
    }

    if (found) {
      cacheHits++;
      continue;
    }

    ESP_LOGI(TAG, "getMapBlocks loading missing: offset(%d, %d)", req.x, req.y);

    // Block is not in memory => load from disk
    int32_t blockX = (req.x >> MAPBLOCK_SIZE_BITS) & MAPFOLDER_MASK;
    int32_t blockY = (req.y >> MAPBLOCK_SIZE_BITS) & MAPFOLDER_MASK;
    int32_t folderNameX = req.x >> (MAPFOLDER_SIZE_BITS + MAPBLOCK_SIZE_BITS);
    int32_t folderNameY = req.y >> (MAPFOLDER_SIZE_BITS + MAPBLOCK_SIZE_BITS);

    char folderName[12];
    snprintf(folderName, 12, "%+04d%+04d", (int)folderNameX, (int)folderNameY);
    String fileName =
        mapVectorFolder + folderName + "/" + blockX + "_" + blockY;

    log_i("Attempting to load map file: %s", fileName.c_str());

    // If cache is full, find a block that is NOT in view to evict
    if (memCache.blocks.size() >= MAPBLOCKS_MAX) {
      bool evicted = false;
      for (auto it = memCache.blocks.begin(); it != memCache.blocks.end();
           ++it) {
        if (!(*it)->inView) {
          ESP_LOGI(TAG, "Evicting block: offset(%d, %d)", (*it)->offset.x,
                   (*it)->offset.y);
          delete *it;
          memCache.blocks.erase(it);
          evictedBlocks++;
          evicted = true;
          break;
        }
      }
      // If all blocks are in view (should not happen if MAPBLOCKS_MAX >= 4),
      // we still must evict something to load the new one.
      if (!evicted) {
        ESP_LOGW(TAG, "Cache full and all blocks inView! Evicting front.");
        delete memCache.blocks.front();
        memCache.blocks.erase(memCache.blocks.begin());
        evictedBlocks++;
      }
    }

    MapBlock *newBlock = Maps::readMapBlock(fileName);
    if (Maps::isMapFound) {
      newBlock->inView = true;
      newBlock->offset = req;
      memCache.blocks.push_back(newBlock);
      loadedBlocks++;

      ESP_LOGI(TAG, "Block loaded: %p, offset(%d, %d)", newBlock, req.x, req.y);
      ESP_LOGI(TAG, "FreeHeap: %d", (int)esp_get_free_heap_size());
    }
  }

  ESP_LOGI(TAG, "memCache size: %i %i", memCache.blocks.size(), millis());
  MAPIO_LOG("MAPIO: blocks required=%u cacheHit=%u loaded=%u evicted=%u "
            "cache=%u elapsedMs=%lu\n",
            (unsigned)requiredOffsets.size(), (unsigned)cacheHits,
            (unsigned)loadedBlocks, (unsigned)evictedBlocks,
            (unsigned)memCache.blocks.size(),
            (unsigned long)(MAPIO_TIME_MS() - blocksStartMs));
}

/**
 * @brief Generate vectorized map
 *
 * @param viewPort
 * @param memblocks
 * @param map -> Map Sprite
 * @param zoom -> Zoom Level
 */
void Maps::readVectorMap(ViewPort &viewPort, MemCache &memCache,
                         lv_obj_t *canvas, uint8_t zoom, double rotation) {
  Polygon newPolygon;
  const uint32_t drawStartMs = MAPIO_TIME_MS();
  const uint32_t fillStartMs = MAPIO_TIME_MS();
  lv_canvas_fill_bg(canvas, lv_color_hex(BACKGROUND_COLOR), LV_OPA_COVER);
  const uint32_t fillMs = MAPIO_TIME_MS() - fillStartMs;

  // Calculate rotation from passed argument
  double cosA = cos(rotation);
  double sinA = sin(rotation);

  // Use the actual canvas dimensions, not mapScrHeight which may differ from
  // canvas height in fullscreen mode. The anchor may be board-specific: 1.75
  // stays centered; 2.06 shifts down to show more route ahead on the tall panel.
  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  int16_t screenAnchorX =
      mapAnchorXForWidth(draw_buf ? draw_buf->header.w : Maps::mapScrWidth);
  int16_t screenAnchorY = mapAnchorYForHeight(
      draw_buf ? draw_buf->header.h
               : (mapSet.mapFullScreen ? Maps::mapScrFull
                                        : Maps::mapScrHeight));

  uint32_t totalTime = millis();
  log_i("readVectorMap: Draw start. isMapFound=%d, Blocks=%d", Maps::isMapFound,
        memCache.blocks.size());

  if (!Maps::isMapFound || memCache.blocks.empty()) {
    log_w("readVectorMap: No map data found for this location!");
    Maps::showNoMap(canvas, storage.getSdLoaded());
    MAPIO_LOG("MAPIO: canvas-draw ok=0 blocks=%u fillMs=%lu totalMs=%lu\n",
              (unsigned)memCache.blocks.size(), (unsigned long)fillMs,
              (unsigned long)(MAPIO_TIME_MS() - drawStartMs));
    return;
  }

  int16_t p1x, p1y, p2x, p2y;
  if (Maps::isMapFound) {
    for (MapBlock *mblock : memCache.blocks) {
      uint32_t blockTime = millis();
      if (!mblock->inView)
        continue;

      // block to draw
      Point16 screen_center_mc =
          viewPort.center.toPoint16() -
          mblock->offset.toPoint16(); // screen center with features coordinates

      ESP_LOGI(TAG, "Block Draw: OffsetX=%d OffsetY=%d CenterX=%d CenterY=%d",
               mblock->offset.x, mblock->offset.y, screen_center_mc.x,
               screen_center_mc.y);

      BBox screen_bbox_mc =
          viewPort.bbox -
          mblock->offset; // screen boundaries with features coordinates

      ////// Polygons - Grid-based spatial culling for performance
      const uint32_t polygonStartMs = millis();
      int poly_total = mblock->polygons.size();
      int poly_drawn = 0;
      int poly_checked = 0;

      // Calculate which grid cells overlap the viewport bounding box
      // screen_bbox_mc is in block-local coordinates (0-4095 range)
      int minCX = std::max(0, (int)(screen_bbox_mc.min.x >> CELL_SHIFT));
      int maxCX =
          std::min(GRID_SIZE - 1, (int)(screen_bbox_mc.max.x >> CELL_SHIFT));
      int minCY = std::max(0, (int)(screen_bbox_mc.min.y >> CELL_SHIFT));
      int maxCY =
          std::min(GRID_SIZE - 1, (int)(screen_bbox_mc.max.y >> CELL_SHIFT));

      // Bitset to track visited polygons (avoid processing same polygon twice
      // if it spans multiple cells)
      std::vector<bool> visited(poly_total, false);

      // Define transform lambda once, outside the loop
      auto transformPoint = [&](Point16 p) -> Point16 {
        // 1. Convert from map coords to screen-space offset (Y inverted)
        // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
        double dx, dy;
        if (zoom == 0) {
          dx = (double)(p.x - screen_center_mc.x) * 2.0;
          dy = -(double)(p.y - screen_center_mc.y) * 2.0;
        } else if (zoom == 1) {
          dx = (double)(p.x - screen_center_mc.x) * 1.5;
          dy = -(double)(p.y - screen_center_mc.y) * 1.5;
        } else {
          int divisor = zoom - 1;
          dx = (double)(p.x - screen_center_mc.x) / divisor;
          dy = -(double)(p.y - screen_center_mc.y) / divisor;
        }

        // 2. Rotate in screen space (same as route overlay)
        double rx = dx * cosA - dy * sinA;
        double ry = dx * sinA + dy * cosA;

        // 3. Translate to screen center
        int16_t sx = round(rx) + screenAnchorX;
        int16_t sy = round(ry) + screenAnchorY;

        return Point16(sx, sy);
      };

      // Iterate only through cells that overlap the viewport
      for (int cy = minCY; cy <= maxCY; cy++) {
        for (int cx = minCX; cx <= maxCX; cx++) {
          int cellIdx = cy * GRID_SIZE + cx;

          // Check bounds on polygonGrid access
          if (cellIdx < 0 || cellIdx >= (int)mblock->polygonGrid.size())
            continue;

          for (uint16_t polyIdx : mblock->polygonGrid[cellIdx]) {
            // Skip if already processed (polygon spans multiple cells)
            if (visited[polyIdx])
              continue;
            visited[polyIdx] = true;
            poly_checked++;

            const auto &polygon = mblock->polygons[polyIdx];

            // Fine-grained intersection test with viewport
            if (!polygon.bbox.intersects(screen_bbox_mc)) {
              continue;
            }

            // Skip if type is hidden by visibility mask
            if (!isPolygonVisible(polygon.typeId, polygon.color,
                                  mapRenderSettings)) {
              continue;
            }

            poly_drawn++;
            newPolygon.color = polygon.color;

            // Transform points to screen coordinates
            newPolygon.points.clear();
            int16_t minX = 32000, maxX = -32000, minY = 32000, maxY = -32000;

            for (const auto &p : polygon.points) {
              Point16 tp = transformPoint(p);
              newPolygon.points.push_back(tp);
              if (tp.x < minX)
                minX = tp.x;
              if (tp.x > maxX)
                maxX = tp.x;
              if (tp.y < minY)
                minY = tp.y;
              if (tp.y > maxY)
                maxY = tp.y;
            }

            newPolygon.bbox.min.x = minX;
            newPolygon.bbox.max.x = maxX;
            newPolygon.bbox.min.y = minY;
            newPolygon.bbox.max.y = maxY;

            // Skip tiny polygons based on explicit min size plus detail density.
            const uint8_t minPolygonSize =
                effectiveMinPolygonSize(mapRenderSettings);
            int16_t polyWidth = maxX - minX;
            int16_t polyHeight = maxY - minY;
            if (minPolygonSize > 0 &&
                polyWidth * polyHeight < minPolygonSize * minPolygonSize) {
              poly_drawn--; // Don't count as drawn
              continue;
            }

            Maps::fillPolygon(newPolygon, canvas);
          }
        }
      }
      Serial.printf("[Maps] Block polygons: Total=%d, Checked=%d, Drawn=%d\n",
                    poly_total, poly_checked, poly_drawn);
      const uint32_t polygonMs = millis() - polygonStartMs;
      log_i("Block polygons done %i ms", polygonMs);
      const uint32_t lineStartMs = millis();

      ////// Lines
      // Removed lv_draw_line usage to fix crash
      for (const auto &line : mblock->polylines) {
        if (zoom > line.maxZoom)
          continue;
        if (!line.bbox.intersects(screen_bbox_mc))
          continue;

        if (line.points.size() < 2)
          continue;

        // Skip if type is hidden by visibility mask
        if (!isLineVisible(line.typeId, line.color, line.width,
                           mapRenderSettings))
          continue;

        uint16_t color_swapped = line.color; // Use color directly (RGB565)

        // Transform first point
        auto transformPoint = [&](Point16 p) -> Point16 {
          // Convert to screen-space offset (Y inverted), rotate, translate
          // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
          double dx, dy;
          if (zoom == 0) {
            dx = (double)(p.x - screen_center_mc.x) * 2.0;
            dy = -(double)(p.y - screen_center_mc.y) * 2.0;
          } else if (zoom == 1) {
            dx = (double)(p.x - screen_center_mc.x) * 1.5;
            dy = -(double)(p.y - screen_center_mc.y) * 1.5;
          } else {
            int divisor = zoom - 1;
            dx = (double)(p.x - screen_center_mc.x) / divisor;
            dy = -(double)(p.y - screen_center_mc.y) / divisor;
          }
          double rx = dx * cosA - dy * sinA;
          double ry = dx * sinA + dy * cosA;
          int16_t sx = round(rx) + screenAnchorX;
          int16_t sy = round(ry) + screenAnchorY;
          return Point16(sx, sy);
        };

        Point16 p1 = transformPoint(line.points[0]);
        int32_t streetBoost = shouldBoostLineWidth(line.typeId, line.width)
                                  ? mapRenderSettings.streetLineWidthBoost
                                  : 0;
        uint8_t lineWidth = (uint8_t)std::min<int32_t>(
            std::max<int32_t>(line.width, 1) + streetBoost, 24);

        for (int i = 0; i < (int)line.points.size() - 1; i++) {
          Point16 p2 = transformPoint(line.points[i + 1]);
          Maps::drawLine(canvas, p1.x, p1.y, p2.x, p2.y, color_swapped,
                         lineWidth);
          p1 = p2;
        }
      }
      const uint32_t lineMs = millis() - lineStartMs;
      ESP_LOGI(TAG, "Block lines done %i ms", lineMs);
      MAPIO_LOG("MAPIO: draw-block offset=%d,%d polygons=%d "
                "checked=%d drawn=%d lines=%u polygonMs=%lu lineMs=%lu "
                "totalMs=%lu\n",
                mblock->offset.x, mblock->offset.y, poly_total, poly_checked,
                poly_drawn, (unsigned)mblock->polylines.size(),
                (unsigned long)polygonMs, (unsigned long)lineMs,
                (unsigned long)(MAPIO_TIME_MS() - blockTime));
    }
    ESP_LOGI(TAG, "Total %i ms", millis() - totalTime);

    // TODO: paint only in NAV mode
    // map.fillTriangle(...)
    ESP_LOGI(TAG, "Draw done! %i", millis());

    // NOTE: Block caching is now handled by getMapBlocks() eviction logic.
    // Previously, this code deleted the first block after every render,
    // which defeated caching and forced SD card reads every frame.

    Maps::totalBounds.lat_min = Maps::mercatorY2lat(viewPort.bbox.min.y);
    Maps::totalBounds.lat_max = Maps::mercatorY2lat(viewPort.bbox.max.y);
    Maps::totalBounds.lon_min = Maps::mercatorX2lon(viewPort.bbox.min.x);
    Maps::totalBounds.lon_max = Maps::mercatorX2lon(viewPort.bbox.max.x);

    ESP_LOGI(TAG,
             "Total Bounds: Lat Min: %f, Lat Max: %f, Lon Min: %f, Lon Max: %f",
             Maps::totalBounds.lat_min, Maps::totalBounds.lat_max,
             Maps::totalBounds.lon_min, Maps::totalBounds.lon_max);

    if (Maps::isCoordInBounds(Maps::destLat, Maps::destLon, Maps::totalBounds))
      Maps::coords2map(Maps::destLat, Maps::destLon, Maps::totalBounds,
                       &(Maps::wptPosX), &(Maps::wptPosY));
    else {
      Maps::wptPosX = -1;
      Maps::wptPosY = -1;
    }

    lv_layer_t track_layer;
    lv_canvas_init_layer(canvas, &track_layer);
    lv_draw_line_dsc_t track_dsc;
    lv_draw_line_dsc_init(&track_dsc);
    track_dsc.width = 2;
    track_dsc.color = lv_color_hex(
        TFT_BLUE); // Assuming TFT_BLUE is defined, else use LVGL color
    track_dsc.opa = LV_OPA_COVER;

    for (size_t i = 1; i < trackData.size(); ++i) {
      if (trackData[i - 1].lon > Maps::totalBounds.lon_min &&
          trackData[i - 1].lon < Maps::totalBounds.lon_max &&
          trackData[i - 1].lat > Maps::totalBounds.lat_min &&
          trackData[i - 1].lat < Maps::totalBounds.lat_max &&
          trackData[i].lon > Maps::totalBounds.lon_min &&
          trackData[i].lon < Maps::totalBounds.lon_max &&
          trackData[i].lat > Maps::totalBounds.lat_min &&
          trackData[i].lat < Maps::totalBounds.lat_max) {
        uint16_t x, y, x2, y2;
      }
    }
    MAPIO_LOG("MAPIO: canvas-draw ok=1 blocks=%u fillMs=%lu totalMs=%lu\n",
              (unsigned)memCache.blocks.size(), (unsigned long)fillMs,
              (unsigned long)(MAPIO_TIME_MS() - drawStartMs));
  } else {
    Maps::isMapFound = false;
    lv_canvas_fill_bg(canvas, lv_color_hex(TFT_BLACK), LV_OPA_COVER);
    MAPIO_LOG("MAPIO: canvas-draw ok=0 blocks=%u fillMs=%lu totalMs=%lu\n",
              (unsigned)memCache.blocks.size(), (unsigned long)fillMs,
              (unsigned long)(MAPIO_TIME_MS() - drawStartMs));
    //    Maps::showNoMap(map);
    //    ESP_LOGE(TAG, "Map doesn't exist");
  }
}

void Maps::showNoMap(lv_obj_t *canvas, bool sdPresent) {
  if (canvas == nullptr)
    return;

  lv_canvas_fill_bg(canvas, lv_color_hex(0x101820), LV_OPA_COVER);

  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  const int16_t w = draw_buf ? draw_buf->header.w : Maps::mapScrWidth;
  const int16_t h =
      draw_buf ? draw_buf->header.h
               : (mapSet.mapFullScreen ? Maps::mapScrFull
                                        : Maps::mapScrHeight);

  lv_layer_t layer;
  lv_canvas_init_layer(canvas, &layer);

  lv_draw_label_dsc_t title_dsc;
  lv_draw_label_dsc_init(&title_dsc);
  title_dsc.color = lv_color_hex(TFT_WHITE);
  title_dsc.opa = LV_OPA_COVER;
  title_dsc.font = &lv_font_montserrat_24;
  title_dsc.align = LV_TEXT_ALIGN_CENTER;
  title_dsc.text = "No map data";
  lv_area_t title_area = {0, (int16_t)(h / 2 - 46), (int16_t)(w - 1),
                          (int16_t)(h / 2 - 16)};
  lv_draw_label(&layer, &title_dsc, &title_area);

  lv_draw_label_dsc_t hint_dsc;
  lv_draw_label_dsc_init(&hint_dsc);
  hint_dsc.color = lv_color_hex(0xB8C7D9);
  hint_dsc.opa = LV_OPA_COVER;
  hint_dsc.font = &lv_font_montserrat_16;
  hint_dsc.align = LV_TEXT_ALIGN_CENTER;
  hint_dsc.text = sdPresent ? "Download map\nfor this area" : "Insert SD card";
  lv_area_t hint_area = {16, (int16_t)(h / 2 - 6), (int16_t)(w - 17),
                         (int16_t)(h / 2 + 58)};
  lv_draw_label(&layer, &hint_dsc, &hint_area);

  lv_canvas_finish_layer(canvas, &layer);
}

/**
 * @brief Get vector map Position from GPS position and check if is moved
 *
 * @param lat
 * @param lon
 */
void Maps::getPosition(double lat, double lon) {
  Coord pos;
  pos.lat = lat;
  pos.lng = lon;
  if (abs(pos.lat - Maps::prevLat) > 0.00005 &&
      abs(pos.lng - Maps::prevLon) > 0.00005) {
    Maps::point.x = Maps::lon2x(pos.lng);
    Maps::point.y = Maps::lat2y(pos.lat);
    Maps::prevLat = pos.lat;
    Maps::prevLon = pos.lng;
    Maps::isPosMoved = true;
  }
}

// Common Private section

/**
 * @brief Get min and max longitude and latitude from tile
 *
 * @param tileX -> tile X
 * @param tileY -> tile Y
 * @param zoom  -> zoom
 * @return tileBounds -> min and max longitude and latitude
 */
Maps::tileBounds Maps::getTileBounds(uint32_t tileX, uint32_t tileY,
                                     uint8_t zoom) {
  tileBounds bounds;
  bounds.lon_min = Maps::tilex2lon(tileX, zoom);
  bounds.lat_min = Maps::tiley2lat(tileY + 1, zoom);
  bounds.lon_max = Maps::tilex2lon(tileX + 1, zoom);
  bounds.lat_max = Maps::tiley2lat(tileY, zoom);
  return bounds;
}

/**
 * @brief Check if coordinates are in map bounds
 *
 * @param lat -> latitude
 * @param lon -> longitude
 * @param bound -> map bounds
 * @return true/false
 */
bool Maps::isCoordInBounds(double lat, double lon, tileBounds bound) {
  return (lat >= Maps::totalBounds.lat_min &&
          lat <= Maps::totalBounds.lat_max &&
          lon >= Maps::totalBounds.lon_min && lon <= Maps::totalBounds.lon_max);
}

/**
 * @brief Convert GPS Coordinates to screen position (with offsets)
 *
 * @param lon -> Longitude
 * @param lat -> Latitude
 * @param zoomLevel -> Zoom level
 * @param tileSize -> tile size
 * @return ScreenCoord -> Screen position
 */
Maps::ScreenCoord Maps::coord2ScreenPos(double lon, double lat,
                                        uint8_t zoomLevel, uint16_t tileSize) {
  ScreenCoord data;
  data.posX = Maps::lon2posx(lon, zoomLevel, tileSize);
  data.posY = Maps::lat2posy(lat, zoomLevel, tileSize);
  return data;
}

/**
 * @brief Get position X,Y in render map for a coordinate
 *
 * @param lat -> latitude
 * @param lon -> longitude
 * @param bound -> map bounds
 * @param pixelX -> X position on map
 * @param pixelY -> Y position on map
 */
void Maps::coords2map(double lat, double lon, tileBounds bound,
                      uint16_t *pixelX, uint16_t *pixelY) {
  double lon_ratio = (lon - bound.lon_min) / (bound.lon_max - bound.lon_min);
  double lat_ratio = (bound.lat_max - lat) / (bound.lat_max - bound.lat_min);

  *pixelX = (int)(lon_ratio * Maps::tileWidth);
  *pixelY = (int)(lat_ratio * Maps::tileHeight);
}

/**
 * @brief Load No Map Image
 *
 */
#ifndef USE_ARDUINO_GFX
void Maps::showNoMap(TFT_eSprite &map) {
  map.drawPngFile(noMapFile, (Maps::mapScrWidth / 2) - 50,
                  (Maps::mapScrHeight / 2) - 50);
  map.drawCenterString("NO MAP FOUND", (Maps::mapScrWidth / 2),
                       (Maps::mapScrHeight >> 1) + 65, &fonts::DejaVu18);
}
#else
// Removed duplicate showNoMap
// void Maps::showNoMap(lv_obj_t *canvas) { ... }
#endif

/**
 * @brief Draw map widgets
 *
 */
void Maps::drawMapWidgets(const MapSettings &mapSettings) {
  // Simplified widgets - commenting out unsupported TFT calls
  /*
  Maps::mapSprite.setTextColor(TFT_WHITE, TFT_WHITE);

  uint16_t mapHeading = 0;
#ifdef ENABLE_COMPASS
  if (mapSettings.mapRotationComp)
    mapHeading = compass.getHeading();
  else
    mapHeading = gps.gpsData.heading;
#else
  mapHeading = gps.gpsData.heading;
#endif

  if (mapSettings.showMapCompass)
  {
    Maps::mapSprite.fillRectAlpha(Maps::mapScrWidth - 48, 0, 48, 48, 95,
TFT_BLACK);
    if (mapSettings.compassRotation)
      Maps::mapSprite.pushImageRotateZoom(Maps::mapScrWidth - 24, 24, 24, 24,
360 - mapHeading, 1, 1, 48, 48, (uint16_t *)mini_compass, TFT_BLACK);
    else
      Maps::mapSprite.pushImage(Maps::mapScrWidth - 48, 0, 48, 48, (uint16_t
*)mini_compass, TFT_BLACK);
  }

  uint16_t mapHeight = 0;
  if (mapSettings.mapFullScreen)
    mapHeight = Maps::mapScrFull;
  else
    mapHeight = Maps::mapScrHeight;

  uint8_t toolBarOffset = 0;
  uint8_t toolBarSpace = 0;
#ifdef LARGE_SCREEN
  toolBarOffset = 100;
  toolBarSpace = 60;
#endif
#ifndef LARGE_SCREEN
  toolBarOffset = 80;
  toolBarSpace = 50;
#endif

  if (showMapToolBar)
  {
    if (mapSettings.mapFullScreen)
      Maps::mapSprite.pushImage(10, mapHeight - toolBarOffset, 48, 48, (uint16_t
*)collapse, TFT_BLACK);
    else
      Maps::mapSprite.pushImage(10, mapHeight - toolBarOffset, 48, 48, (uint16_t
*)expand, TFT_BLACK);

      // Maps::mapSprite.fillRectAlpha(10, mapHeight - toolBarOffset, 48, 48,
50, TFT_BLACK);

    Maps::mapSprite.pushImage(10, mapHeight - (toolBarOffset + toolBarSpace),
48, 48, (uint16_t *)zoomout, TFT_BLACK);
    // Maps::mapSprite.fillRectAlpha(10, mapHeight - (toolBarOffset +
toolBarSpace), 48, 48, 50, TFT_BLACK);

    Maps::mapSprite.pushImage(10, mapHeight - (toolBarOffset + (2 *
toolBarSpace)), 48, 48, (uint16_t *)zoomin, TFT_BLACK);
    // Maps::mapSprite.fillRectAlpha(10, mapHeight - (toolBarOffset + (2 *
toolBarSpace)), 48, 48, 50, TFT_BLACK);

    // if (!mapSettings.vectorMap)
    // {
    //   Maps::mapSprite.pushImage(tft.width() - 58, mapHeight - toolBarOffset,
48, 48, (uint16_t *)move, TFT_BLACK);
    // }
  }

  Maps::mapSprite.fillRectAlpha(0, 0, 50, 32, 95, TFT_BLACK);
  Maps::mapSprite.pushImage(0, 4, 24, 24, (uint16_t *)zoom_ico, TFT_BLACK);
  Maps::mapSprite.drawNumber(zoom, 26, 8, &fonts::FreeSansBold9pt7b);

  if (mapSettings.showMapSpeed)
  {
    Maps::mapSprite.fillRectAlpha(0, mapHeight - 32, 70, 32, 95, TFT_BLACK);
    Maps::mapSprite.pushImage(0, mapHeight - 28, 24, 24, (uint16_t *)speed_ico,
TFT_BLACK); Maps::mapSprite.drawNumber(gps.gpsData.speed, 26, mapHeight - 24,
&fonts::FreeSansBold9pt7b);
  }

  if (!mapSettings.vectorMap)
    if (mapSettings.showMapScale)
    {
      Maps::mapSprite.fillRectAlpha(Maps::mapScrWidth - 70, mapHeight - 32, 70,
Maps::mapScrWidth - 75, 95, TFT_BLACK); Maps::mapSprite.setTextSize(1);
      // Maps::mapSprite.drawFastHLine(Maps::mapScrWidth - 65, mapHeight - 14,
60);
      // Maps::mapSprite.drawFastVLine(Maps::mapScrWidth - 65, mapHeight - 19,
10);
      // Maps::mapSprite.drawFastVLine(Maps::mapScrWidth - 5, mapHeight - 19,
10);
      // Maps::mapSprite.drawCenterString(map_scale[zoom], Maps::mapScrWidth -
35, mapHeight - 24);
    }
  */
  // ... reimplement widgets as LVGL objects calling createMapWidgets() or
  // similar
}

/**
 * @brief Set center coordinates of viewport
 *
 * @param pcenter
 */
void Maps::ViewPort::setCenter(Point32 pcenter) {
  center = pcenter; // CRITICAL: Must assign center!
  // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
  double zoomScale = (zoom == 0)   ? 0.5
                     : (zoom == 1) ? 0.667
                                   : (double)(zoom - 1);
  bbox.min.x = pcenter.x - Maps::tileWidth * zoomScale / 2;
  bbox.min.y = pcenter.y - Maps::tileHeight * zoomScale / 2;
  bbox.max.x = pcenter.x + Maps::tileWidth * zoomScale / 2;
  bbox.max.y = pcenter.y + Maps::tileHeight * zoomScale / 2;
}

// Public section

/**
 * @brief Init map size
 *
 * @param mapHeight  -> Screen map size height
 * @param mapWidth   -> Screen map size width
 * @param mapFull    -> Full Screen map size
 */
void Maps::initMap(uint16_t mapHeight, uint16_t mapWidth, uint16_t mapFull) {
  Maps::mapScrHeight = mapHeight;
  Maps::mapScrWidth = mapWidth;
  Maps::mapScrFull = mapFull;

  // Reserve PSRAM for buffer map
  // Maps::mapTempSprite.deleteSprite();
  // Maps::mapTempSprite.createSprite(tileHeight, tileWidth);

  // Allocate PSRAM buffer for temp map
  if (bufMapTemp == nullptr) {
    bufMapTemp = heap_caps_malloc(tileWidth * tileHeight * sizeof(lv_color_t),
                                  MALLOC_CAP_SPIRAM);
  }

  if (bufArrow == nullptr) {
    ensureArrowBuffer();
  }

  Maps::oldMapTile = {};           // Old Map tile coordinates and zoom
  Maps::currentMapTile = {};       // Current Map tile coordinates and zoom
  Maps::roundMapTile = {};         // Boundaries Map tiles
  Maps::navArrowPosition = {0, 0}; // Map Arrow position

  Maps::totalBounds = {90.0, -90.0, 180.0, -180.0};
}

/**
 * @brief Delete map screen and release PSRAM
 *
 */
void Maps::deleteMapScrSprites() {
  // Maps::arrowSprite.deleteSprite();
  // Maps::mapSprite.deleteSprite();
  if (Maps::canvasArrow)
    lv_obj_delete(Maps::canvasArrow);
  if (Maps::canvasMap)
    lv_obj_delete(Maps::canvasMap);
  if (Maps::canvasMapTemp)
    lv_obj_delete(Maps::canvasMapTemp);

  Maps::canvasArrow = nullptr;
  Maps::canvasMap = nullptr;
  Maps::canvasMapTemp = nullptr;
}

/**
 * @brief Create map screen
 *
 */
void Maps::createMapScrSprites() {
  ESP_LOGI(TAG, "createMapScrSprites start");
  // Map Sprite
  // Map Sprite (Canvas)
  uint16_t w = Maps::mapScrWidth;
  uint16_t h = Maps::mapScrHeight;
  if (mapSet.mapFullScreen)
    h = Maps::mapScrFull;

  Maps::canvasMap = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_EVENT_BUBBLE);

  // Need buffer for screen canvas
  // We should reallocate if size changes? For now assuming fixed alloc or
  // simple.
  static void *bufMapScr = nullptr;
  static size_t bufMapScrSize = 0;
  // Use LVGL's stride calculation to ensure we match what LVGL expects
  // internally
  uint32_t stride_bytes =
      lv_draw_buf_width_to_stride(w, LV_COLOR_FORMAT_RGB565);
  size_t requiredSize = stride_bytes * h;

  if (bufMapScrSize < requiredSize) {
    if (bufMapScr)
      heap_caps_free(bufMapScr);
    bufMapScr = heap_caps_malloc(requiredSize, MALLOC_CAP_SPIRAM);
    bufMapScrSize = requiredSize;
  }
  ESP_LOGI(TAG, "MapBuff: W=%d H=%d Stride=%d Size=%d", w, h, stride_bytes,
           requiredSize);
  if (bufMapScr == nullptr) {
    ESP_LOGE(TAG, "MapBuff: screen buffer allocation failed");
    return;
  }

  lv_canvas_set_buffer(Maps::canvasMap, bufMapScr, w, h,
                       LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);

  Maps::canvasMapTemp = lv_canvas_create(
      NULL); // Invisible canvas, or just use it as buffer holder?
  // We need an object to perform operations? Or just buffer?
  // Actually we fill the buffer manually in readVectorMap (fillPolygon).
  // But line drawing uses canvas object?
  // Let's create it but not add to parent (NULL) works? No, needs parent?
  // Just create hidden.
  Maps::canvasMapTemp = lv_canvas_create(lv_scr_act());
  lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, tileWidth, tileHeight,
                       LV_COLOR_FORMAT_RGB565);

  // Arrow Sprite (Canvas) - 48x48 for better visibility
  if (ensureArrowBuffer() != nullptr) {
    Maps::canvasArrow =
        lv_canvas_create(mapTile); // Create on mapTile instead of active screen
    lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
    lv_canvas_set_buffer(Maps::canvasArrow, bufArrow, 48, 48,
                         LV_COLOR_FORMAT_ARGB8888);
    updateCurrentPositionMarker(Maps::canvasArrow, true);
  } else {
    ESP_LOGE(TAG, "MapBuff: arrow buffer unavailable; marker disabled");
    Maps::canvasArrow = nullptr;
  }
  ESP_LOGI(TAG, "createMapScrSprites done");

  // Make arrow clickable to toggle rotation mode
  // lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_CLICKABLE);
  // lv_obj_add_event_cb(
  //     Maps::canvasArrow,
  //     [](lv_event_t *e) {
  //       Maps *maps = (Maps *)lv_event_get_user_data(e);
  //       maps->toggleRotationMode();
  //     },
  //     LV_EVENT_CLICKED, this);

  // Maps::arrowSprite.pushImage(0, 0, 16, 16, (uint16_t *)navigation);
}

/**
 * @brief Toggle Map Rotation Mode
 */
void Maps::toggleRotationMode() {
  if (rotationMode == ROT_NORTH_UP) {
    rotationMode = ROT_COURSE_UP;
    log_i("Map Rotation: COURSE UP");
  } else {
    rotationMode = ROT_NORTH_UP;
    rotationRad = 0;
    log_i("Map Rotation: NORTH UP");
  }
  // Update arrow color to indicate mode
  updateArrowColor();
  // Force redraw
  redrawMap = true;
  // If we switched to Course Up, update position immediately if possible
  if (rotationMode == ROT_COURSE_UP) {
    isPosMoved = true; // Trigger regeneration
  }
}

/**
 * @brief Update GPS indicator arrow color based on rotation mode
 */
void Maps::updateArrowColor() {
  if (!Maps::canvasArrow || bufArrow == nullptr)
    return;

  updateCurrentPositionMarker(Maps::canvasArrow, true);
}

/**
 * @brief Generate render map
 *
 * @param zoom -> Zoom Level
 */
#ifndef USE_ARDUINO_GFX
void Maps::generateRenderMap(uint8_t zoom) {
  Maps::mapTileSize = Maps::renderMapTileSize;
  Maps::zoomLevel = zoom;

  bool foundRoundMap = false;
  bool missingMap = false;

  if (Maps::followGps)
    Maps::currentMapTile = Maps::getMapTile(
        gps.gpsData.longitude, gps.gpsData.latitude, Maps::zoomLevel, 0, 0);
  else
    Maps::currentMapTile =
        Maps::getMapTile(Maps::currentMapTile.lon, Maps::currentMapTile.lat,
                         Maps::zoomLevel, 0, 0);

  // Detects if tile changes from actual GPS position
  if (strcmp(Maps::currentMapTile.file, Maps::oldMapTile.file) != 0 ||
      Maps::currentMapTile.zoom != Maps::oldMapTile.zoom ||
      Maps::currentMapTile.tilex != Maps::oldMapTile.tilex ||
      Maps::currentMapTile.tiley != Maps::oldMapTile.tiley) {
    Maps::isMapFound = Maps::mapTempSprite.drawPngFile(
        Maps::currentMapTile.file, Maps::mapTileSize, Maps::mapTileSize);

  } else {
    Maps::oldMapTile = Maps::currentMapTile;
    strcpy(Maps::oldMapTile.file, Maps::currentMapTile.file);

    // Maps::mapTempSprite.fillScreen(TFT_BLACK);
    // Maps::showNoMap(Maps::mapTempSprite);
    ESP_LOGW(TAG, "Render Map not found (render map disabled)");
  }
  else {
    Maps::oldMapTile = Maps::currentMapTile;
    strcpy(Maps::oldMapTile.file, Maps::currentMapTile.file);

    Maps::totalBounds =
        Maps::getTileBounds(Maps::currentMapTile.tilex,
                            Maps::currentMapTile.tiley, Maps::zoomLevel);

    int8_t startX = -1;
    int8_t startY = -1;

    for (int8_t y = startX; y <= startX + 2; y++) {
      for (int8_t x = startY; x <= startY + 2; x++) {

        if (x == 0 && y == 0)
          continue; // Skip Center Tile

        Maps::roundMapTile =
            getMapTile(Maps::currentMapTile.lon, Maps::currentMapTile.lat,
                       Maps::zoomLevel, x, y);

        foundRoundMap = Maps::mapTempSprite.drawPngFile(
            Maps::roundMapTile.file, (x - startX) * Maps::mapTileSize,
            (y - startY) * Maps::mapTileSize);
        if (!foundRoundMap) {
          Maps::mapTempSprite.fillRect((x - startX) * Maps::mapTileSize,
                                       (y - startY) * Maps::mapTileSize,
                                       Maps::mapTileSize, Maps::mapTileSize,
                                       TFT_BLACK);
          Maps::mapTempSprite.drawPngFile(noMapFile,
                                          ((x - startX) * Maps::mapTileSize) +
                                              (Maps::mapTileSize / 2) - 50,
                                          ((y - startY) * Maps::mapTileSize) +
                                              (Maps::mapTileSize / 2) - 50);
          missingMap = true;
        } else {
          tileBounds currentBounds =
              Maps::getTileBounds(Maps::roundMapTile.tilex,
                                  Maps::roundMapTile.tiley, Maps::zoomLevel);

          if (currentBounds.lat_min < Maps::totalBounds.lat_min)
            Maps::totalBounds.lat_min = currentBounds.lat_min;
          if (currentBounds.lat_max > Maps::totalBounds.lat_max)
            Maps::totalBounds.lat_max = currentBounds.lat_max;
          if (currentBounds.lon_min < Maps::totalBounds.lon_min)
            Maps::totalBounds.lon_min = currentBounds.lon_min;
          if (currentBounds.lon_max > Maps::totalBounds.lon_max)
            Maps::totalBounds.lon_max = currentBounds.lon_max;
        }
      }
    }

    if (!missingMap) {
      if (Maps::isCoordInBounds(Maps::destLat, Maps::destLon,
                                Maps::totalBounds))
        Maps::coords2map(Maps::destLat, Maps::destLon, Maps::totalBounds,
                         &(Maps::wptPosX), &(Maps::wptPosY));
    } else {
      Maps::wptPosX = -1;
    }
  }
}
}
#else
void Maps::generateRenderMap(uint8_t zoom) {
  // Render Map not supported in Arduino_GFX mode
}
#endif

/**
 * @brief Display Map (Stub for Vector Maps/Arduino_GFX)
 */
void Maps::displayMap() {
  const uint32_t displayStartMs = MAPIO_TIME_MS();
  if (Maps::canvasMap)
    lv_obj_invalidate(Maps::canvasMap);

  // Update Arrow Position
  if (Maps::canvasArrow) {
    if (!Maps::isMapFound || !isCurrentPositionVisible(mapRenderSettings)) {
      lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      MAPIO_LOG("MAPIO: current-position marker hidden mapFound=%d visible=%d\n",
                Maps::isMapFound, isCurrentPositionVisible(mapRenderSettings));
      return;
    }

    uint16_t h = mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
    const int16_t anchorX = mapAnchorXForWidth(Maps::mapScrWidth);
    const int16_t anchorY = mapAnchorYForHeight(h);
    updateCurrentPositionMarker(Maps::canvasArrow);
    const int16_t markerVisualHalf = 24 * currentMarkerScale();
    int16_t x, y;

    if (Maps::followGps) {
      // Board-specific map anchor when following GPS (48x48 icon, so offset
      // by -24). The 1.75 stays centered; the 2.06 anchor is lower.
      x = anchorX - 24;
      y = anchorY - 24;
      lv_obj_clear_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      lv_obj_set_pos(Maps::canvasArrow, x, y);
      ESP_LOGI(TAG, "GPS indicator: followGps mode, anchor screen pos(%d,%d)",
               x, y);
    } else {
      // Calculate position relative to viewport center
      // Convert GPS lat/lon to Mercator coordinates
      int32_t gpsX = lon2x(gps.gpsData.longitude);
      int32_t gpsY = lat2y(gps.gpsData.latitude);

      // Apply rotation to match map rendering
      // 1. Convert from map coords to screen-space offset (Y inverted)
      // 1. Convert from map coords to screen-space offset (Y inverted)
      // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
      double dx, dy;
      if (zoom == 0) {
        dx = (double)(gpsX - Maps::viewPort.center.x) * 2.0;
        dy = -(double)(gpsY - Maps::viewPort.center.y) * 2.0;
      } else if (zoom == 1) {
        dx = (double)(gpsX - Maps::viewPort.center.x) * 1.5;
        dy = -(double)(gpsY - Maps::viewPort.center.y) * 1.5;
      } else {
        int divisor = zoom - 1; // zoom 2->1, 3->2, 4->3, 5->4
        dx = (double)(gpsX - Maps::viewPort.center.x) / divisor;
        dy = -(double)(gpsY - Maps::viewPort.center.y) / divisor;
      }

      // 2. Rotate in screen space
      double cosA = cos(rotationRad);
      double sinA = sin(rotationRad);
      double rx = dx * cosA - dy * sinA;
      double ry = dx * sinA + dy * cosA;

      // 3. Translate to screen center (centered on arrow)
      // 48x48 icon, so offset by -24
      x = (round(rx) + anchorX) - 24;
      y = (round(ry) + anchorY) - 24;

      ESP_LOGI(TAG,
               "GPS indicator: gps(%.6f,%.6f) -> mercator(%d,%d) -> "
               "screen(%d,%d), viewport center(%d,%d) zoom=%d rot=%.2f",
               gps.gpsData.latitude, gps.gpsData.longitude, gpsX, gpsY, x, y,
               Maps::viewPort.center.x, Maps::viewPort.center.y, zoom,
               rotationRad);

      lv_obj_set_pos(Maps::canvasArrow, x, y);

      // Simple bounds check to hide if too far off screen
      const int16_t centerX = x + 24;
      const int16_t centerY = y + 24;
      if (centerX < -markerVisualHalf ||
          centerX > (int16_t)Maps::mapScrWidth + markerVisualHalf ||
          centerY < -markerVisualHalf ||
          centerY > (int16_t)h + markerVisualHalf) {
        lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
        ESP_LOGI(TAG, "GPS indicator hidden: off-screen at (%d,%d)", x, y);
      } else {
        lv_obj_clear_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      }
    }
    lv_obj_move_foreground(Maps::canvasArrow);
  }
  MAPIO_LOG("MAPIO: display invalidateMs=%lu hasCanvas=%d hasArrow=%d\n",
            (unsigned long)(MAPIO_TIME_MS() - displayStartMs),
            Maps::canvasMap != nullptr, Maps::canvasArrow != nullptr);
}

/**
 * @brief Generate Vector Map
 *
 * @param zoom -> Zoom Level
 */
void Maps::generateVectorMap(uint8_t zoom) {
  const uint32_t generateStartMs = MAPIO_TIME_MS();
  Maps::mapTileSize = Maps::vectorMapTileSize;
  Maps::zoomLevel = zoom;

  // CRITICAL: Update Rotation ONCE per generation frame to ensure map and route
  // align
  if (rotationMode == ROT_COURSE_UP) {
    uint16_t courseUpHeading = gps.gpsData.heading;
    const char *courseUpSource = "gps";
    uint16_t routeHeading = 0;
    if (routeOverlay.headingNear(gps.gpsData.latitude, gps.gpsData.longitude,
                                 routeHeading)) {
      courseUpHeading = routeHeading;
      courseUpSource = "route";
    }

    // Use negative heading to rotate map so the selected navigation/course
    // direction points up.
    rotationRad = -DEG2RAD(courseUpHeading);
    ESP_LOGI(TAG, "Course-Up: heading=%u source=%s gpsHeading=%u",
             (unsigned)courseUpHeading, courseUpSource,
             (unsigned)gps.gpsData.heading);
  } else {
    rotationRad = 0;
  }

  // Viewport
  Maps::viewPort.zoom = zoom;
  Maps::viewPort.setCenter(Maps::point);

  // Get Map Blocks
  const uint32_t blocksStartMs = MAPIO_TIME_MS();
  Maps::getMapBlocks(Maps::viewPort.bbox, Maps::memCache);
  const uint32_t blocksMs = MAPIO_TIME_MS() - blocksStartMs;

  ESP_LOGI(TAG,
           "generateVectorMap: zoom=%d center(%d, %d) bbox[(%d, %d), (%d, %d)]",
           zoom, Maps::viewPort.center.x, Maps::viewPort.center.y,
           Maps::viewPort.bbox.min.x, Maps::viewPort.bbox.min.y,
           Maps::viewPort.bbox.max.x, Maps::viewPort.bbox.max.y);

  // Read Vector Map to Canvas (Pass calculated rotation)
  const uint32_t drawStartMs = MAPIO_TIME_MS();
  Maps::readVectorMap(Maps::viewPort, Maps::memCache, Maps::canvasMap, zoom,
                      rotationRad);
  const uint32_t drawMs = MAPIO_TIME_MS() - drawStartMs;

  // Draw route overlay from iOS navigation (if available)
  const uint32_t routeStartMs = MAPIO_TIME_MS();
  ESP_LOGI(TAG, "Checking for route overlay: hasRoute=%d",
           routeOverlay.hasRoute());
  if (routeOverlay.hasRoute() && isRouteOverlayVisible(mapRenderSettings)) {
    ESP_LOGI(TAG,
             "Drawing route overlay: centerMerc=(%d,%d) "
             "zoom=%d points=%d",
             Maps::viewPort.center.x, Maps::viewPort.center.y, zoom,
             routeOverlay.getPointCount());

    // BUGFIX: Use actual canvas height, not mapScrHeight which differs in
    // fullscreen mode
    uint16_t canvasHeight =
        mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
    routeOverlay.drawRoute(Maps::canvasMap, Maps::viewPort.center.x,
                           Maps::viewPort.center.y, zoom, Maps::mapScrWidth,
                           canvasHeight, rotationRad,
                           mapAnchorXForWidth(Maps::mapScrWidth),
                           mapAnchorYForHeight(canvasHeight));
    ESP_LOGI(TAG, "Route overlay draw complete (rotation=%.2f rad, canvasH=%d)",
             rotationRad, canvasHeight);
  } else if (routeOverlay.hasRoute()) {
    ESP_LOGI(TAG, "Route overlay hidden by visibility mask");
  } else {
    ESP_LOGI(TAG, "No route overlay to draw (no route data)");
  }
  const uint32_t routeMs = MAPIO_TIME_MS() - routeStartMs;
  MAPIO_LOG("MAPIO: generate zoom=%u blocksMs=%lu drawMs=%lu "
            "routeMs=%lu totalMs=%lu cache=%u hasRoute=%d\n",
            zoom, (unsigned long)blocksMs, (unsigned long)drawMs,
            (unsigned long)routeMs,
            (unsigned long)(MAPIO_TIME_MS() - generateStartMs),
            (unsigned)Maps::memCache.blocks.size(), routeOverlay.hasRoute());
  // NOTE: isPosMoved flag is now cleared in updateMap() after display,
  // not here, to allow queued BLE updates to trigger new regenerations
}

/**
 * @brief Set Waypoint coords in Map
 *
 * @param wptLat -> Waypoint Latitude
 * @param wptLon -> Waypoint Longitude
 */
void Maps::setWaypoint(double wptLat, double wptLon) {
  Maps::destLat = wptLat;
  Maps::destLon = wptLon;
}

/**
 * @brief Refresh current map
 *
 */
void Maps::updateMap() {
  Maps::oldMapTile = {};
  Maps::isPosMoved = true;
}

/**
 * @brief Pan current map
 *
 * @param dx
 * @param dy
 */
void Maps::panMap(int8_t dx, int8_t dy) {
  Maps::currentMapTile.tilex += dx;
  Maps::currentMapTile.tiley += dy;
  Maps::currentMapTile.lon =
      Maps::tilex2lon(Maps::currentMapTile.tilex, Maps::currentMapTile.zoom);
  Maps::currentMapTile.lat =
      Maps::tiley2lat(Maps::currentMapTile.tiley, Maps::currentMapTile.zoom);
}

/**
 * @brief Center map on current GPS location
 *
 * @param lat -> GPS Latitude
 * @param lon -> GPS Longitude
 */
void Maps::centerOnGps(double lat, double lon) {
  Maps::followGps = true;
  Maps::currentMapTile.tilex = Maps::lon2tilex(lon, Maps::currentMapTile.zoom);
  Maps::currentMapTile.tiley = Maps::lat2tiley(lat, Maps::currentMapTile.zoom);
  Maps::currentMapTile.lat = lat;
  Maps::currentMapTile.lon = lon;

  // CRITICAL: Also set Maps::point which is used by generateVectorMap
  Maps::point.x = Maps::lon2x(lon);
  Maps::point.y = Maps::lat2y(lat);
  Maps::isPosMoved = true;

  ESP_LOGI(TAG, "centerOnGps: lat=%f, lon=%f -> point.x=%d, point.y=%d", lat,
           lon, Maps::point.x, Maps::point.y);
}

/**
 * @brief Smooth scroll current map
 *
 * @param dx
 * @param dy
 */
void Maps::scrollMap(int16_t dx, int16_t dy) {
  // SIMPLIFIED: Direct displacement without inertia
  // The inertia logic was causing oscillation because residual momentum
  // from previous drags wasn't being reset between touch sessions.

  if (mapSet.vectorMap) {
    // For vector maps, directly update the geographic center point
    // Scale pixels to coordinates using the current zoom
    // Zoom scale: 0=2x, 1=1.5x, 2=1x, 3=/2, 4=/3, 5=/4
    if (zoom == 0) {
      Maps::point.x += (int32_t)(dx / 2);
      Maps::point.y -= (int32_t)(dy / 2);
    } else if (zoom == 1) {
      Maps::point.x += (int32_t)(dx / 1.5);
      Maps::point.y -= (int32_t)(dy / 1.5);
    } else {
      int divisor = zoom - 1;
      Maps::point.x += (int32_t)(dx * divisor);
      Maps::point.y -= (int32_t)(dy * divisor);
    }
    ESP_LOGI(TAG, "scrollMap (Vector): dx=%d dy=%d zoom=%d -> point(%d, %d)",
             dx, dy, zoom, Maps::point.x, Maps::point.y);
    Maps::isPosMoved = true;
    Maps::followGps = false;
    return;
  }

  // For non-vector (render) maps, update tile offsets directly
  Maps::offsetX += (int16_t)dx;
  Maps::offsetY += (int16_t)dy;

  Maps::scrollUpdated = false;
  Maps::followGps = false;

  if (Maps::offsetX <= -Maps::scrollThreshold) {
    Maps::tileX--;
    Maps::offsetX += Maps::renderMapTileSize;
    Maps::scrollUpdated = true;
  } else if (offsetX >= Maps::scrollThreshold) {
    Maps::tileX++;
    Maps::offsetX -= Maps::renderMapTileSize;
    Maps::scrollUpdated = true;
  }

  if (Maps::offsetY <= -Maps::scrollThreshold) {
    Maps::tileY--;
    Maps::offsetY += Maps::renderMapTileSize;
    Maps::scrollUpdated = true;
  } else if (Maps::offsetY >= Maps::scrollThreshold) {
    Maps::tileY++;
    Maps::offsetY -= Maps::renderMapTileSize;
    Maps::scrollUpdated = true;
  }

  if (Maps::scrollUpdated) {
    int8_t deltaTileX = Maps::tileX - Maps::lastTileX;
    int8_t deltaTileY = Maps::tileY - Maps::lastTileY;
    Maps::panMap(deltaTileX, deltaTileY);
    // Maps::preloadTiles(deltaTileX, deltaTileY); // Preloading uses
    // TFT_eSprite, disabled for now
    Maps::lastTileX = Maps::tileX;
    Maps::lastTileY = Maps::tileY;
  }
}

/**
 * @brief Preload Tiles for map scrolling
 *
 * @param dirX
 * @param dirY
 */
void Maps::preloadTiles(int8_t dirX, int8_t dirY) {
#ifndef USE_ARDUINO_GFX
  int16_t preloadWidth =
      (dirX != 0) ? renderMapTileSize : renderMapTileSize * 2;
  int16_t preloadHeight =
      (dirY != 0) ? renderMapTileSize : renderMapTileSize * 2;

  TFT_eSprite preloadSprite = TFT_eSprite(&tft);
  preloadSprite.createSprite(preloadWidth, preloadHeight);

  int16_t startX = tileX + dirX;
  int16_t startY = tileY + dirY;

  for (int8_t i = 0; i < 2; ++i) {
    int16_t tileToLoadX = startX + ((dirX == 0) ? i - 1 : 0);
    int16_t tileToLoadY = startY + ((dirY == 0) ? i - 1 : 0);

    Maps::roundMapTile =
        Maps::getMapTile(Maps::currentMapTile.lon, Maps::currentMapTile.lat,
                         Maps::zoomLevel, tileToLoadX, tileToLoadY);

    bool foundTile = preloadSprite.drawPngFile(
        Maps::roundMapTile.file, (dirX != 0) ? i * renderMapTileSize : 0,
        (dirY != 0) ? i * renderMapTileSize : 0);

    if (!foundTile) {
      preloadSprite.fillRect((dirX != 0) ? i * renderMapTileSize : 0,
                             (dirY != 0) ? i * renderMapTileSize : 0,
                             renderMapTileSize, renderMapTileSize,
                             TFT_LIGHTGREY);
    }
  }

  if (dirX != 0) {
    mapTempSprite.scroll(dirX * renderMapTileSize, 0);
    mapTempSprite.pushImage((dirX > 0 ? renderMapTileSize * 2 : 0), 0,
                            preloadWidth, preloadHeight,
                            preloadSprite.frameBuffer(0));
  } else if (dirY != 0) {
    mapTempSprite.scroll(0, dirY * renderMapTileSize);
    mapTempSprite.pushImage(0, (dirY > 0 ? renderMapTileSize * 2 : 0),
                            preloadWidth, preloadHeight,
                            preloadSprite.frameBuffer(0));
  }

  preloadSprite.deleteSprite();
#else
  // Preloading not implemented for LVGL/Arduino_GFX yet
  (void)dirX;
  (void)dirY;
#endif
}
