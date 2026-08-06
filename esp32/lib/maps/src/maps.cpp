/**
 * @file maps.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com) - Render Maps
 * @author @aresta - https://github.com/aresta/ESP32_GPS - Vector Maps
 * @brief  Maps draw class
 * @version 0.2.2
 * @date 2025-05
 */

#include "maps.hpp"
#include "mapBlockFormat.hpp"
#include "mapBuildingRenderer.hpp"
#include "mapLabelLayout.hpp"
#include "mapLabelRasterizer.hpp"
#include "mapLabelSelection.hpp"
#include "mapLineStyle.hpp"
#include "mapTransform.hpp"
#include "map_projection.hpp"
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../gui/src/guiLayout.hpp"
#include "../../gui/src/navigationContentMode.hpp"
#include "../../power_management/power_management.hpp"
#include "../../power_metrics/power_metrics.hpp"
#include "../../utils/src/line_rasterizer.hpp"

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 1
#endif

// #include "../../compass/compass.hpp"
extern Gps gps;
extern Storage storage;
extern std::vector<wayPoint> trackData;
const char *TAG PROGMEM = "Maps";

#if defined(WAVESHARE_MAPIO_TIMING_LOG) ||                                  \
    defined(WAVESHARE_TOUCH_DIAGNOSTICS)
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
#include <algorithm>
#include <esp_heap_caps.h>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <limits>
#include <new>
#include <numeric>
#include <sys/stat.h>
#include <unordered_map>

namespace {

bool findMapBlock(const std::string &directory, std::string &basePath,
                  size_t &visited, size_t depth) {
  if (depth > 6 || visited >= 65536)
    return false;
  DIR *handle = ::opendir(directory.c_str());
  if (handle == nullptr)
    return false;
  bool found = false;
  while (!found) {
    struct dirent *entry = ::readdir(handle);
    if (entry == nullptr)
      break;
    const std::string name = entry->d_name;
    if (name == "." || name == ".." || (!name.empty() && name[0] == '.'))
      continue;
    if (++visited > 65536)
      break;
    const std::string path = directory + "/" + name;
    struct stat metadata = {};
    if (::stat(path.c_str(), &metadata) != 0)
      continue;
    if (S_ISDIR(metadata.st_mode)) {
      found = findMapBlock(path, basePath, visited, depth + 1);
    } else if (S_ISREG(metadata.st_mode) && name.size() > 4 &&
               name.compare(name.size() - 4, 4, ".fmb") == 0) {
      basePath = path.substr(0, path.size() - 4);
      found = true;
    } else if (S_ISREG(metadata.st_mode) && basePath.empty() &&
               name.size() > 4 &&
               name.compare(name.size() - 4, 4, ".fmp") == 0) {
      // Keep searching for the binary form, which is what production packs
      // render when both companions exist. This remains a bounded fallback for
      // legacy ASCII-only packs.
      basePath = path.substr(0, path.size() - 4);
    }
  }
  ::closedir(handle);
  return found || (depth == 0 && !basePath.empty());
}

bool validateMapBlockCooperatively(const std::string &path,
                                   const uint8_t *data, size_t size,
                                   bool &interrupted) {
  constexpr size_t VALIDATION_CHUNK_BYTES = 16 * 1024;
  interrupted = false;
  map_block_format::StreamValidator validator(path);
  size_t offset = 0;
  while (offset < size) {
    if (shouldInterruptMapRenderForScreenCycle()) {
      interrupted = true;
      return false;
    }
    const size_t remaining = size - offset;
    const size_t chunkSize = remaining < VALIDATION_CHUNK_BYTES
                                 ? remaining
                                 : VALIDATION_CHUNK_BYTES;
    if (!validator.feed(data + offset, chunkSize)) {
      return false;
    }
    offset += chunkSize;
  }
  return validator.finish();
}

map_projection::Projection makeMapProjection(
    double rasterOriginX, double rasterOriginY, int32_t rasterCellOffsetX,
    int32_t rasterCellOffsetY, uint8_t zoom, double rotation,
    uint16_t viewportWidth, uint16_t viewportHeight,
    map_projection::Mode mode,
    map_projection::BirdsEyePerspective birdsEyePerspective =
        map_projection::BirdsEyePerspective::Standard) {
  map_projection::Config config;
  config.viewportWidth = viewportWidth;
  config.viewportHeight = viewportHeight;
  config.worldOrigin = {rasterOriginX, rasterOriginY};
  config.zoom = zoom;
  config.rotationRad = rotation;
  config.anchorX = gui_layout::mapAnchorX(viewportWidth);
  config.anchorY = mode == map_projection::Mode::BirdsEye
                       ? map_projection::birdsEyeAnchorY(viewportHeight)
                       : gui_layout::mapAnchorY(viewportHeight);
  config.rasterCellOffset = {rasterCellOffsetX, rasterCellOffsetY};
  config.mode = mode;
  config.topEdgeScale =
      map_projection::birdsEyeTopEdgeScale(birdsEyePerspective);
  return map_projection::Projection(config);
}

} // namespace

bool Maps::LabelLayoutCacheKey::operator==(
    const LabelLayoutCacheKey &other) const {
  return centerX == other.centerX && centerY == other.centerY &&
         rotationBucket == other.rotationBucket &&
         screenWidth == other.screenWidth && screenHeight == other.screenHeight &&
         fontFingerprint == other.fontFingerprint &&
         visibilityMask == other.visibilityMask &&
         blockSignature == other.blockSignature && zoom == other.zoom &&
         density == other.density && languageMode == other.languageMode &&
         textSize == other.textSize && orientation == other.orientation &&
         markerX == other.markerX && markerY == other.markerY &&
         markerScale == other.markerScale &&
         markerVisible == other.markerVisible && guidance == other.guidance;
}

enum class VisibilityClass : uint8_t {
  Always,
  MajorRoad,
  LocalStreet,
  ServiceRoad,
  Building,
  GreenSpace,
  Water,
  Path,
  Track,
  Rail,
  OtherArea,
};

static inline bool isClassVisible(VisibilityClass visibilityClass,
                                  const ScreenMapRenderSettings &settings) {
  if (visibilityClass == VisibilityClass::Always)
    return true;

  uint32_t visMask = settings.visibilityMask;
  switch (visibilityClass) {
  case VisibilityClass::MajorRoad:
    return (visMask & MAP_VISIBILITY_MAJOR_ROADS) != 0;
  case VisibilityClass::LocalStreet:
    return (visMask & MAP_VISIBILITY_LOCAL_STREETS) != 0;
  case VisibilityClass::ServiceRoad:
    return (visMask & MAP_VISIBILITY_SERVICE_ROADS) != 0;
  case VisibilityClass::Building:
    return (visMask & MAP_VISIBILITY_BUILDINGS) != 0;
  case VisibilityClass::GreenSpace:
    return (visMask & MAP_VISIBILITY_GREEN_SPACE) != 0;
  case VisibilityClass::Water:
    return (visMask & MAP_VISIBILITY_WATER) != 0;
  case VisibilityClass::Path:
    return (visMask & MAP_VISIBILITY_PATHS) != 0;
  case VisibilityClass::Track:
    return (visMask & MAP_VISIBILITY_TRACKS) != 0;
  case VisibilityClass::Rail:
    return (visMask & MAP_VISIBILITY_RAILWAYS) != 0;
  case VisibilityClass::OtherArea:
    return (visMask & MAP_VISIBILITY_OTHER_AREAS) != 0;
  case VisibilityClass::Always:
  default:
    return true;
  }
}

static inline VisibilityClass visibilityClassForTypeId(uint8_t typeId) {
  if (typeId >= 1 && typeId <= 5)
    return VisibilityClass::MajorRoad;
  if (map_profile_protocol::isServiceRoadTypeId(typeId))
    return VisibilityClass::ServiceRoad;
  if (map_profile_protocol::isLocalStreetTypeId(typeId))
    return VisibilityClass::LocalStreet;
  if (map_profile_protocol::isTrackTypeId(typeId))
    return VisibilityClass::Track;
  if (map_profile_protocol::isPathTypeId(typeId))
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
// 5 water, 6 rail, 7 other areas, 10 service roads, 11 tracks.
static inline bool isTypeVisible(uint8_t typeId,
                                 const ScreenMapRenderSettings &settings) {
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
    const ScreenMapRenderSettings &settings) {
  return std::max(settings.minPolygonSize,
                  detailPolygonSizeFloor(settings.detailLevel));
}

static inline bool isPolygonVisible(uint8_t typeId, uint16_t color,
                                    const ScreenMapRenderSettings &settings) {
  if (typeId != 0)
    return isTypeVisible(typeId, settings);
  return isClassVisible(legacyPolygonVisibilityClass(color), settings);
}

static inline bool isLineVisible(uint8_t typeId, uint16_t color, uint8_t width,
                                 const ScreenMapRenderSettings &settings) {
  if (typeId != 0)
    return isTypeVisible(typeId, settings);
  return isClassVisible(legacyLineVisibilityClass(color, width), settings);
}

static inline bool isRouteOverlayVisible(const MapRenderSettings &settings) {
  return (settings.navigationOverlayVisibilityMask & (1 << 8)) != 0;
}

static inline bool isCurrentPositionVisible(const MapRenderSettings &settings) {
  return (settings.navigationOverlayVisibilityMask & (1 << 9)) != 0;
}

static inline bool shouldBoostLineWidth(uint8_t typeId, uint8_t styleWidth) {
  if (typeId >= 1 && typeId < 100)
    return true;

  // Older/unknown map blocks may not carry type IDs. In our styles, ordinary
  // roads are 3px or wider, while waterways/rail/coastline are normally 1-2px.
  return typeId == 0 && styleWidth >= 3;
}

static void *bufMapScreen = nullptr;
static void *bufMapTemp = nullptr;
static void *bufMapForeground = nullptr;
static size_t bufMapScreenSize = 0;
static size_t bufMapTempSize = 0;
static size_t bufMapForegroundSize = 0;
static void *bufMapIcon = nullptr;

static bool ensureMapBuffer(void *&buffer, size_t &capacity,
                            size_t requiredSize, const char *name) {
  if (buffer != nullptr && capacity >= requiredSize)
    return true;

  const size_t previousCapacity = capacity;
  void *replacement = heap_caps_malloc(requiredSize, MALLOC_CAP_SPIRAM);
  if (replacement == nullptr) {
    ESP_LOGE(TAG, "MapBuff: %s allocation failed size=%u", name,
             (unsigned)requiredSize);
    return false;
  }
  if (buffer != nullptr)
    heap_caps_free(buffer);
  buffer = replacement;
  capacity = requiredSize;
  ESP_LOGI(TAG, "MapBuff: %s capacity %u -> %u freePsram=%u", name,
           (unsigned)previousCapacity, (unsigned)capacity,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
  return true;
}

static bool ensureMapScreenBuffer(size_t requiredSize) {
  return ensureMapBuffer(bufMapScreen, bufMapScreenSize, requiredSize,
                         "screen");
}

static bool ensureMapTempBuffer(size_t requiredSize) {
  return ensureMapBuffer(bufMapTemp, bufMapTempSize, requiredSize, "scratch");
}

static size_t rgb565A8BufferSize(uint16_t width, uint16_t height) {
  const uint32_t stride =
      lv_draw_buf_width_to_stride(width, LV_COLOR_FORMAT_RGB565A8);
  return static_cast<size_t>(stride) * height +
         static_cast<size_t>(stride / sizeof(uint16_t)) * height;
}

static bool ensureMapForegroundBuffer(uint16_t width, uint16_t height) {
  return ensureMapBuffer(bufMapForeground, bufMapForegroundSize,
                         rgb565A8BufferSize(width, height), "foreground");
}

static void bindMapForegroundCanvas(lv_obj_t *canvas, uint16_t width,
                                    uint16_t height) {
  lv_canvas_set_buffer(canvas, bufMapForeground, width, height,
                       LV_COLOR_FORMAT_RGB565A8);
  // LVGL 9.2's canvas convenience API records only the RGB565 plane size for
  // RGB565A8. The backing allocation also contains the trailing A8 plane, so
  // retain its real extent for decoders and diagnostics that inspect it.
  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
  if (drawBuffer != nullptr)
    drawBuffer->data_size = rgb565A8BufferSize(width, height);
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

static uint8_t currentMarkerScale() {
  return (uint8_t)std::min(
      std::max((int)currentMapStyleSettings().positionMarkerScale, 1), 5);
}

static int16_t currentMarkerSize() {
  return navigation_visual_style::POSITION_MARKER_BASE_SIZE *
         currentMarkerScale();
}

static lv_value_precise_t markerCoord(int32_t origin, int16_t size,
                                      int16_t baseCoord) {
  return origin +
         (static_cast<lv_value_precise_t>(baseCoord) * size /
          navigation_visual_style::POSITION_MARKER_BASE_SIZE);
}

// The arrow's geographic reference is the point where it touches the road,
// not the center of its 48x48 drawing box.  Keeping this anchor explicit makes
// course-up rotation pivot around the rider's position instead of the arrow's
// tip and prevents a visual lead/lag when the map canvas moves underneath it.
static int16_t currentMarkerAnchorX() {
  const int16_t size = currentMarkerSize();
  return static_cast<int16_t>(std::lround(markerCoord(0, size, 24)));
}

static int16_t currentMarkerAnchorY() {
  const int16_t size = currentMarkerSize();
  const int16_t baseY = routeOverlay.hasRoute() ? 42 : 24;
  return static_cast<int16_t>(std::lround(
      markerCoord(0, size, baseY)));
}

static lv_value_precise_t markerEdgeXAtY(const lv_point_precise_t &start,
                                         const lv_point_precise_t &end,
                                         lv_value_precise_t y) {
  if (start.y == end.y)
    return start.x;

  return start.x +
         (end.x - start.x) * (y - start.y) / (end.y - start.y);
}

static void drawNavigationMarker(lv_layer_t *layer, const lv_area_t &bounds,
                                 int16_t size, lv_color_t color) {
  // Filled Lucide navigation-2 polygon. Render horizontal spans at the final
  // on-screen size because this target's software renderer does not reliably
  // fill LVGL triangle draw tasks. The rounded outline softens the three outer
  // points without magnifying a bitmap.
  const lv_point_precise_t top = {
      markerCoord(bounds.x1, size, 24), markerCoord(bounds.y1, size, 4)};
  const lv_point_precise_t right = {
      markerCoord(bounds.x1, size, 38), markerCoord(bounds.y1, size, 42)};
  const lv_point_precise_t notch = {
      markerCoord(bounds.x1, size, 24), markerCoord(bounds.y1, size, 34)};
  const lv_point_precise_t left = {
      markerCoord(bounds.x1, size, 10), markerCoord(bounds.y1, size, 42)};

  lv_draw_line_dsc_t fill;
  lv_draw_line_dsc_init(&fill);
  fill.color = color;
  fill.opa = LV_OPA_COVER;
  fill.width = 1;

  for (lv_value_precise_t y = top.y; y <= notch.y; ++y) {
    fill.p1 = {markerEdgeXAtY(top, left, y), y};
    fill.p2 = {markerEdgeXAtY(top, right, y), y};
    lv_draw_line(layer, &fill);
  }

  for (lv_value_precise_t y = notch.y + 1; y <= left.y; ++y) {
    fill.p1 = {markerEdgeXAtY(top, left, y), y};
    fill.p2 = {markerEdgeXAtY(notch, left, y), y};
    lv_draw_line(layer, &fill);

    fill.p1 = {markerEdgeXAtY(notch, right, y), y};
    fill.p2 = {markerEdgeXAtY(top, right, y), y};
    lv_draw_line(layer, &fill);
  }

  lv_draw_line_dsc_t outline;
  lv_draw_line_dsc_init(&outline);
  outline.color = color;
  outline.opa = LV_OPA_COVER;
  outline.width = std::max<int16_t>(
      1, 3 * size / navigation_visual_style::POSITION_MARKER_BASE_SIZE);
  outline.round_start = 1;
  outline.round_end = 1;

  const lv_point_precise_t outlinePoints[] = {top, right, notch, left, top};
  for (uint8_t i = 1; i < 5; ++i) {
    outline.p1 = outlinePoints[i - 1];
    outline.p2 = outlinePoints[i];
    lv_draw_line(layer, &outline);
  }
}

static void drawPositionDotMarker(lv_layer_t *layer, const lv_area_t &bounds,
                                  int16_t size, lv_color_t color) {
  const int32_t diameter = size / 3;
  const int32_t centerX = bounds.x1 + size / 2;
  const int32_t centerY = bounds.y1 + size / 2;
  lv_area_t dotBounds = {centerX - diameter / 2, centerY - diameter / 2,
                         centerX + diameter / 2 - 1,
                         centerY + diameter / 2 - 1};

  lv_draw_rect_dsc_t dot;
  lv_draw_rect_dsc_init(&dot);
  dot.bg_color = color;
  dot.bg_opa = LV_OPA_COVER;
  dot.radius = LV_RADIUS_CIRCLE;
  lv_draw_rect(layer, &dot, &dotBounds);
}

static void drawCurrentPositionMarker(lv_event_t *event) {
  lv_obj_t *marker = static_cast<lv_obj_t *>(lv_event_get_target(event));
  lv_layer_t *layer = lv_event_get_layer(event);
  if (!marker || !layer)
    return;

  lv_area_t bounds;
  lv_obj_get_coords(marker, &bounds);
  const int16_t size = lv_obj_get_width(marker);
  const lv_color_t color =
      lv_color_hex(navigation_visual_style::ROUTE_BLUE_RGB888);

  if (routeOverlay.hasRoute()) {
    drawNavigationMarker(layer, bounds, size, color);
  } else {
    drawPositionDotMarker(layer, bounds, size, color);
  }
}

static void updateCurrentPositionMarker(lv_obj_t *marker, bool force = false) {
  if (!marker)
    return;

  static bool hasLastShape = false;
  static bool lastWasNavigating = false;
  static uint8_t lastScale = 0;

  const bool isNavigating = routeOverlay.hasRoute();
  const uint8_t scale = currentMarkerScale();
  if (!force && hasLastShape && lastWasNavigating == isNavigating &&
      lastScale == scale) {
    return;
  }

  const int16_t size = currentMarkerSize();
  lv_obj_set_size(marker, size, size);
  lv_obj_invalidate(marker);
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

static map_drag_preview::CanvasExtent canvasExtent(
    lv_obj_t *canvas, uint16_t fallbackWidth, uint16_t fallbackHeight) {
  const lv_draw_buf_t *drawBuffer =
      canvas != nullptr ? lv_canvas_get_draw_buf(canvas) : nullptr;
  if (drawBuffer == nullptr)
    return {fallbackWidth, fallbackHeight};
  return {static_cast<uint16_t>(drawBuffer->header.w),
          static_cast<uint16_t>(drawBuffer->header.h)};
}

static void setPinchCanvasScale(void *object, int32_t scale) {
  lv_image_set_scale(static_cast<lv_obj_t *>(object),
                     static_cast<uint32_t>(scale));
}

static void completePinchCanvasSettlement(lv_anim_t *animation) {
  auto *canvas = static_cast<lv_obj_t *>(animation->var);
  if (canvas != nullptr) {
    lv_image_set_scale(canvas, LV_SCALE_NONE);
    lv_image_set_pivot(canvas, 0, 0);
    lv_obj_invalidate(canvas);
  }
}

#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
static void recordPinchPreviewFrame(bool reset = false) {
  static uint32_t intervals[64] = {};
  static uint8_t intervalCount = 0;
  static uint32_t lastFrameMs = 0;
  static uint32_t lastReportMs = 0;
  const uint32_t now = millis();
  if (reset) {
    intervalCount = 0;
    lastFrameMs = 0;
    lastReportMs = now;
    return;
  }
  if (lastFrameMs != 0) {
    intervals[intervalCount++] = now - lastFrameMs;
  }
  lastFrameMs = now;
  if (intervalCount < 64 && now - lastReportMs < 1000) {
    return;
  }
  if (intervalCount == 0) {
    return;
  }
  uint32_t sorted[64] = {};
  memcpy(sorted, intervals, intervalCount * sizeof(uint32_t));
  std::sort(sorted, sorted + intervalCount);
  const uint8_t medianIndex = intervalCount / 2;
  const uint8_t p95Index = static_cast<uint8_t>(
      std::min<uint16_t>(intervalCount - 1,
                         (static_cast<uint16_t>(intervalCount) * 95 + 99) /
                                 100 -
                             1));
  Serial.printf(
      "Pinch diagnostic: frames=%u median_ms=%lu p95_ms=%lu "
      "free_psram=%u largest_psram=%u\n",
      intervalCount, static_cast<unsigned long>(sorted[medianIndex]),
      static_cast<unsigned long>(sorted[p95Index]),
      heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
  intervalCount = 0;
  lastReportMs = now;
}
#endif

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
  int16_t result =
      round((double)(pxy - screenCenterxy) *
            map_transform::worldToScreenScale(zoom)) +
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
  char *start = file + Maps::idx;
  char *end = nullptr;
  const long parsed = std::strtol(start, &end, 10);
  if (end == start || parsed < std::numeric_limits<int16_t>::min() ||
      parsed > std::numeric_limits<int16_t>::max()) {
    ESP_LOGE(TAG, "parseInt16 invalid value at offset %u", Maps::idx);
    return 0;
  }
  const char delimiter = *end;
  if (delimiter != ';' && delimiter != ',' && delimiter != '\n') {
    ESP_LOGE(TAG, "parseInt16 invalid delimiter: %c %i", delimiter,
             delimiter);
    return 0;
  }
  Maps::idx = static_cast<uint32_t>(end - file + 1);
  return static_cast<int16_t>(parsed);
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
bool Maps::parseCoords(char *file,
                       std::vector<Point16, PsramAllocator<Point16>> &points) {
  char str[30];
  assert(points.size() == 0);
  Point16 point;
  while (true) {
    if ((points.size() & 0x1F) == 0 &&
        shouldInterruptMapRenderForScreenCycle()) {
      return false;
    }
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
  return true;
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
    if (fileSize == 0 || fileSize > map_block_format::kMaximumBlockBytes) {
      ESP_LOGE(TAG, "Map block size is outside renderer limits: %u bytes",
               (unsigned)fileSize);
      ::close(fd);
      Maps::isMapFound = false;
      mblock->inView = false;
      return mblock;
    }

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
    constexpr size_t READ_CHUNK_BYTES = 16 * 1024;
    size_t bytesRead = 0;
    bool readInterrupted = false;
    while (bytesRead < fileSize) {
      if (shouldInterruptMapRenderForScreenCycle()) {
        readInterrupted = true;
        break;
      }
      const size_t remaining = fileSize - bytesRead;
      const size_t requested =
          remaining < READ_CHUNK_BYTES ? remaining : READ_CHUNK_BYTES;
      const ssize_t chunkRead = ::read(fd, file + bytesRead, requested);
      if (chunkRead <= 0) {
        break;
      }
      bytesRead += static_cast<size_t>(chunkRead);
    }
    ::close(fd);
    const uint32_t readMs = MAPIO_TIME_MS() - readStartMs;

    if (readInterrupted) {
      free(file);
      Maps::isMapFound = false;
      return mblock;
    }

    if (bytesRead != fileSize) {
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

    if (shouldInterruptMapRenderForScreenCycle()) {
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

    size_t normalizedSize = 0;
    for (size_t index = 0; index < fileSize; ++index) {
      if ((index & 0x0FFF) == 0 &&
          shouldInterruptMapRenderForScreenCycle()) {
        free(file);
        Maps::isMapFound = false;
        return mblock;
      }
      if (file[index] != '\r')
        file[normalizedSize++] = file[index];
    }
    fileSize = normalizedSize;
    file[fileSize] = '\0';
    bool validationInterrupted = false;
    if (!validateMapBlockCooperatively(
            filePath, reinterpret_cast<const uint8_t *>(file), fileSize,
            validationInterrupted)) {
      if (validationInterrupted) {
        free(file);
        Maps::isMapFound = false;
        return mblock;
      }
      ESP_LOGE(TAG, "Invalid or unsupported ASCII map block");
      free(file);
      Maps::isMapFound = false;
      mblock->inView = false;
      return mblock;
    }

    try {
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
      if (shouldInterruptMapRenderForScreenCycle()) {
        free(file);
        Maps::isMapFound = false;
        return mblock;
      }
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
      polygon.typeId = 0;
      if (strcmp(str, "bbox") != 0) {
        polygon.typeId = (uint8_t)std::stoul(str, nullptr, 10);
        Maps::parseStrUntil(file, ':', str);
        line++;
      }
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

      if (!Maps::parseCoords(file, polygon.points)) {
        free(file);
        Maps::isMapFound = false;
        return mblock;
      }
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
        if (shouldInterruptMapRenderForScreenCycle()) {
          free(file);
          Maps::isMapFound = false;
          return mblock;
        }
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
        polyline.typeId = 0;
        if (strcmp(str, "bbox") != 0) {
          polyline.typeId = (uint8_t)std::stoul(str, nullptr, 10);
          Maps::parseStrUntil(file, ':', str);
          line++;
        }
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
        if (!Maps::parseCoords(file, polyline.points)) {
          free(file);
          Maps::isMapFound = false;
          return mblock;
        }
        line++;
        mblock->polylines.push_back(polyline);
        totalPoints += polyline.points.size();
        count--;
      }
    }
    // Build spatial grid for polygon culling optimization
    const uint32_t gridStartMs = MAPIO_TIME_MS();
    if (!buildPolygonGrid(mblock)) {
      if (shouldInterruptMapRenderForScreenCycle()) {
        free(file);
        Maps::isMapFound = false;
        delete mblock;
        return new MapBlock();
      }
      ESP_LOGE(TAG, "Could not allocate bounded polygon grid");
      throw std::bad_alloc();
    }
    Maps::isMapFound = true;
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
      // File descriptor was already closed via ::close(fd) after reading.
      free(file);
      return mblock;
    } catch (const std::bad_alloc &) {
      ESP_LOGE(TAG, "PSRAM exhausted while decoding ASCII map block");
      free(file);
      Maps::isMapFound = false;
      delete mblock;
      return new MapBlock();
    }
  }
}

/**
 * @brief High performance binary map block reader
 * Supports both v1 (legacy) and v2 (with typeId) formats
 */
Maps::MapBlock *Maps::readMapBlockBinary(char *file, size_t fileSize) {
  const uint32_t parseStartMs = MAPIO_TIME_MS();
  bool validationInterrupted = false;
  if (!validateMapBlockCooperatively(
          "block.fmb", reinterpret_cast<const uint8_t *>(file), fileSize,
          validationInterrupted)) {
    if (validationInterrupted) {
      Maps::isMapFound = false;
      return new MapBlock();
    }
    ESP_LOGE(TAG, "Invalid or unsupported binary map block");
    Maps::isMapFound = false;
    return new MapBlock();
  }

  MapBlock *mblock = nullptr;
  try {
    mblock = new MapBlock();
    size_t offset = 0;

    // Get version from 4th byte
    uint8_t version = (uint8_t)file[3];
    bool hasTypeId = (version >= 2);
    mblock->formatVersion = version;
    ESP_LOGI(TAG, "Map file version: %d (typeId: %s)", version,
             hasTypeId ? "yes" : "no");
    offset += 4;

  // Polygons
  uint16_t polyCount = *(uint16_t *)(file + offset);
  offset += 2;
  mblock->polygons.reserve(polyCount);

  for (int i = 0; i < polyCount; i++) {
    if ((i & 0x1F) == 0 && shouldInterruptMapRenderForScreenCycle()) {
      Maps::isMapFound = false;
      delete mblock;
      return new MapBlock();
    }
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
    if ((i & 0x1F) == 0 && shouldInterruptMapRenderForScreenCycle()) {
      Maps::isMapFound = false;
      delete mblock;
      return new MapBlock();
    }
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

  if (version >= 3) {
    std::string labelError;
    if (!map_label_block::decode(
            reinterpret_cast<const uint8_t *>(file), fileSize, lineCount,
            mblock->labelData, &labelError)) {
      ESP_LOGE(TAG, "Could not decode FMB v3 labels: %s", labelError.c_str());
      Maps::isMapFound = false;
      delete mblock;
      return new MapBlock();
    }
  }
  if (version >= 4) {
    std::string buildingError;
    if (!map_building_block::decode(
            reinterpret_cast<const uint8_t *>(file), fileSize,
            mblock->buildingData, &buildingError)) {
      ESP_LOGE(TAG, "Could not decode FMB v4 buildings: %s",
               buildingError.c_str());
      Maps::isMapFound = false;
      delete mblock;
      return new MapBlock();
    }
  }

  // Build spatial grid for polygon culling optimization
  const uint32_t gridStartMs = MAPIO_TIME_MS();
  if (!buildPolygonGrid(mblock)) {
    if (shouldInterruptMapRenderForScreenCycle()) {
      Maps::isMapFound = false;
      delete mblock;
      return new MapBlock();
    }
    ESP_LOGE(TAG, "Could not allocate bounded polygon grid");
    throw std::bad_alloc();
  }
  Maps::isMapFound = true;
  const uint32_t gridMs = MAPIO_TIME_MS() - gridStartMs;
  MAPIO_LOG("MAPIO: vector-parse format=binary size=%u version=%u "
            "polygons=%u lines=%u buildingRecords=%u buildingRings=%u "
            "buildingPoints=%u heightExplicit=%u heightLevels=%u "
            "heightInherited=%u heightLocalMedian=%u heightClassDefault=%u "
            "parseMs=%lu gridMs=%lu totalMs=%lu\n",
            (unsigned)fileSize, version, (unsigned)mblock->polygons.size(),
            (unsigned)mblock->polylines.size(),
            (unsigned)mblock->buildingData.stats.records,
            (unsigned)mblock->buildingData.stats.rings,
            (unsigned)mblock->buildingData.stats.points,
            (unsigned)mblock->buildingData.stats.provenance[0],
            (unsigned)mblock->buildingData.stats.provenance[1],
            (unsigned)mblock->buildingData.stats.provenance[2],
            (unsigned)mblock->buildingData.stats.provenance[3],
            (unsigned)mblock->buildingData.stats.provenance[4],
            (unsigned long)(gridStartMs - parseStartMs),
            (unsigned long)gridMs,
            (unsigned long)(MAPIO_TIME_MS() - parseStartMs));
    return mblock;
  } catch (const std::bad_alloc &) {
    ESP_LOGE(TAG, "PSRAM exhausted while decoding binary map block");
    Maps::isMapFound = false;
    delete mblock;
    return new MapBlock();
  }
}

/**
 * @brief Build spatial grid index for polygon culling optimization.
 * Divides block into 16x16 grid cells and assigns polygon indices to cells
 * based on bounding box overlap. This reduces polygon iteration from O(n)
 * to O(cells_in_viewport * polygons_per_cell).
 *
 * @param mblock The map block to build the grid for
 */
bool Maps::buildPolygonGrid(MapBlock *mblock) {
  // Initialize grid with GRID_SIZE * GRID_SIZE cells (16x16 = 256 cells)
  try {
    mblock->polygonGrid.clear();
    mblock->polygonGrid.resize(GRID_SIZE * GRID_SIZE);

    size_t totalEntries = 0;
    for (uint16_t i = 0; i < mblock->polygons.size(); i++) {
      if ((i & 0x1F) == 0 && shouldInterruptMapRenderForScreenCycle()) {
        mblock->polygonGrid.clear();
        return false;
      }
      const auto &poly = mblock->polygons[i];

      // Calculate which grid cells this polygon's bounding box overlaps.
      // CELL_SHIFT converts block coords (0-4095) to a cell index (0-15).
      int minCX = std::max(0, (int)(poly.bbox.min.x >> CELL_SHIFT));
      int maxCX =
          std::min(GRID_SIZE - 1, (int)(poly.bbox.max.x >> CELL_SHIFT));
      int minCY = std::max(0, (int)(poly.bbox.min.y >> CELL_SHIFT));
      int maxCY =
          std::min(GRID_SIZE - 1, (int)(poly.bbox.max.y >> CELL_SHIFT));

      const size_t entries = minCX <= maxCX && minCY <= maxCY
                                 ? static_cast<size_t>(maxCX - minCX + 1) *
                                       static_cast<size_t>(maxCY - minCY + 1)
                                 : 0;
      if (entries > map_block_format::kMaximumPolygonGridEntries -
                        totalEntries) {
        mblock->polygonGrid.clear();
        return false;
      }
      totalEntries += entries;

      // Add polygon index to all overlapping cells.
      for (int cy = minCY; cy <= maxCY; cy++) {
        for (int cx = minCX; cx <= maxCX; cx++) {
          mblock->polygonGrid[cy * GRID_SIZE + cx].push_back(i);
        }
      }
    }

    log_d(
        "Built polygon grid: %d polygons -> %d cell entries (%.1fx expansion)",
        mblock->polygons.size(), totalEntries,
        mblock->polygons.size() > 0
            ? (float)totalEntries / mblock->polygons.size()
            : 0.0f);
    return true;
  } catch (const std::bad_alloc &) {
    mblock->polygonGrid.clear();
    return false;
  }
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
bool Maps::fillPolygon(const Polygon &p, lv_obj_t *canvas,
                       uint32_t deadlineStartMs,
                       uint32_t deadlineDurationMs) // scanline fill algorithm
{
  int16_t maxY = p.bbox.max.y;
  int16_t minY = p.bbox.min.y;

  // Retrieve canvas buffer and dimensions
  lv_draw_buf_t *draw_buf = lv_canvas_get_draw_buf(canvas);
  if (draw_buf == NULL)
    return true;
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
    return true;

  int16_t nodeX[p.points.size()], pixelY;

  //  Loop through the rows of the image.
  int16_t nodes, i, swap;

  if (p.points.size() < 2)
    return true;

  for (pixelY = minY; pixelY <= maxY; pixelY++) { //  Build a list of nodes.
    if ((pixelY & 0x0F) == 0) {
      if (shouldInterruptMapRenderForScreenCycle())
        return false;
      if (deadlineDurationMs != 0 &&
          millis() - deadlineStartMs >= deadlineDurationMs)
        return false;
    }
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
  return true;
}

/**
 * @brief Draw an opaque filled line directly to the canvas buffer
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
  line_rasterizer::drawFilledLine(buf, buf_w, buf_h, stride_pixels, x1, y1,
                                  x2, y2, color, width);
}

/**
 * @brief Get bounding objects in memory block
 *
 * @param memBlocks
 * @param bbox
 */
bool Maps::getMapBlocks(BBox &bbox, Maps::MemCache &memCache) {
  ESP_LOGI(TAG, "getMapBlocks %i", millis());
  if (shouldInterruptMapRenderForScreenCycle()) {
    return false;
  }
  const uint32_t blocksStartMs = MAPIO_TIME_MS();
  uint16_t cacheHits = 0;
  uint16_t loadedBlocks = 0;
  uint16_t evictedBlocks = 0;
  for (MapBlock *block : memCache.blocks) {
    block->inView = false;
  }

  // 1. Identify all required block offsets for the current viewport
  std::vector<Point32> requiredOffsets;
  const int32_t minBlockX = bbox.min.x & (~MAPBLOCK_MASK);
  const int32_t maxBlockX = bbox.max.x & (~MAPBLOCK_MASK);
  const int32_t minBlockY = bbox.min.y & (~MAPBLOCK_MASK);
  const int32_t maxBlockY = bbox.max.y & (~MAPBLOCK_MASK);
  for (int64_t blockY = minBlockY; blockY <= maxBlockY;
       blockY += (1 << MAPBLOCK_SIZE_BITS)) {
    for (int64_t blockX = minBlockX; blockX <= maxBlockX;
         blockX += (1 << MAPBLOCK_SIZE_BITS)) {
      if (requiredOffsets.size() >= MAPBLOCKS_MAX) {
        ESP_LOGE(TAG,
                 "Viewport needs more than %u map blocks: bbox[(%d,%d),"
                 "(%d,%d)]",
                 (unsigned)MAPBLOCKS_MAX, bbox.min.x, bbox.min.y, bbox.max.x,
                 bbox.max.y);
        return false;
      }
      requiredOffsets.emplace_back(static_cast<int32_t>(blockX),
                                   static_cast<int32_t>(blockY));
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
    if (shouldInterruptMapRenderForScreenCycle()) {
      return false;
    }

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
        vectorMapFolder + folderName + "/" + blockX + "_" + blockY;

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
      newBlock->mercatorScale = map_projection::mercatorScaleForLatitude(
          Maps::mercatorY2lat(static_cast<double>(req.y) +
                              (1 << (MAPBLOCK_SIZE_BITS - 1))));
      memCache.blocks.push_back(newBlock);
      loadedBlocks++;

      ESP_LOGI(TAG, "Block loaded: %p, offset(%d, %d)", newBlock, req.x, req.y);
      ESP_LOGI(TAG, "FreeHeap: %d", (int)esp_get_free_heap_size());
    } else {
      delete newBlock;
    }

    if (shouldInterruptMapRenderForScreenCycle()) {
      return false;
    }
  }

  // readMapBlock() reports the result of the most recent disk lookup through
  // isMapFound. Recompute the aggregate state so a missing neighboring block,
  // or an earlier interrupted load followed by cache-only hits, cannot hide
  // valid map data that is already available for this viewport.
  bool hasVisibleMapBlock = false;
  for (const MapBlock *block : memCache.blocks) {
    if (block->inView) {
      hasVisibleMapBlock = true;
      break;
    }
  }
  Maps::isMapFound = hasVisibleMapBlock;

  ESP_LOGI(TAG, "memCache size: %i %i", memCache.blocks.size(), millis());
  MAPIO_LOG("MAPIO: blocks required=%u cacheHit=%u loaded=%u evicted=%u "
            "cache=%u elapsedMs=%lu\n",
            (unsigned)requiredOffsets.size(), (unsigned)cacheHits,
            (unsigned)loadedBlocks, (unsigned)evictedBlocks,
            (unsigned)memCache.blocks.size(),
            (unsigned long)(MAPIO_TIME_MS() - blocksStartMs));
  return true;
}

bool Maps::drawStreetLabels(ViewPort &viewPort, MemCache &memCache,
                            lv_obj_t *canvas, uint8_t zoom, double rotation,
                            const ScreenMapRenderSettings &style) {
  if (style.labelDensity == 0 || !labelFontAsset.healthy())
    return true;
  const uint32_t labelStartMs = MAPIO_TIME_MS();
  const uint32_t cacheHitsBefore = labelFontAsset.cacheHits();
  const uint32_t cacheMissesBefore = labelFontAsset.cacheMisses();
  const uint32_t cacheEvictionsBefore = labelFontAsset.cacheEvictions();
  size_t peakDecodedLabelBytes = 0;
  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
  if (drawBuffer == nullptr || drawBuffer->data == nullptr)
    return true;
  const bool transparentSurface =
      drawBuffer->header.cf == LV_COLOR_FORMAT_RGB565A8;
  if (!transparentSurface &&
      drawBuffer->header.cf != LV_COLOR_FORMAT_RGB565) {
    ESP_LOGE(TAG, "Street labels require an RGB565 or RGB565A8 surface");
    return true;
  }

  const int32_t screenWidth = drawBuffer->header.w;
  const int32_t screenHeight = drawBuffer->header.h;
  const int16_t screenAnchorX = mapAnchorXForWidth(screenWidth);
  const int16_t screenAnchorY = mapAnchorYForHeight(screenHeight);
  float markerX = screenAnchorX;
  float markerY = screenAnchorY;
  bool markerVisible = false;
  if (isCurrentPositionVisible(mapRenderSettings)) {
    if (!followGps) {
      const auto markerDelta = map_transform::worldToScreen(
          {lon2x(gps.gpsData.longitude) - viewPort.center.x,
           lat2y(gps.gpsData.latitude) - viewPort.center.y},
          zoom, rotation);
      markerX += markerDelta.x;
      markerY += markerDelta.y;
    }
    const float markerHalf = currentMarkerSize() * 0.5F;
    markerVisible = markerX + markerHalf >= 0 && markerY + markerHalf >= 0 &&
                    markerX - markerHalf < screenWidth &&
                    markerY - markerHalf < screenHeight;
  }
  constexpr float LABEL_PI = 3.14159265358979323846F;
  constexpr size_t MAX_GATHERED_CANDIDATES = 4096;
  // Half-degree rotation buckets move an edge-of-screen label by at most two
  // pixels and make repeated sensor redraws reuse one stable collision result.
  const int16_t rotationBucket = static_cast<int16_t>(
      std::lround(rotation * 360.0 / static_cast<double>(LABEL_PI)));
  const double labelRotation =
      rotationBucket * static_cast<double>(LABEL_PI) / 360.0;
  const double mapCosine = std::cos(labelRotation);
  const double mapSine = std::sin(labelRotation);
  const int32_t centerQuantum = zoom >= 3 ? zoom - 1 : 1;
  const auto quantize = [](int32_t value, int32_t quantum) {
    if (quantum <= 1)
      return value;
    return (value >= 0 ? value + quantum / 2 : value - quantum / 2) /
           quantum * quantum;
  };
  Point32 labelCenter = viewPort.center;
  labelCenter.x = quantize(labelCenter.x, centerQuantum);
  labelCenter.y = quantize(labelCenter.y, centerQuantum);
  const uint8_t sizeId = std::min<uint8_t>(style.labelTextSize, 2);
  const float fontPixels[3] = {18.0F, 22.0F, 26.0F};

  uint64_t blockSignature = 1469598103934665603ULL;
  const auto mixSignature = [&](uint32_t value) {
    blockSignature ^= value;
    blockSignature *= 1099511628211ULL;
  };
  for (const MapBlock *block : memCache.blocks) {
    mixSignature(static_cast<uint32_t>(block->offset.x));
    mixSignature(static_cast<uint32_t>(block->offset.y));
    mixSignature(block->inView ? 1U : 0U);
    mixSignature(block->formatVersion);
    mixSignature(block->labelData.profileFingerprint);
    mixSignature(static_cast<uint32_t>(block->labelData.labels.size()));
  }
  const bool guidance = isMapGuidanceScreenActive();
  const LabelLayoutCacheKey cacheKey{
      labelCenter.x,
      labelCenter.y,
      rotationBucket,
      static_cast<uint16_t>(screenWidth),
      static_cast<uint16_t>(screenHeight),
      labelFontAsset.profileFingerprint(),
      style.visibilityMask,
      blockSignature,
      zoom,
      style.labelDensity,
      style.labelLanguageMode,
      sizeId,
      style.labelOrientation,
      markerVisible ? static_cast<int16_t>(std::lround(markerX)) : 0,
      markerVisible ? static_cast<int16_t>(std::lround(markerY)) : 0,
      style.positionMarkerScale,
      markerVisible,
      guidance};

  struct RenderItem {
    uint32_t key = 0;
    const map_label_block::ShapedRun *runs[2] = {nullptr, nullptr};
    uint8_t runCount = 0;
    float widths[2] = {0, 0};
  };
  MapLabelLayoutVector<map_label_layout::Option> options;
  std::vector<RenderItem, PsramAllocator<RenderItem>> items;
  using ItemIndexValue = std::pair<const uint32_t, size_t>;
  std::unordered_map<uint32_t, size_t, std::hash<uint32_t>,
                     std::equal_to<uint32_t>, PsramAllocator<ItemIndexValue>>
      itemByKey;
  options.reserve(MAX_GATHERED_CANDIDATES);
  items.reserve(1024);
  itemByKey.reserve(1024);

  const auto transformed = [&](Point16 point, Point16 center) {
    double dx = 0;
    double dy = 0;
    if (zoom == 0) {
      dx = static_cast<double>(point.x - center.x) * 2.0;
      dy = -static_cast<double>(point.y - center.y) * 2.0;
    } else if (zoom == 1) {
      dx = static_cast<double>(point.x - center.x) * 1.5;
      dy = -static_cast<double>(point.y - center.y) * 1.5;
    } else {
      const int divisor = zoom - 1;
      dx = static_cast<double>(point.x - center.x) / divisor;
      dy = -static_cast<double>(point.y - center.y) / divisor;
    }
    return Point16(static_cast<int16_t>(std::round(dx * mapCosine -
                                                   dy * mapSine)) +
                       screenAnchorX,
                   static_cast<int16_t>(std::round(dx * mapSine +
                                                   dy * mapCosine)) +
                       screenAnchorY);
  };
  const auto runWidth = [](const map_label_block::ShapedRun &run) {
    int32_t advance = 0;
    for (const auto &glyph : run.glyphs)
      advance += glyph.xAdvance26_6;
    return std::fabs(static_cast<float>(advance) / 64.0F);
  };
  // Rank buckets bound gathering before the layout sort, ensuring dense local
  // roads cannot crowd out high-priority road names merely due to block order.
  for (uint8_t rankBucket = 0;
       rankBucket <= 6 && options.size() < MAX_GATHERED_CANDIDATES;
       ++rankBucket) {
    for (size_t blockIndex = 0;
         blockIndex < memCache.blocks.size() &&
         options.size() < MAX_GATHERED_CANDIDATES;
         ++blockIndex) {
      MapBlock *block = memCache.blocks[blockIndex];
      if (block->inView)
        peakDecodedLabelBytes =
            std::max(peakDecodedLabelBytes, block->labelData.decodedBytes());
      if (!block->inView || block->formatVersion < 3 ||
          block->labelData.profileFingerprint !=
              labelFontAsset.profileFingerprint() ||
          !block->labelData.referencesResolve(labelFontAsset.glyphCount(),
                                              labelFontAsset.languageCount()))
        continue;
      const Point16 blockCenter =
          labelCenter.toPoint16() - block->offset.toPoint16();
      for (size_t labelIndex = 0;
           labelIndex < block->labelData.labels.size() &&
           options.size() < MAX_GATHERED_CANDIDATES;
           ++labelIndex) {
        if ((labelIndex & 0x3fU) == 0 &&
            shouldInterruptMapRenderForScreenCycle())
          return false;
        const auto &label = block->labelData.labels[labelIndex];
        if (label.rank != rankBucket || zoom < label.minZoom ||
            zoom > label.maxZoom ||
            label.polylineIndex >= block->polylines.size())
          continue;
        const Polyline &road = block->polylines[label.polylineIndex];
        if (!isLineVisible(road.typeId, road.color, road.width, style))
          continue;

        const auto selection =
            map_label_selection::select(label, style.labelLanguageMode);
        if (selection.count == 0)
          continue;

        RenderItem item;
        item.key = (static_cast<uint32_t>(blockIndex + 1U) << 16U) |
                   static_cast<uint32_t>(labelIndex + 1U);
        bool validRuns = true;
        float measuredWidth = 0;
        for (uint8_t line = 0; line < selection.count; ++line) {
          const uint16_t runId = selection.lines[line]->runIds[sizeId];
          if (runId == 0 || runId > block->labelData.runs.size()) {
            validRuns = false;
            break;
          }
          item.runs[line] = &block->labelData.runs[runId - 1U];
          item.widths[line] = runWidth(*item.runs[line]);
          measuredWidth = std::max(measuredWidth, item.widths[line]);
        }
        if (!validRuns || measuredWidth <= 0)
          continue;
        item.runCount = selection.count;
        const size_t itemIndex = items.size();
        items.push_back(item);
        itemByKey[item.key] = itemIndex;
        const float measuredHeight =
            fontPixels[sizeId] * selection.count +
            (selection.count == 2 ? 4.0F : 0.0F) + 6.0F;

        for (const auto &candidate : label.candidates) {
          if (options.size() >= MAX_GATHERED_CANDIDATES)
            break;
          const Point16 start = transformed(
              Point16(candidate.startX, candidate.startY), blockCenter);
          const Point16 end =
              transformed(Point16(candidate.endX, candidate.endY), blockCenter);
          const float dx = static_cast<float>(end.x - start.x);
          const float dy = static_cast<float>(end.y - start.y);
          if (std::hypot(dx, dy) < measuredWidth + 12.0F)
            continue;
          float angle = style.labelOrientation == 0 ? std::atan2(dy, dx) : 0;
          if (angle > LABEL_PI * 0.5F)
            angle -= LABEL_PI;
          else if (angle < -LABEL_PI * 0.5F)
            angle += LABEL_PI;
          options.push_back(
              {item.key,
               label.repeatGroup,
               static_cast<uint16_t>(blockIndex),
               static_cast<uint16_t>(labelIndex),
               label.rank,
               candidate.quality,
               (start.x + end.x) * 0.5F,
               (start.y + end.y) * 0.5F,
               angle,
               measuredWidth + 6.0F,
               measuredHeight});
        }
      }
    }
  }

  if (options.empty())
    return true;
  std::vector<map_label_layout::ReservedRegion> reserved;
  if (markerVisible) {
    const float markerSize = static_cast<float>(currentMarkerSize());
    reserved.push_back({markerX, markerY, markerSize, markerSize});
  }
  if (guidance)
    reserved.push_back(
        {screenWidth * 0.5F, 34.0F, static_cast<float>(screenWidth), 68.0F});
  const size_t gatheredOptions = options.size();
  map_label_layout::Diagnostics layoutDiagnostics;
  const uint32_t layoutStartMs = MAPIO_TIME_MS();
  const bool layoutCacheHit = labelLayoutCache.valid &&
                              labelLayoutCache.key == cacheKey;
  MapLabelLayoutVector<map_label_layout::Placement> placements;
  if (layoutCacheHit) {
    placements = labelLayoutCache.placements;
    layoutDiagnostics = labelLayoutCache.diagnostics;
  } else {
    placements = map_label_layout::place(
        std::move(options),
        {static_cast<float>(screenWidth), static_cast<float>(screenHeight)},
        style.labelDensity, reserved, &layoutDiagnostics);
    labelLayoutCache.key = cacheKey;
    labelLayoutCache.placements = placements;
    labelLayoutCache.diagnostics = layoutDiagnostics;
    labelLayoutCache.valid = true;
  }
  const uint32_t layoutMs = MAPIO_TIME_MS() - layoutStartMs;
  const uint32_t drawLabelsStartMs = MAPIO_TIME_MS();

  uint16_t *pixels = reinterpret_cast<uint16_t *>(drawBuffer->data);
  const uint32_t stride = drawBuffer->header.stride / sizeof(uint16_t);
  uint8_t *alphaPixels =
      transparentSurface
          ? static_cast<uint8_t *>(drawBuffer->data) +
                static_cast<size_t>(drawBuffer->header.stride) * screenHeight
          : nullptr;
  const uint32_t alphaStride = transparentSurface ? stride : 0;
  const lv_draw_buf_t *contrastBuffer = nullptr;
  int32_t contrastOffsetX = 0;
  int32_t contrastOffsetY = 0;
  if (transparentSurface && Maps::canvasMap != nullptr) {
    contrastBuffer = lv_canvas_get_draw_buf(Maps::canvasMap);
    if (contrastBuffer == nullptr || contrastBuffer->data == nullptr ||
        contrastBuffer->header.cf != LV_COLOR_FORMAT_RGB565) {
      contrastBuffer = nullptr;
    } else {
      contrastOffsetX = lv_obj_get_x_aligned(canvas) -
                        lv_obj_get_x_aligned(Maps::canvasMap);
      contrastOffsetY = lv_obj_get_y_aligned(canvas) -
                        lv_obj_get_y_aligned(Maps::canvasMap);
    }
  }
  for (const auto &placement : placements) {
    if (shouldInterruptMapRenderForScreenCycle())
      return false;
    const auto itemPosition = itemByKey.find(placement.option.labelKey);
    if (itemPosition == itemByKey.end())
      continue;
    const RenderItem &item = items[itemPosition->second];
    const int32_t centerX = static_cast<int32_t>(placement.option.centerX);
    const int32_t centerY = static_cast<int32_t>(placement.option.centerY);
    if (centerX < 0 || centerX >= screenWidth || centerY < 0 ||
        centerY >= screenHeight)
      continue;
    uint16_t fillColor = 0x0000U;
    uint16_t haloColor = 0xffffU;
    uint16_t background = 0;
    bool hasBackgroundSample = false;
    if (!transparentSurface) {
      background = pixels[centerY * stride + centerX];
      hasBackgroundSample = true;
    } else if (contrastBuffer != nullptr) {
      const int32_t contrastX = centerX + contrastOffsetX;
      const int32_t contrastY = centerY + contrastOffsetY;
      if (contrastX >= 0 && contrastY >= 0 &&
          contrastX < contrastBuffer->header.w &&
          contrastY < contrastBuffer->header.h) {
        const auto *contrastPixels =
            reinterpret_cast<const uint16_t *>(contrastBuffer->data);
        const uint32_t contrastStride =
            contrastBuffer->header.stride / sizeof(uint16_t);
        background =
            contrastPixels[contrastY * contrastStride + contrastX];
        hasBackgroundSample = true;
      }
    }
    if (hasBackgroundSample) {
      const uint32_t luminance =
          ((background >> 11U) & 0x1fU) * 299U * 255U / 31U +
          ((background >> 5U) & 0x3fU) * 587U * 255U / 63U +
          (background & 0x1fU) * 114U * 255U / 31U;
      fillColor = luminance > 128000U ? 0x0000U : 0xffffU;
      haloColor = luminance > 128000U ? 0xffffU : 0x0000U;
    }
    const map_label_rasterizer::TransformQ15 transform{
        centerX,
        centerY,
        static_cast<int32_t>(std::lround(
            std::cos(placement.option.angleRadians) *
            map_label_rasterizer::kQ15One)),
        static_cast<int32_t>(std::lround(
            std::sin(placement.option.angleRadians) *
            map_label_rasterizer::kQ15One))};
    const int32_t fontHeight = static_cast<int32_t>(fontPixels[sizeId]);
    const int32_t totalHeight =
        fontHeight * item.runCount + (item.runCount == 2 ? 4 : 0);

    for (uint8_t pass = 0; pass < 2; ++pass) {
      for (uint8_t line = 0; line < item.runCount; ++line) {
        const auto &run = *item.runs[line];
        int32_t totalAdvance26_6 = 0;
        for (const auto &glyph : run.glyphs)
          totalAdvance26_6 += glyph.xAdvance26_6;
        int32_t penX26_6 = -std::abs(totalAdvance26_6) / 2;
        const int32_t baselineY26_6 =
            -totalHeight * 32 + line * (fontHeight + 4) * 64 +
            fontHeight * 50;
        for (const auto &glyph : run.glyphs) {
          map_font_asset::GlyphBitmap bitmap;
          if (!labelFontAsset.loadGlyph(glyph.glyphId, sizeId, bitmap)) {
            const char *error = map_font_asset::runtimeErrorCode(
                labelFontAsset.runtimeError());
            MAPIO_LOG("MAPIO: label-font-failure code=%s consecutive=%u "
                      "healthy=%u\n",
                      error, (unsigned)labelFontAsset.consecutiveFailures(),
                      (unsigned)labelFontAsset.healthy());
            if (!labelFontAsset.healthy()) {
              streetLabelRuntimeFailurePending = true;
              streetLabelRuntimeFailureCode = error;
              labelLayoutCache.clear();
            }
            return true; // Keep the base map visible on any asset I/O failure.
          }
          const int32_t glyphX26_6 = penX26_6 + glyph.xOffset26_6 +
                                     bitmap.bearingX * 64;
          const int32_t glyphY26_6 = baselineY26_6 - glyph.yOffset26_6 -
                                     bitmap.bearingY * 64;
          const bool drawn =
              transparentSurface
                  ? map_label_rasterizer::drawGlyphPassRgb565A8(
                        pixels, alphaPixels, screenWidth, screenHeight,
                        stride, alphaStride, bitmap.fill, bitmap.distance,
                        bitmap.width, bitmap.height, glyphX26_6, glyphY26_6,
                        transform, pass, fillColor, haloColor,
                        shouldInterruptMapRenderForScreenCycle)
                  : map_label_rasterizer::drawGlyphPass(
                        pixels, screenWidth, screenHeight, stride, bitmap.fill,
                        bitmap.distance, bitmap.width, bitmap.height,
                        glyphX26_6, glyphY26_6, transform, pass, fillColor,
                        haloColor, shouldInterruptMapRenderForScreenCycle);
          if (!drawn)
            return false;
          penX26_6 += glyph.xAdvance26_6;
        }
      }
    }
  }
  MAPIO_LOG(
      "MAPIO: labels gathered=%u invalid=%u duplicate=%u outside=%u "
      "collisionTested=%u collision=%u capacity=%u accepted=%u "
      "layoutCacheHit=%u layoutMs=%lu drawMs=%lu totalMs=%lu "
      "cacheHit=%lu cacheMiss=%lu cacheEvict=%lu cacheBytes=%u "
      "decodedBlockPeakBytes=%u\n",
      (unsigned)gatheredOptions,
      (unsigned)layoutDiagnostics.invalidOrDensityRejected,
      (unsigned)layoutDiagnostics.duplicateRejected,
      (unsigned)layoutDiagnostics.outsideScreenRejected,
      (unsigned)layoutDiagnostics.collisionTested,
      (unsigned)layoutDiagnostics.collisionRejected,
      (unsigned)layoutDiagnostics.capacityRejected,
      (unsigned)placements.size(), (unsigned)layoutCacheHit,
      (unsigned long)layoutMs,
      (unsigned long)(MAPIO_TIME_MS() - drawLabelsStartMs),
      (unsigned long)(MAPIO_TIME_MS() - labelStartMs),
      (unsigned long)(labelFontAsset.cacheHits() - cacheHitsBefore),
      (unsigned long)(labelFontAsset.cacheMisses() - cacheMissesBefore),
      (unsigned long)(labelFontAsset.cacheEvictions() - cacheEvictionsBefore),
      (unsigned)labelFontAsset.cachedBytes(), (unsigned)peakDecodedLabelBytes);
  return true;
}

/**
 * @brief Generate vectorized map
 *
 * @param viewPort
 * @param memblocks
 * @param map -> Map Sprite
 * @param zoom -> Zoom Level
 */
bool Maps::readVectorMap(ViewPort &viewPort, MemCache &memCache,
                         lv_obj_t *canvas, uint8_t zoom, double rotation,
                         const map_projection::Projection &projection,
                         bool drawLabels, bool suppressBuildings) {
  (void)rotation;
  Polygon newPolygon;
  std::vector<map_projection::GroundPoint> groundPolygon;
  std::vector<map_projection::GroundPoint> clippedGroundPolygon;
  const ScreenMapRenderSettings &style = currentMapStyleSettings();
  const bool mapNavigationActive = isMapGuidanceScreenActive();
  const bool guidanceBirdsEye = mapNavigationActive && projection.isBirdsEye();
  constexpr uint32_t kGuidanceBuildingTimeBudgetMs = 900U;
  constexpr size_t kGuidanceMaximumQueuedBuildingRecords = 2048U;
  constexpr double kGuidanceFarBuildingCutoffFraction = 0.20;
  // Guidance renders on the UI task. Keep the optional 3D pass bounded so a
  // dense city cannot starve GPS/scene updates for several seconds. The
  // normal-map budget remains unchanged; if guidance reaches this limit, the
  // existing retry path presents the same frame with buildings suppressed,
  // leaving the 2D roads/land-use map intact.
  const uint32_t buildingTimeBudgetMs =
      guidanceBirdsEye
          ? kGuidanceBuildingTimeBudgetMs
          : map_building_renderer::kMaximumBuildingRenderTimeMs;
  const size_t maximumQueuedBuildingRecords =
      guidanceBirdsEye
          ? kGuidanceMaximumQueuedBuildingRecords
          : map_building_renderer::kMaximumRenderedBuildingRecords;
  uint64_t buildingContextSignature = 1469598103934665603ULL;
  const auto mixBuildingContext = [&](uint64_t value) {
    buildingContextSignature ^= value;
    buildingContextSignature *= 1099511628211ULL;
  };
  mixBuildingContext(zoom);
  mixBuildingContext(projection.isBirdsEye() ? 1U : 0U);
  mixBuildingContext(style.visibilityMask);
  mixBuildingContext(mapRenderSettings.mapNavigation3DBuildingsEnabled ? 1U
                                                                      : 0U);
  mixBuildingContext(mapRenderSettings.mapNavigationBirdsEyePerspective);
  for (const MapBlock *block : memCache.blocks) {
    if (!block->inView || block->formatVersion < 4)
      continue;
    mixBuildingContext(static_cast<uint32_t>(block->offset.x));
    mixBuildingContext(static_cast<uint32_t>(block->offset.y));
    mixBuildingContext(block->formatVersion);
    mixBuildingContext(block->buildingData.stats.records);
    mixBuildingContext(block->buildingData.stats.points);
  }
  const map_building_renderer::RenderRegion buildingRenderRegion{
      viewPort.bbox.min.x, viewPort.bbox.min.y, viewPort.bbox.max.x,
      viewPort.bbox.max.y};
  const bool buildingsSuppressed =
      suppressBuildings || buildingFailureRetryCooldown.shouldSuppress(
                               millis(), buildingContextSignature,
                               buildingRenderRegion);
  uint32_t projectionClippedCount = 0;
  uint32_t projectionRejectedCount = 0;
  const uint32_t drawStartMs = MAPIO_TIME_MS();
  const uint32_t fillStartMs = MAPIO_TIME_MS();
  lv_canvas_fill_bg(canvas, lv_color_hex(BACKGROUND_COLOR), LV_OPA_COVER);
  const uint32_t fillMs = MAPIO_TIME_MS() - fillStartMs;

  uint32_t totalTime = millis();
  log_i("readVectorMap: Draw start. isMapFound=%d, Blocks=%d", Maps::isMapFound,
        memCache.blocks.size());

  if (!Maps::isMapFound || memCache.blocks.empty()) {
    log_w("readVectorMap: No map data found for this location!");
    Maps::showNoMap(canvas, storage.getSdLoaded());
    MAPIO_LOG("MAPIO: canvas-draw ok=0 blocks=%u fillMs=%lu totalMs=%lu\n",
              (unsigned)memCache.blocks.size(), (unsigned long)fillMs,
              (unsigned long)(MAPIO_TIME_MS() - drawStartMs));
    return true;
  }

  int16_t p1x, p1y, p2x, p2y;
  if (Maps::isMapFound) {
    for (MapBlock *mblock : memCache.blocks) {
      if (shouldInterruptMapRenderForScreenCycle()) {
        return false;
      }
      uint32_t blockTime = millis();
      if (!mblock->inView)
        continue;

      ScreenMapRenderSettings blockStyle = style;
      blockStyle.visibilityMask =
          map_profile_protocol::visibilityMaskForMapVersion(
              style.visibilityMask, mblock->formatVersion);

      ESP_LOGI(TAG, "Drawing cached map block");

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

      auto worldPoint = [&](Point16 p) -> map_transform::WorldPoint {
        return {static_cast<double>(p.x) + mblock->offset.x,
                static_cast<double>(p.y) + mblock->offset.y};
      };
      auto projectedPoint = [&](map_projection::GroundPoint ground) -> Point16 {
        const auto projected = projection.projectGround(ground);
        return Point16(
            static_cast<int16_t>(map_transform::quantizePixel(projected.x)),
            static_cast<int16_t>(map_transform::quantizePixel(projected.y)));
      };

      // Iterate only through cells that overlap the viewport
      for (int cy = minCY; cy <= maxCY; cy++) {
        for (int cx = minCX; cx <= maxCX; cx++) {
          int cellIdx = cy * GRID_SIZE + cx;

          // Check bounds on polygonGrid access
          if (cellIdx < 0 || cellIdx >= (int)mblock->polygonGrid.size())
            continue;

          for (uint16_t polyIdx : mblock->polygonGrid[cellIdx]) {
            if ((poly_checked & 0x0F) == 0 &&
                shouldInterruptMapRenderForScreenCycle()) {
              return false;
            }
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
            if (!isPolygonVisible(polygon.typeId, polygon.color, blockStyle)) {
              continue;
            }

            poly_drawn++;
            newPolygon.color = polygon.color;

            // Transform points to screen coordinates
            newPolygon.points.clear();
            int16_t minX = 32000, maxX = -32000, minY = 32000, maxY = -32000;

            groundPolygon.clear();
            groundPolygon.reserve(polygon.points.size());
            for (const auto &p : polygon.points)
              groundPolygon.push_back(projection.groundForWorld(worldPoint(p)));
            const auto *projectedPolygon = &groundPolygon;
            if (projection.isBirdsEye()) {
              map_projection::clipPolygonToNearPlane(
                  projection, groundPolygon, clippedGroundPolygon);
              projectedPolygon = &clippedGroundPolygon;
              if (clippedGroundPolygon.size() != groundPolygon.size())
                projectionClippedCount++;
            }
            if (projectedPolygon->size() < 3) {
              projectionRejectedCount++;
              poly_drawn--;
              continue;
            }

            for (const auto &ground : *projectedPolygon) {
              Point16 tp = projectedPoint(ground);
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
                effectiveMinPolygonSize(blockStyle);
            int16_t polyWidth = maxX - minX;
            int16_t polyHeight = maxY - minY;
            if (minPolygonSize > 0 &&
                polyWidth * polyHeight < minPolygonSize * minPolygonSize) {
              poly_drawn--; // Don't count as drawn
              continue;
            }

            if (!Maps::fillPolygon(newPolygon, canvas)) {
              return false;
            }
          }
        }
      }
#if FIRMWARE_DIAGNOSTICS
      Serial.printf("[Maps] Block polygons: Total=%d, Checked=%d, Drawn=%d\n",
                    poly_total, poly_checked, poly_drawn);
#endif
      const uint32_t polygonMs = millis() - polygonStartMs;
      log_i("Block polygons done %i ms", polygonMs);
      const uint32_t lineStartMs = millis();

      ////// Lines
      // Removed lv_draw_line usage to fix crash
      for (const auto &line : mblock->polylines) {
        if (shouldInterruptMapRenderForScreenCycle()) {
          return false;
        }
        if (zoom > line.maxZoom)
          continue;
        if (!line.bbox.intersects(screen_bbox_mc))
          continue;

        if (line.points.size() < 2)
          continue;

        // Skip if type is hidden by visibility mask
        if (!isLineVisible(line.typeId, line.color, line.width, blockStyle))
          continue;

        const uint16_t color_swapped = map_line_style::displayColor(
            line.typeId, line.color, line.width, mapNavigationActive);

        const uint8_t baseLineWidth =
            shouldBoostLineWidth(line.typeId, line.width)
                ? blockStyle.streetLineWidth
                : static_cast<uint8_t>(std::max<int32_t>(line.width, 1));

        for (int i = 0; i < (int)line.points.size() - 1; i++) {
          if ((i & 0x0F) == 0 &&
              shouldInterruptMapRenderForScreenCycle()) {
            return false;
          }
          auto ground1 = projection.groundForWorld(worldPoint(line.points[i]));
          auto ground2 =
              projection.groundForWorld(worldPoint(line.points[i + 1]));
          if (!projection.clipSegmentToNearPlane(ground1, ground2)) {
            projectionRejectedCount++;
            continue;
          }
          if (projection.isBirdsEye() &&
              (ground1.forward == projection.nearPlaneForward() ||
               ground2.forward == projection.nearPlaneForward())) {
            projectionClippedCount++;
          }
          const auto projected1 = projection.projectGround(ground1);
          const auto projected2 = projection.projectGround(ground2);
          if (!projected1.valid || !projected2.valid) {
            projectionRejectedCount++;
            continue;
          }
          const uint8_t lineWidth = projection.scaledLineWidth(
              baseLineWidth,
              (projected1.depthScale + projected2.depthScale) / 2.0, 24);
          Maps::drawLine(
              canvas,
              static_cast<int16_t>(map_transform::quantizePixel(projected1.x)),
              static_cast<int16_t>(map_transform::quantizePixel(projected1.y)),
              static_cast<int16_t>(map_transform::quantizePixel(projected2.x)),
              static_cast<int16_t>(map_transform::quantizePixel(projected2.y)),
              color_swapped, lineWidth);
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
    struct BuildingRenderItem {
      MapBlock *block = nullptr;
      const map_building_block::Building *building = nullptr;
      double depth = 0.0;
      uint16_t recordIndex = 0;
      size_t pointCount = 0;
      bool render = false;
      bool extrude = false;
      bool extrusionCandidate = false;

      uint8_t buildingFlags() const { return building->flags; }
      bool eligibleForExtrusion() const { return extrusionCandidate; }
    };
    bool buildingAllocationFailed = false;
    bool buildingDeadlineAborted = false;
    bool buildingPrepassDeadlineExceeded = false;
    size_t visibleBuildingCount = 0;
    uint64_t buildingPointCount = 0;
    size_t renderTimeOverflow = 0;
    uint32_t renderedBuildings = 0;
    uint32_t extrudedBuildings = 0;
    uint32_t buildingProjectionMs = 0;
    uint32_t buildingSortMs = 0;
    uint32_t buildingDrawMs = 0;
    uint32_t buildingFailurePsramUsed = 0;
    uint32_t buildingFailurePsramFree = 0;
    uint32_t buildingFailurePsramLargest = 0;
    bool buildingFailurePsramSamplePostCleanup = false;
    const auto captureBuildingFailureMemory = [&]() {
      buildingFailurePsramFree =
          heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
      buildingFailurePsramLargest =
          heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
      buildingFailurePsramUsed =
          ESP.getPsramSize() - buildingFailurePsramFree;
    };
    std::vector<BuildingRenderItem, PsramAllocator<BuildingRenderItem>>
        buildingQueue;
    map_building_renderer::RenderSelection renderSelection;
    map_building_renderer::ExtrusionSelection buildingSelection;
    MapBuildingVector<map_projection::GroundPoint> buildingEligibilityGround;
    MapBuildingVector<map_projection::GroundPoint> buildingEligibilityClipped;
    Polygon buildingPolygon;
    std::vector<Point16, PsramAllocator<Point16>> buildingSurfacePoints;
    std::vector<uint16_t, PsramAllocator<uint16_t>> courtyardUnderlay;
    std::vector<int32_t, PsramAllocator<int32_t>> courtyardScanlineNodes;
    map_building_renderer::SurfaceStats buildingSurfaceStats;
    const auto releaseBuildingFailureWorkspace = [&]() {
      decltype(buildingQueue){}.swap(buildingQueue);
      decltype(buildingEligibilityGround){}.swap(buildingEligibilityGround);
      decltype(buildingEligibilityClipped){}.swap(buildingEligibilityClipped);
      decltype(buildingPolygon.points){}.swap(buildingPolygon.points);
      decltype(buildingSurfacePoints){}.swap(buildingSurfacePoints);
      decltype(courtyardUnderlay){}.swap(courtyardUnderlay);
      decltype(courtyardScanlineNodes){}.swap(courtyardScanlineNodes);
    };
    static uint64_t renderTimeOverflowTotal = 0;
    map_building_block::Stats loadedBuildingStats;
    for (const MapBlock *block : memCache.blocks) {
      if (!block->inView || block->formatVersion < 4)
        continue;
      loadedBuildingStats.records += block->buildingData.stats.records;
      loadedBuildingStats.rings += block->buildingData.stats.rings;
      loadedBuildingStats.points += block->buildingData.stats.points;
      for (size_t index = 0; index < loadedBuildingStats.provenance.size();
           ++index) {
        loadedBuildingStats.provenance[index] +=
            block->buildingData.stats.provenance[index];
      }
    }
    enum class BuildingPassPhase : uint8_t { Projection, Sort, Draw, Complete };
    BuildingPassPhase buildingPassPhase = BuildingPassPhase::Projection;
    uint32_t buildingPhaseStartMs = millis();
    const uint32_t buildingPassStartMs = buildingPhaseStartMs;
    const auto finishBuildingPhaseTiming = [&]() {
      const uint32_t elapsed = millis() - buildingPhaseStartMs;
      switch (buildingPassPhase) {
      case BuildingPassPhase::Projection:
        buildingProjectionMs = elapsed;
        break;
      case BuildingPassPhase::Sort:
        buildingSortMs = elapsed;
        break;
      case BuildingPassPhase::Draw:
        buildingDrawMs = elapsed;
        break;
      case BuildingPassPhase::Complete:
        break;
      }
      buildingPassPhase = BuildingPassPhase::Complete;
    };
    const bool buildingPassCompleted =
        map_building_renderer::runAllocationSafe(
            [&]() -> bool {
    const auto buildingRendersBefore =
        [](const BuildingRenderItem &left, const BuildingRenderItem &right) {
          return map_building_renderer::rendersBefore(
              {left.depth, left.block->offset.x, left.block->offset.y,
               left.recordIndex},
              {right.depth, right.block->offset.x, right.block->offset.y,
               right.recordIndex});
        };
    const bool buildingsVisible =
        !buildingsSuppressed &&
        (style.visibilityMask & MAP_VISIBILITY_BUILDINGS) != 0;
    bool extrudeBuildings =
        navigation_content_mode::extrudesMapGuidanceBuildings(
            buildingsVisible, mapNavigationActive, projection.isBirdsEye(),
            mapRenderSettings.mapNavigation3DBuildingsEnabled);
    size_t boundedBuildingCandidateCount = 0;
    size_t oversizedBuildingCount = 0;
    size_t renderRecordLimitOverflow = 0;
    uint64_t visibleWallCandidateCount = 0;
    bool buildingBudgetFallback = false;
    bool buildingDeadlineExceeded = false;
    bool buildingScreenInterrupted = false;
    static uint64_t renderRecordOverflowTotal = 0;
    static uint64_t renderPointOverflowTotal = 0;
    static uint64_t renderOversizedOverflowTotal = 0;
    static uint64_t extrusionRecordOverflowTotal = 0;
    static uint64_t extrusionPointOverflowTotal = 0;
    const auto buildingDeadlineReached = [&]() {
      return millis() - buildingPassStartMs >= buildingTimeBudgetMs;
    };
    const auto shouldStopBuildingWork = [&]() {
      if (shouldInterruptMapRenderForScreenCycle()) {
        buildingScreenInterrupted = true;
        return true;
      }
      if (buildingDeadlineReached()) {
        buildingDeadlineExceeded = true;
        return true;
      }
      return false;
    };
    const auto abortStoppedBuildingWork = [&](size_t timeOverflow) -> bool {
      finishBuildingPhaseTiming();
      if (buildingDeadlineExceeded) {
        captureBuildingFailureMemory();
        buildingDeadlineAborted = true;
        const size_t countedOverflow = std::max<size_t>(1, timeOverflow);
        renderTimeOverflow += countedOverflow;
        renderTimeOverflowTotal += countedOverflow;
      }
      return false;
    };
    if (buildingsVisible) {
      buildingPassPhase = BuildingPassPhase::Projection;
      buildingPhaseStartMs = millis();
      bool stopBuildingPrepass = false;
      for (MapBlock *block : memCache.blocks) {
        if (shouldStopBuildingWork()) {
          stopBuildingPrepass = true;
          break;
        }
        if (!block->inView || block->formatVersion < 4)
          continue;
        const BBox screenBbox = viewPort.bbox - block->offset;
        for (size_t recordIndex = 0;
             recordIndex < block->buildingData.buildings.size();
             ++recordIndex) {
          if ((recordIndex & 0x1FU) == 0 && shouldStopBuildingWork()) {
            stopBuildingPrepass = true;
            break;
          }
          const auto &building = block->buildingData.buildings[recordIndex];
          const map_transform::WorldPoint center{
              static_cast<double>(block->offset.x) +
                  (static_cast<double>(building.minX) + building.maxX) / 2.0,
              static_cast<double>(block->offset.y) +
                  (static_cast<double>(building.minY) + building.maxY) / 2.0};
          const auto centerGround = projection.groundForWorld(center);
          const auto centerProjection = projection.projectGround(centerGround);
          // The top of a birds-eye frame is the far field. Keep its building
          // footprints as flat 2D surfaces, reserving wall work for the
          // foreground where it materially improves orientation.
          const bool guidanceExtrusionAllowed =
              !guidanceBirdsEye ||
              (centerProjection.valid &&
               centerProjection.y >=
                   static_cast<double>(projection.config().viewportHeight) *
                       kGuidanceFarBuildingCutoffFraction);
          const bool mayExtrude =
              extrudeBuildings &&
              map_building_renderer::usesExtrusion(true, building.flags) &&
              guidanceExtrusionAllowed;
          // A roof can project into the frame even when its ground footprint is
          // just outside it. Expand conservatively in world space before
          // excluding the record from the queue and its geometry budget.
          const int32_t elevationMargin = mayExtrude
              ? static_cast<int32_t>(std::ceil(
                    building.heightDm / 10.0 * block->mercatorScale))
              : 0;
          const BBox buildingBbox(
              Point32(building.minX - elevationMargin,
                      building.minY - elevationMargin),
              Point32(building.maxX + elevationMargin,
                      building.maxY + elevationMargin));
          if (!buildingBbox.intersects(screenBbox))
            continue;
          size_t pointCount = 0;
          bool stopBuildingRecord = false;
          for (const auto &ring : building.rings) {
            for (size_t pointIndex = 0; pointIndex < ring.points.size();
                 ++pointIndex) {
              if ((pointIndex & 0x1FU) == 0 && shouldStopBuildingWork()) {
                stopBuildingRecord = true;
                break;
              }
              ++pointCount;
              if (mayExtrude && pointIndex < ring.walls.size() &&
                  ring.walls[pointIndex] != 0) {
                ++visibleWallCandidateCount;
              }
            }
            if (stopBuildingRecord)
              break;
          }
          if (stopBuildingRecord) {
            stopBuildingPrepass = true;
            break;
          }
          ++visibleBuildingCount;
          buildingPointCount += pointCount;
          if (pointCount > map_building_renderer::
                               kMaximumRenderedBuildingPointsPerRecord) {
            ++oversizedBuildingCount;
            continue;
          }
          ++boundedBuildingCandidateCount;
          const bool extrusionZoomEligible =
              map_building_renderer::eligibleExtrusionZoom(zoom);
          double projectedArea = 0.0;
          if (mayExtrude && extrusionZoomEligible) {
            projectedArea =
                map_building_renderer::projectedFootprintAreaPixels(
                    building, block->offset.x, block->offset.y, projection,
                    buildingEligibilityGround, buildingEligibilityClipped,
                    shouldStopBuildingWork);
          }
          if (buildingScreenInterrupted || buildingDeadlineExceeded) {
            stopBuildingPrepass = true;
            break;
          }
          BuildingRenderItem candidate{
              block,
              &building,
              centerGround.forward,
              static_cast<uint16_t>(recordIndex),
              pointCount,
              false,
              false,
              mayExtrude && extrusionZoomEligible &&
                  projectedArea >= map_building_renderer::
                                       kMinimumBuildingExtrusionAreaPixels};
          map_building_renderer::retainNearestCandidate(
              buildingQueue, candidate,
              maximumQueuedBuildingRecords,
              buildingRendersBefore);
        }
        if (stopBuildingPrepass)
          break;
      }
      buildingProjectionMs = millis() - buildingPhaseStartMs;
      buildingPassPhase = BuildingPassPhase::Sort;
      buildingPhaseStartMs = millis();
      renderRecordLimitOverflow =
          boundedBuildingCandidateCount - buildingQueue.size();
      if (!stopBuildingPrepass) {
        std::sort(buildingQueue.begin(), buildingQueue.end(),
                  buildingRendersBefore);
        buildingSortMs = millis() - buildingPhaseStartMs;
        if (!shouldStopBuildingWork()) {
          renderSelection = map_building_renderer::selectNearestForRendering(
              buildingQueue.rbegin(), buildingQueue.rend(),
              shouldStopBuildingWork);
          if (!buildingDeadlineExceeded && !buildingScreenInterrupted &&
              extrudeBuildings) {
            // The painter queue is far-to-near. Reserve in reverse so the
            // geometry nearest the rider keeps its walls when a dense city
            // exceeds the bounded extrusion workspace; overflow roofs remain
            // visible and flat.
            buildingSelection =
                map_building_renderer::selectNearestForExtrusion(
                    buildingQueue.rbegin(), buildingQueue.rend(),
                    shouldStopBuildingWork);
            buildingBudgetFallback = buildingSelection.usedFallback();
            extrusionRecordOverflowTotal +=
                buildingSelection.recordLimitOverflow;
            extrusionPointOverflowTotal +=
                buildingSelection.pointLimitOverflow;
          }
        }
      }
      if (buildingDeadlineExceeded) {
        buildingPrepassDeadlineExceeded = true;
        return abortStoppedBuildingWork(buildingQueue.size());
      }
      if (buildingScreenInterrupted)
        return false;
      renderRecordOverflowTotal += renderRecordLimitOverflow;
      renderPointOverflowTotal += renderSelection.pointLimitOverflow;
      renderOversizedOverflowTotal += oversizedBuildingCount;
    }

    buildingPassPhase = BuildingPassPhase::Draw;
    buildingPhaseStartMs = millis();
    const uint16_t roofColor = lv_color_to_u16(lv_color_hex(0xB9B2A8));
    const uint16_t wallLight = lv_color_to_u16(lv_color_hex(0x958E84));
    const uint16_t wallMiddle = lv_color_to_u16(lv_color_hex(0x827B72));
    const uint16_t wallDark = lv_color_to_u16(lv_color_hex(0x6D665E));
    const auto fillScreenPolygon = [&](const auto &points,
                                       uint16_t color) -> bool {
      if (points.size() < 3)
        return true;
      buildingPolygon.points.clear();
      buildingPolygon.color = color;
      int16_t minX = 32767, minY = 32767, maxX = -32768, maxY = -32768;
      for (const Point16 &point : points) {
        buildingPolygon.points.push_back(point);
        minX = std::min(minX, point.x);
        minY = std::min(minY, point.y);
        maxX = std::max(maxX, point.x);
        maxY = std::max(maxY, point.y);
      }
      buildingPolygon.points.push_back(points.front());
      buildingPolygon.bbox.min = Point16(minX, minY);
      buildingPolygon.bbox.max = Point16(maxX, maxY);
      const bool completed = Maps::fillPolygon(
          buildingPolygon, canvas, buildingPassStartMs,
          buildingTimeBudgetMs);
      if (!completed)
        shouldStopBuildingWork();
      return completed;
    };
    const auto countRenderTimeOverflowFrom = [&](size_t itemIndex) {
      size_t overflow = 0;
      for (size_t remaining = itemIndex; remaining < buildingQueue.size();
           ++remaining) {
        if (buildingQueue[remaining].render)
          ++overflow;
      }
      return overflow;
    };
    for (size_t itemIndex = 0;
         !buildingDeadlineExceeded && itemIndex < buildingQueue.size();
         ++itemIndex) {
      const auto &item = buildingQueue[itemIndex];
      if (!item.render)
        continue;
      if (shouldStopBuildingWork()) {
        return abortStoppedBuildingWork(
            countRenderTimeOverflowFrom(itemIndex));
      }
      bool courtyardUnderlayReady = false;
      bool courtyardUnderlayUnavailable = false;
      const bool surfacesRendered = map_building_renderer::renderSurfaces(
          *item.building, item.block->offset.x, item.block->offset.y,
          item.block->mercatorScale, projection, item.extrude,
          [&](map_building_renderer::Surface surface,
              const auto &points) -> bool {
            buildingSurfacePoints.clear();
            for (size_t pointIndex = 0; pointIndex < points.size();
                 ++pointIndex) {
              if ((pointIndex & 0x1FU) == 0 && shouldStopBuildingWork())
                return false;
              const auto &point = points[pointIndex];
              buildingSurfacePoints.push_back(Point16(point.x, point.y));
            }

            if (surface ==
                map_building_renderer::Surface::CourtyardCapture) {
              if (buildingSurfacePoints.size() < 3 ||
                  courtyardUnderlayUnavailable) {
                return true;
              }
              try {
                if (courtyardScanlineNodes.size() <
                    buildingSurfacePoints.size()) {
                  courtyardScanlineNodes.resize(buildingSurfacePoints.size());
                }
              } catch (const std::bad_alloc &) {
                courtyardUnderlayUnavailable = true;
                return true;
              }
              if (courtyardUnderlayReady)
                return true;
              lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
              if (drawBuffer == nullptr) {
                courtyardUnderlayUnavailable = true;
                return true;
              }
              const size_t stridePixels = drawBuffer->header.stride / 2U;
              const size_t pixelCount =
                  stridePixels * drawBuffer->header.h;
              try {
                courtyardUnderlay.resize(pixelCount);
              } catch (const std::bad_alloc &) {
                courtyardUnderlayUnavailable = true;
                return true;
              }
              std::memcpy(courtyardUnderlay.data(), drawBuffer->data,
                          pixelCount * sizeof(uint16_t));
              if (shouldStopBuildingWork())
                return false;
              courtyardUnderlayReady = true;
              return true;
            }
            if (courtyardUnderlayUnavailable &&
                (surface == map_building_renderer::Surface::Roof ||
                 surface == map_building_renderer::Surface::Courtyard)) {
              // Preserve the real underlay instead of painting a false solid
              // roof if the bounded snapshot cannot be allocated.
              return true;
            }
            if (surface == map_building_renderer::Surface::Courtyard) {
              if (!courtyardUnderlayReady ||
                  buildingSurfacePoints.size() < 3) {
                return true;
              }
              lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
              if (drawBuffer == nullptr)
                return false;
              return map_building_renderer::restoreCourtyardUnderlay(
                  buildingSurfacePoints,
                  reinterpret_cast<uint16_t *>(drawBuffer->data),
                  drawBuffer->header.w, drawBuffer->header.h,
                  drawBuffer->header.stride / 2U,
                  courtyardUnderlay.data(), courtyardUnderlay.size(),
                  courtyardScanlineNodes,
                  shouldStopBuildingWork);
            }

            uint16_t color = roofColor;
            switch (surface) {
            case map_building_renderer::Surface::WallLight:
              color = wallLight;
              break;
            case map_building_renderer::Surface::WallMiddle:
              color = wallMiddle;
              break;
            case map_building_renderer::Surface::WallDark:
              color = wallDark;
              break;
            case map_building_renderer::Surface::CourtyardCapture:
            case map_building_renderer::Surface::Courtyard:
              break;
            case map_building_renderer::Surface::Roof:
              break;
            }
            return fillScreenPolygon(buildingSurfacePoints, color);
          },
          &buildingSurfaceStats, shouldStopBuildingWork);
      if (!surfacesRendered) {
        shouldStopBuildingWork();
        if (buildingDeadlineExceeded) {
          return abortStoppedBuildingWork(
              countRenderTimeOverflowFrom(itemIndex));
        }
        return false;
      }
      ++renderedBuildings;
      if (item.extrude)
        ++extrudedBuildings;
    }
    const uint64_t generatedWallFaces =
        buildingSurfaceStats.generatedWallFaces;
    const uint64_t suppressedWallFaces =
        visibleWallCandidateCount > generatedWallFaces
            ? visibleWallCandidateCount - generatedWallFaces
            : 0;

    buildingDrawMs = millis() - buildingPhaseStartMs;
    buildingPassPhase = BuildingPassPhase::Complete;
    MAPIO_LOG("MAPIO: buildings parsedRecords=%u parsedRings=%u "
              "parsedPoints=%u heightExplicit=%u heightLevels=%u "
              "heightInherited=%u heightLocalMedian=%u heightClassDefault=%u "
              "suppressed=%u visibleRecords=%u visiblePoints=%llu "
              "queuedRecords=%u rendered=%u extruded=%u flatOverflow=%u "
              "renderRecordOverflow=%u renderPointOverflow=%u "
              "renderOversizedOverflow=%u renderTimeOverflow=%u "
              "extrusionRecordOverflow=%u extrusionPointOverflow=%u "
              "wallCandidates=%llu generatedWallFaces=%llu "
              "suppressedWallFaces=%llu "
              "projectionMs=%lu sortMs=%lu buildingDrawMs=%lu "
              "deadlineExceeded=%u prepassDeadlineExceeded=%u "
              "psramUsed=%u psramFree=%u psramLargest=%u "
              "budgetFallback=%u renderRecordOverflowTotal=%llu "
              "renderPointOverflowTotal=%llu "
              "renderOversizedOverflowTotal=%llu renderTimeOverflowTotal=%llu "
              "extrusionRecordOverflowTotal=%llu "
              "extrusionPointOverflowTotal=%llu decodedBytes=%u\n",
              (unsigned)loadedBuildingStats.records,
              (unsigned)loadedBuildingStats.rings,
              (unsigned)loadedBuildingStats.points,
              (unsigned)loadedBuildingStats.provenance[0],
              (unsigned)loadedBuildingStats.provenance[1],
              (unsigned)loadedBuildingStats.provenance[2],
              (unsigned)loadedBuildingStats.provenance[3],
              (unsigned)loadedBuildingStats.provenance[4],
              buildingsSuppressed ? 1U : 0U, (unsigned)visibleBuildingCount,
              (unsigned long long)buildingPointCount,
              (unsigned)buildingQueue.size(),
              (unsigned)renderedBuildings,
              (unsigned)extrudedBuildings,
              (unsigned)buildingSelection.flatOverflow(),
              (unsigned)renderRecordLimitOverflow,
              (unsigned)renderSelection.pointLimitOverflow,
              (unsigned)oversizedBuildingCount,
              (unsigned)renderTimeOverflow,
              (unsigned)buildingSelection.recordLimitOverflow,
              (unsigned)buildingSelection.pointLimitOverflow,
              (unsigned long long)visibleWallCandidateCount,
              (unsigned long long)generatedWallFaces,
              (unsigned long long)suppressedWallFaces,
              (unsigned long)buildingProjectionMs,
              (unsigned long)buildingSortMs,
              (unsigned long)buildingDrawMs,
              buildingDeadlineExceeded ? 1U : 0U,
              buildingPrepassDeadlineExceeded ? 1U : 0U,
              (unsigned)(ESP.getPsramSize() -
                         heap_caps_get_free_size(MALLOC_CAP_SPIRAM)),
              (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
              (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM),
              buildingBudgetFallback ? 1U : 0U,
              (unsigned long long)renderRecordOverflowTotal,
              (unsigned long long)renderPointOverflowTotal,
              (unsigned long long)renderOversizedOverflowTotal,
              (unsigned long long)renderTimeOverflowTotal,
              (unsigned long long)extrusionRecordOverflowTotal,
              (unsigned long long)extrusionPointOverflowTotal,
              (unsigned)std::accumulate(
                  memCache.blocks.begin(), memCache.blocks.end(), size_t{0},
                  [](size_t total, const MapBlock *block) {
                    return total + block->buildingData.decodedBytes();
                  }));

              return true;
            },
            [&]() {
              finishBuildingPhaseTiming();
              buildingAllocationFailed = true;
              // The large render workspaces live outside the guarded callable,
              // so this catch samples them before the fallback releases them.
              captureBuildingFailureMemory();
            });
    if (!buildingPassCompleted) {
      const char *failureReason = buildingAllocationFailed
                                      ? "allocation"
                                      : (buildingDeadlineAborted ? "deadline"
                                                                 : "interrupt");
      if (buildingAllocationFailed || buildingDeadlineAborted) {
        MAPIO_LOG(
            "MAPIO: buildings aborted reason=%s fallback=buildings-hidden "
            "parsedRecords=%u parsedRings=%u parsedPoints=%u "
            "heightExplicit=%u heightLevels=%u heightInherited=%u "
            "heightLocalMedian=%u heightClassDefault=%u "
            "visibleRecords=%u visiblePoints=%llu rendered=%u extruded=%u "
            "renderTimeOverflow=%u renderTimeOverflowTotal=%llu "
            "projectionMs=%lu sortMs=%lu buildingDrawMs=%lu "
            "prepassDeadlineExceeded=%u psramUsed=%u psramFree=%u "
            "psramLargest=%u psramSamplePostCleanup=%u\n",
            failureReason, (unsigned)loadedBuildingStats.records,
            (unsigned)loadedBuildingStats.rings,
            (unsigned)loadedBuildingStats.points,
            (unsigned)loadedBuildingStats.provenance[0],
            (unsigned)loadedBuildingStats.provenance[1],
            (unsigned)loadedBuildingStats.provenance[2],
            (unsigned)loadedBuildingStats.provenance[3],
            (unsigned)loadedBuildingStats.provenance[4],
            (unsigned)visibleBuildingCount,
            (unsigned long long)buildingPointCount,
            (unsigned)renderedBuildings, (unsigned)extrudedBuildings,
            (unsigned)renderTimeOverflow,
            (unsigned long long)renderTimeOverflowTotal,
            (unsigned long)buildingProjectionMs,
            (unsigned long)buildingSortMs, (unsigned long)buildingDrawMs,
            buildingPrepassDeadlineExceeded ? 1U : 0U,
            (unsigned)buildingFailurePsramUsed,
            (unsigned)buildingFailurePsramFree,
            (unsigned)buildingFailurePsramLargest,
            buildingFailurePsramSamplePostCleanup ? 1U : 0U);
        buildingFailureRetryCooldown.recordFailure(
            millis(), buildingContextSignature, buildingRenderRegion);
        releaseBuildingFailureWorkspace();
        const bool screenCycleInterrupted =
            shouldInterruptMapRenderForScreenCycle();
        if (map_building_renderer::shouldRetryWithoutBuildings(
                buildingsSuppressed, buildingAllocationFailed,
                buildingDeadlineAborted, screenCycleInterrupted)) {
          return Maps::readVectorMap(viewPort, memCache, canvas, zoom, rotation,
                                     projection, drawLabels, true);
        }
      }
      return false;
    }

    // Failure diagnostics need the live allocations, but labels do not. Drop
    // the building workspace at the phase boundary so dense geometry and the
    // label candidate/layout reserves never overlap on a successful frame.
    releaseBuildingFailureWorkspace();
    if (drawLabels &&
        !drawStreetLabels(viewPort, memCache, canvas, zoom, rotation, style))
      return false;
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

    ESP_LOGI(TAG, "Updated rendered map bounds");

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
    MAPIO_LOG("MAPIO: canvas-draw ok=1 mode=%s clipped=%lu rejected=%lu "
              "blocks=%u fillMs=%lu totalMs=%lu\n",
              projection.isBirdsEye() ? "birds-eye" : "flat",
              (unsigned long)projectionClippedCount,
              (unsigned long)projectionRejectedCount,
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
  return true;
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
  rasterOriginX = pcenter.x;
  rasterOriginY = pcenter.y;
  rasterCellOffsetX = 0;
  rasterCellOffsetY = 0;
  const double zoomScale = map_transform::screenToWorldScale(zoom);
  bbox.min.x = pcenter.x - Maps::tileWidth * zoomScale / 2;
  bbox.min.y = pcenter.y - Maps::tileHeight * zoomScale / 2;
  bbox.max.x = pcenter.x + Maps::tileWidth * zoomScale / 2;
  bbox.max.y = pcenter.y + Maps::tileHeight * zoomScale / 2;
}

void Maps::ViewPort::setCenterForCanvas(Point32 pcenter,
                                        uint16_t canvasWidth,
                                        uint16_t canvasHeight,
                                        double rotation) {
  setCenterForCanvas(static_cast<double>(pcenter.x),
                     static_cast<double>(pcenter.y), canvasWidth,
                     canvasHeight, rotation);
}

void Maps::ViewPort::setCenterForCanvas(double centerX, double centerY,
                                        uint16_t canvasWidth,
                                        uint16_t canvasHeight,
                                        double rotation) {
  rasterOriginX = centerX;
  rasterOriginY = centerY;
  rasterCellOffsetX = 0;
  rasterCellOffsetY = 0;
  center = Point32(static_cast<int32_t>(std::round(centerX)),
                   static_cast<int32_t>(std::round(centerY)));
  const auto bounds = map_transform::canvasWorldBounds(
      {centerX, centerY}, canvasWidth, canvasHeight, zoom, rotation);
  bbox.min = Point32(static_cast<int32_t>(std::floor(bounds.min.x)),
                     static_cast<int32_t>(std::floor(bounds.min.y)));
  bbox.max = Point32(static_cast<int32_t>(std::ceil(bounds.max.x)),
                     static_cast<int32_t>(std::ceil(bounds.max.y)));
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

  Maps::oldMapTile = {};           // Old Map tile coordinates and zoom
  Maps::currentMapTile = {};       // Current Map tile coordinates and zoom
  Maps::roundMapTile = {};         // Boundaries Map tiles
  Maps::navArrowPosition = {0, 0}; // Map Arrow position

  Maps::totalBounds = {90.0, -90.0, 180.0, -180.0};
  buildingFailureRetryCooldown.clear();
}

bool Maps::setVectorMapFolder(const std::string &folder) {
  power_management::ScopedLock powerLock(power_management::LockDomain::Storage);
  String normalized(folder.c_str());
  if (!normalized.endsWith("/"))
    normalized += "/";
  if (normalized == vectorMapFolder)
    return true;

  struct stat storage = {};
  if (::stat(normalized.c_str(), &storage) != 0 || !S_ISDIR(storage.st_mode)) {
    ESP_LOGE(TAG, "Vector map root is unavailable: %s", normalized.c_str());
    return false;
  }

  map_font_asset::Asset candidateFont;
  const std::string fontPath =
      std::string(normalized.c_str()) + "assets/street-labels.fma";
  struct stat fontMetadata = {};
  if (::stat(fontPath.c_str(), &fontMetadata) == 0) {
    if (!S_ISREG(fontMetadata.st_mode) || !candidateFont.open(fontPath)) {
      ESP_LOGE(TAG, "Street-label font asset is invalid: %s", fontPath.c_str());
      return false;
    }
  }

  for (MapBlock *block : memCache.blocks)
    delete block;
  memCache.blocks.clear();
  labelFontAsset = std::move(candidateFont);
  labelLayoutCache.clear();
  streetLabelRuntimeFailurePending = false;
  streetLabelRuntimeFailureCode.clear();
  buildingFailureRetryCooldown.clear();
  vectorMapFolder = normalized;
  invalidateRollingRasterWindow();
  isMapFound = false;
  isPosMoved = true;
  redrawMap = true;
  oldMapTile = {};
  currentMapTile = {};
  ESP_LOGI(TAG, "Vector map root switched to %s", vectorMapFolder.c_str());
  return true;
}

bool Maps::takeStreetLabelRuntimeFailure(std::string &code) {
  if (!streetLabelRuntimeFailurePending)
    return false;
  code = streetLabelRuntimeFailureCode;
  streetLabelRuntimeFailurePending = false;
  return true;
}

bool Maps::probeVectorMapFolder(const std::string &folder) {
  power_management::ScopedLock powerLock(power_management::LockDomain::Storage);
  std::string normalized = folder;
  while (normalized.size() > 1 && normalized.back() == '/')
    normalized.pop_back();
  struct stat storage = {};
  if (::stat(normalized.c_str(), &storage) != 0 || !S_ISDIR(storage.st_mode))
    return false;

  size_t visited = 0;
  std::string blockBase;
  if (!findMapBlock(normalized, blockBase, visited, 0)) {
    ESP_LOGE(TAG, "No map block found under %s", normalized.c_str());
    return false;
  }
  const bool previousMapFound = isMapFound;
  isMapFound = false;
  MapBlock *block = readMapBlock(String(blockBase.c_str()));
  bool loaded = isMapFound;
  if (loaded && block->formatVersion >= 3) {
    map_font_asset::Asset candidateFont;
    const std::string fontPath = normalized + "/assets/street-labels.fma";
    loaded = candidateFont.open(fontPath) &&
             candidateFont.profileFingerprint() ==
                 block->labelData.profileFingerprint &&
             block->labelData.referencesResolve(candidateFont.glyphCount(),
                                                 candidateFont.languageCount());
    if (!loaded)
      ESP_LOGE(TAG, "Street-label block/font contract failed under %s",
               normalized.c_str());
  }
  delete block;
  isMapFound = previousMapFound;
  ESP_LOGI(TAG, "Vector map probe root=%s block=%s loaded=%d",
           normalized.c_str(), blockBase.c_str(), loaded);
  return loaded;
}

/**
 * @brief Delete map screen and release PSRAM
 *
 */
void Maps::deleteMapScrSprites() {
  cancelDragPreview();
  cancelPinchPreview();
  positionPresenter.reset();
  headingPresenter.reset();
  latestPresentedWorld = {};
  hasLatestPresentedWorld = false;
  pinchZoomOutBackdrop = {};
  invalidateRollingRasterWindow();
  hasVisibleProjection = false;
  // Maps::arrowSprite.deleteSprite();
  // Maps::mapSprite.deleteSprite();
  if (Maps::canvasArrow)
    lv_obj_delete(Maps::canvasArrow);
  if (Maps::canvasMap)
    lv_obj_delete(Maps::canvasMap);
  if (Maps::canvasMapTemp)
    lv_obj_delete(Maps::canvasMapTemp);
  if (Maps::canvasForeground)
    lv_obj_delete(Maps::canvasForeground);

  Maps::canvasArrow = nullptr;
  Maps::canvasMap = nullptr;
  Maps::canvasMapTemp = nullptr;
  Maps::canvasForeground = nullptr;
  rollingForegroundReady = false;
}

/**
 * @brief Create map screen
 *
 */
void Maps::createMapScrSprites() {
  ESP_LOGI(TAG, "createMapScrSprites start");
  hasVisibleProjection = false;
  // Map Sprite
  // Map Sprite (Canvas)
  uint16_t w = Maps::mapScrWidth;
  uint16_t h = Maps::mapScrHeight;
  if (mapSet.mapFullScreen)
    h = Maps::mapScrFull;

  // Zoom 5 uses a 5x5 grid of 192 px cells. Zooms 1...4 use a 7x7 grid of
  // 128 px cells. The scratch buffer must hold one complete incoming
  // row/column for either layout so recycling remains atomic.
  const auto wideLayout = map_raster_window::layoutForZoom(
      map_transform::kMaximumRuntimeZoom,
      map_transform::kMaximumRuntimeZoom);
  const auto compactLayout = map_raster_window::layoutForZoom(
      map_transform::kMinimumRuntimeZoom,
      map_transform::kMaximumRuntimeZoom);
  const auto maximumGrid = map_raster_window::gridExtent(wideLayout);
  const auto compactGrid = map_raster_window::gridExtent(compactLayout);
  const uint32_t gridStride = lv_draw_buf_width_to_stride(
      maximumGrid.width, LV_COLOR_FORMAT_RGB565);
  const size_t rollingScreenSize = gridStride * maximumGrid.height;
  const uint32_t wideTileStride = lv_draw_buf_width_to_stride(
      wideLayout.cellExtent, LV_COLOR_FORMAT_RGB565);
  const size_t wideTileSize = wideTileStride * wideLayout.cellExtent;
  const uint32_t compactTileStride = lv_draw_buf_width_to_stride(
      compactLayout.cellExtent, LV_COLOR_FORMAT_RGB565);
  const size_t compactTileSize =
      compactTileStride * compactLayout.cellExtent;
  const size_t maximumTileSize = std::max(wideTileSize, compactTileSize);
  const size_t maximumScratchRowSize =
      std::max(wideTileSize * wideLayout.span,
               compactTileSize * compactLayout.span);
  const uint32_t normalStride = lv_draw_buf_width_to_stride(
      Maps::mapScrWidth, LV_COLOR_FORMAT_RGB565);
  const size_t maximumNormalFrameSize = normalStride * Maps::mapScrFull;
  const size_t requiredTempSize = std::max(
      maximumNormalFrameSize + maximumTileSize,
      maximumScratchRowSize);

  ESP_LOGI(TAG,
           "MapBuff: rollingWide=%ux%u rollingCompact=%ux%u "
           "rollingScreen=%u initialScreen=%u scratch=%u initial=%ux%u",
           (unsigned)maximumGrid.width, (unsigned)maximumGrid.height,
           (unsigned)compactGrid.width, (unsigned)compactGrid.height,
           (unsigned)rollingScreenSize, (unsigned)maximumNormalFrameSize,
           (unsigned)requiredTempSize, (unsigned)w, (unsigned)h);
  // Keep the front buffer viewport-sized until standalone Map first reaches
  // a runtime zoom. Map + Navigation therefore does not pay the rolling
  // grid's PSRAM cost merely by creating the shared map canvases.
  if (!ensureMapScreenBuffer(maximumNormalFrameSize) ||
      !ensureMapTempBuffer(requiredTempSize) ||
      !ensureMapForegroundBuffer(Maps::mapScrWidth, Maps::mapScrFull)) {
    return;
  }
  memset(bufMapScreen, 0, maximumNormalFrameSize);
  memset(bufMapTemp, 0, requiredTempSize);
  memset(bufMapForeground, 0,
         rgb565A8BufferSize(Maps::mapScrWidth, Maps::mapScrFull));
  invalidateRollingRasterWindow();

  Maps::canvasMap = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_canvas_set_buffer(Maps::canvasMap, bufMapScreen, w, h,
                       LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);

  // Vector rendering is synchronous. Draw into a hidden back buffer so an
  // input-triggered abort can never expose a half-rendered frame.
  Maps::canvasMapTemp = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, w, h,
                       LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMapTemp);

  // Standalone Map uses a rolling base raster. Street labels and the route are
  // composed once in viewport coordinates on this transparent foreground so
  // labels are neither clipped nor collision-tested independently per cell.
  Maps::canvasForeground = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
  bindMapForegroundCanvas(Maps::canvasForeground, w, h);
  lv_obj_center(Maps::canvasForeground);

  // Draw the current-position marker as native LVGL geometry at its final
  // on-screen size. This avoids magnifying a fixed 48x48 bitmap.
  Maps::canvasArrow = lv_obj_create(mapTile);
  lv_obj_remove_style_all(Maps::canvasArrow);
  lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_event_cb(Maps::canvasArrow, drawCurrentPositionMarker,
                      LV_EVENT_DRAW_MAIN, nullptr);
  updateCurrentPositionMarker(Maps::canvasArrow, true);
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

bool Maps::shouldUseRollingRasterWindow(uint8_t requestedZoom) const {
  return mapSet.vectorMap && isMapScreenActive() &&
         requestedZoom >= map_transform::kMinimumRuntimeZoom &&
         requestedZoom <= map_transform::kMaximumRuntimeZoom;
}

uint64_t Maps::rollingRasterSignature() const {
  const ScreenMapRenderSettings &style = currentMapStyleSettings();
  uint64_t signature = 1469598103934665603ULL;
  auto mix = [&signature](uint64_t value) {
    signature ^= value;
    signature *= 1099511628211ULL;
  };
  mix(style.minPolygonSize);
  mix(style.detailLevel);
  mix(style.streetLineWidth);
  mix(style.zoomLevel);
  mix(style.visibilityMask);
  mix(static_cast<uint8_t>(rotationMode));
  return signature;
}

bool Maps::rollingRasterCompatible(uint8_t requestedZoom,
                                   uint16_t viewportWidth,
                                   uint16_t viewportHeight,
                                   uint64_t signature) const {
  const auto layout = map_raster_window::layoutForZoom(
      requestedZoom, map_transform::kMaximumRuntimeZoom);
  return rollingRasterWindow.valid &&
         rollingRasterWindow.zoom == requestedZoom &&
         rollingRasterWindow.gridRadius == layout.radius &&
         rollingRasterWindow.gridSpan == layout.span &&
         rollingRasterWindow.tileWidth == layout.cellExtent &&
         rollingRasterWindow.tileHeight == layout.cellExtent &&
         rollingRasterWindow.viewportWidth == viewportWidth &&
         rollingRasterWindow.viewportHeight == viewportHeight &&
         rollingRasterWindow.signature == signature &&
         map_raster_window::rotationIsCompatible(
             rollingRasterWindow.rotation, Maps::rotationRad);
}

void Maps::hideRollingForeground() {
  if (Maps::canvasForeground != nullptr)
    lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
}

void Maps::restoreRollingForeground() {
  if (rollingForegroundReady && Maps::canvasForeground != nullptr)
    lv_obj_clear_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
}

void Maps::invalidateRollingRasterWindow() {
  rollingRasterWindow = {};
  rollingForegroundReady = false;
  hideRollingForeground();
}

double Maps::visibleMapRotation() const {
  // Course-up headings can move within the five-degree raster reuse window.
  // Coordinate interactions must use the rotation of the pixels currently on
  // screen until a replacement raster has been completed.
  if (rollingRasterWindow.valid && isMapScreenActive())
    return rollingRasterWindow.rotation;
  return Maps::rotationRad;
}

bool Maps::renderRollingRasterCell(double rasterOriginX,
                                   double rasterOriginY,
                                   int32_t cellOffsetX,
                                   int32_t cellOffsetY,
                                   uint8_t requestedZoom, double rotation,
                                   uint8_t scratchIndex,
                                   size_t scratchBaseOffset,
                                   bool preserveVisibleState,
                                   bool *mapFoundOut) {
  if (Maps::canvasMapTemp == nullptr || bufMapTemp == nullptr ||
      scratchIndex >= map_raster_window::kScratchTileCount ||
      scratchIndex >= rollingRasterWindow.gridSpan ||
      rollingRasterWindow.tileWidth == 0 ||
      rollingRasterWindow.tileHeight == 0) {
    return false;
  }

  const uint16_t tileWidth = rollingRasterWindow.tileWidth;
  const uint16_t tileHeight = rollingRasterWindow.tileHeight;
  const uint32_t tileStride =
      lv_draw_buf_width_to_stride(tileWidth, LV_COLOR_FORMAT_RGB565);
  const size_t tileSize = tileStride * tileHeight;
  const size_t scratchOffset =
      scratchBaseOffset + (tileSize * scratchIndex);
  if (scratchOffset + tileSize > bufMapTempSize) {
    ESP_LOGE(TAG, "Rolling raster scratch overflow index=%u need=%u have=%u",
             (unsigned)scratchIndex, (unsigned)(scratchOffset + tileSize),
             (unsigned)bufMapTempSize);
    return false;
  }

  const bool previousMapFound = Maps::isMapFound;
  const tileBounds previousBounds = Maps::totalBounds;
  const uint16_t previousWptX = Maps::wptPosX;
  const uint16_t previousWptY = Maps::wptPosY;
  const ViewPort previousViewPort = Maps::viewPort;
  auto restoreVisibleState = [&]() {
    if (!preserveVisibleState)
      return;
    Maps::isMapFound = previousMapFound;
    Maps::totalBounds = previousBounds;
    Maps::wptPosX = previousWptX;
    Maps::wptPosY = previousWptY;
    Maps::viewPort = previousViewPort;
  };

  void *scratch = static_cast<uint8_t *>(bufMapTemp) + scratchOffset;
  lv_canvas_set_buffer(Maps::canvasMapTemp, scratch, tileWidth, tileHeight,
                       LV_COLOR_FORMAT_RGB565);

  ViewPort cellViewPort;
  cellViewPort.zoom = requestedZoom;
  const auto worldDelta = map_transform::screenToWorld(
      {static_cast<double>(cellOffsetX), static_cast<double>(cellOffsetY)},
      requestedZoom, rotation);
  const double centerX = rasterOriginX + worldDelta.x;
  const double centerY = rasterOriginY + worldDelta.y;
  cellViewPort.setCenterForCanvas(centerX, centerY, tileWidth, tileHeight,
                                  rotation);
  cellViewPort.rasterOriginX = rasterOriginX;
  cellViewPort.rasterOriginY = rasterOriginY;
  cellViewPort.rasterCellOffsetX = cellOffsetX;
  cellViewPort.rasterCellOffsetY = cellOffsetY;
  const auto cellProjection = makeMapProjection(
      cellViewPort.rasterOriginX, cellViewPort.rasterOriginY,
      cellViewPort.rasterCellOffsetX, cellViewPort.rasterCellOffsetY,
      requestedZoom, rotation, tileWidth, tileHeight,
      map_projection::Mode::Flat);
  if (!Maps::getMapBlocks(cellViewPort.bbox, Maps::memCache) ||
      !Maps::readVectorMap(cellViewPort, Maps::memCache,
                           Maps::canvasMapTemp, requestedZoom, rotation,
                           cellProjection, false)) {
    restoreVisibleState();
    return false;
  }

  if (shouldInterruptMapRenderForScreenCycle()) {
    restoreVisibleState();
    return false;
  }

  if (mapFoundOut != nullptr)
    *mapFoundOut = Maps::isMapFound;
  restoreVisibleState();
  return true;
}

bool Maps::preserveVisibleFrameForRollingBuild(uint16_t viewportWidth,
                                               uint16_t viewportHeight,
                                               size_t &scratchBaseOffset) {
  scratchBaseOffset = 0;
  if (Maps::canvasMap == nullptr || bufMapTemp == nullptr)
    return false;

  lv_obj_update_layout(Maps::canvasMap);
  lv_obj_update_layout(mapTile);
  const lv_draw_buf_t *source = lv_canvas_get_draw_buf(Maps::canvasMap);
  if (source == nullptr || source->data == nullptr ||
      source->header.cf != LV_COLOR_FORMAT_RGB565) {
    ESP_LOGE(TAG, "Rolling raster could not snapshot the visible map frame");
    return false;
  }

  const uint32_t snapshotStride = lv_draw_buf_width_to_stride(
      viewportWidth, LV_COLOR_FORMAT_RGB565);
  const size_t snapshotSize = snapshotStride * viewportHeight;
  const uint32_t tileStride = lv_draw_buf_width_to_stride(
      rollingRasterWindow.tileWidth, LV_COLOR_FORMAT_RGB565);
  const size_t tileSize = tileStride * rollingRasterWindow.tileHeight;
  if (snapshotSize + tileSize > bufMapTempSize) {
    ESP_LOGE(TAG,
             "Rolling raster snapshot needs %u bytes plus tile=%u, "
             "scratch=%u",
             (unsigned)snapshotSize, (unsigned)tileSize,
             (unsigned)bufMapTempSize);
    return false;
  }

  lv_area_t canvasArea;
  lv_area_t containerArea;
  lv_obj_get_coords(Maps::canvasMap, &canvasArea);
  lv_obj_get_coords(mapTile, &containerArea);
  const int32_t viewportScreenX =
      containerArea.x1 + gui_layout::centeredViewportOrigin(
                             lv_obj_get_width(mapTile), viewportWidth);
  const int32_t viewportScreenY =
      containerArea.y1 + gui_layout::centeredViewportOrigin(
                             lv_obj_get_height(mapTile), viewportHeight);
  const int32_t sourceOriginX = viewportScreenX - canvasArea.x1;
  const int32_t sourceOriginY = viewportScreenY - canvasArea.y1;
  const int32_t sourceWidth = source->header.w;
  const int32_t sourceHeight = source->header.h;

  auto *snapshot = static_cast<uint8_t *>(bufMapTemp);
  const auto *sourceBytes = static_cast<const uint8_t *>(source->data);
  const bool alreadySnapshot =
      sourceBytes == snapshot && sourceOriginX == 0 && sourceOriginY == 0 &&
      sourceWidth == viewportWidth && sourceHeight == viewportHeight &&
      source->header.stride == snapshotStride;
  if (!alreadySnapshot) {
    memset(snapshot, 0, snapshotSize);
    const int32_t destinationX = std::max<int32_t>(0, -sourceOriginX);
    const int32_t destinationY = std::max<int32_t>(0, -sourceOriginY);
    const int32_t clippedSourceX = std::max<int32_t>(0, sourceOriginX);
    const int32_t clippedSourceY = std::max<int32_t>(0, sourceOriginY);
    const int32_t copyWidth = std::min<int32_t>(
        viewportWidth - destinationX, sourceWidth - clippedSourceX);
    const int32_t copyHeight = std::min<int32_t>(
        viewportHeight - destinationY, sourceHeight - clippedSourceY);
    if (copyWidth > 0 && copyHeight > 0) {
      const size_t copyBytes =
          static_cast<size_t>(copyWidth) * sizeof(uint16_t);
      for (int32_t y = 0; y < copyHeight; ++y) {
        memcpy(snapshot +
                   (static_cast<size_t>(destinationY + y) * snapshotStride) +
                   (static_cast<size_t>(destinationX) * sizeof(uint16_t)),
               sourceBytes +
                   (static_cast<size_t>(clippedSourceY + y) *
                    source->header.stride) +
                   (static_cast<size_t>(clippedSourceX) * sizeof(uint16_t)),
               copyBytes);
      }
    }
  }

  // Keep this complete viewport-sized snapshot on screen while bufMapScreen
  // is rebuilt cell by cell. A touch can interrupt that work without exposing
  // a partially populated rolling grid.
  lv_anim_delete(Maps::canvasMap, setPinchCanvasScale);
  lv_image_set_scale(Maps::canvasMap, LV_SCALE_NONE);
  lv_image_set_pivot(Maps::canvasMap, 0, 0);
  lv_canvas_set_buffer(Maps::canvasMap, snapshot, viewportWidth,
                       viewportHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);
  lv_obj_invalidate(Maps::canvasMap);
  scratchBaseOffset = snapshotSize;
  return true;
}

void Maps::restoreVisibleFrameAfterRollingBuildFailure(
    uint16_t viewportWidth, uint16_t viewportHeight) {
  if (Maps::canvasMap == nullptr || Maps::canvasMapTemp == nullptr ||
      bufMapScreen == nullptr || bufMapTemp == nullptr)
    return;
  const uint32_t stride = lv_draw_buf_width_to_stride(
      viewportWidth, LV_COLOR_FORMAT_RGB565);
  const size_t frameSize = stride * viewportHeight;
  if (frameSize > bufMapScreenSize || frameSize > bufMapTempSize)
    return;

  memcpy(bufMapScreen, bufMapTemp, frameSize);
  lv_canvas_set_buffer(Maps::canvasMap, bufMapScreen, viewportWidth,
                       viewportHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, viewportWidth,
                       viewportHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMapTemp);
  lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  lv_obj_invalidate(Maps::canvasMap);
}

void Maps::copyScratchCellToGrid(uint8_t scratchIndex, uint8_t column,
                                 uint8_t row, size_t scratchBaseOffset) {
  const uint16_t tileWidth = rollingRasterWindow.tileWidth;
  const uint16_t tileHeight = rollingRasterWindow.tileHeight;
  const auto grid = map_raster_window::gridExtent(
      tileWidth, tileHeight, rollingRasterWindow.gridSpan);
  const uint32_t gridStride =
      lv_draw_buf_width_to_stride(grid.width, LV_COLOR_FORMAT_RGB565);
  const uint32_t tileStride =
      lv_draw_buf_width_to_stride(tileWidth, LV_COLOR_FORMAT_RGB565);
  const size_t tileSize = tileStride * tileHeight;
  const size_t rowBytes = static_cast<size_t>(tileWidth) * sizeof(uint16_t);
  auto *gridBytes = static_cast<uint8_t *>(bufMapScreen);
  const auto *scratch = static_cast<const uint8_t *>(bufMapTemp) +
                        scratchBaseOffset + (tileSize * scratchIndex);
  for (uint16_t y = 0; y < tileHeight; ++y) {
    uint8_t *destination =
        gridBytes + (static_cast<size_t>(row * tileHeight + y) * gridStride) +
        (static_cast<size_t>(column) * rowBytes);
    memcpy(destination, scratch + (static_cast<size_t>(y) * tileStride),
           rowBytes);
  }
}

void Maps::bindRollingRasterCanvas() {
  if (Maps::canvasMap == nullptr)
    return;
  const auto grid = map_raster_window::gridExtent(
      rollingRasterWindow.tileWidth, rollingRasterWindow.tileHeight,
      rollingRasterWindow.gridSpan);
  lv_canvas_set_buffer(Maps::canvasMap, bufMapScreen, grid.width, grid.height,
                       LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);
  lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
}

void Maps::updateVisibleVectorViewport() {
  if (!rollingRasterWindow.valid)
    return;
  Maps::viewPort.zoom = rollingRasterWindow.zoom;
  Maps::viewPort.setCenterForCanvas(
      Maps::point, rollingRasterWindow.viewportWidth,
      rollingRasterWindow.viewportHeight, rollingRasterWindow.rotation);
  Maps::totalBounds.lat_min = Maps::mercatorY2lat(Maps::viewPort.bbox.min.y);
  Maps::totalBounds.lat_max = Maps::mercatorY2lat(Maps::viewPort.bbox.max.y);
  Maps::totalBounds.lon_min = Maps::mercatorX2lon(Maps::viewPort.bbox.min.x);
  Maps::totalBounds.lon_max = Maps::mercatorX2lon(Maps::viewPort.bbox.max.x);
}

bool Maps::renderRollingForeground() {
  if (!rollingRasterWindow.valid || Maps::canvasForeground == nullptr ||
      bufMapForeground == nullptr) {
    rollingForegroundReady = false;
    hideRollingForeground();
    return false;
  }

  const uint16_t width = rollingRasterWindow.viewportWidth;
  const uint16_t height = rollingRasterWindow.viewportHeight;
  const size_t requiredSize = rgb565A8BufferSize(width, height);
  if (width == 0 || height == 0 ||
      !ensureMapForegroundBuffer(width, height) ||
      requiredSize > bufMapForegroundSize) {
    rollingForegroundReady = false;
    hideRollingForeground();
    return false;
  }

  memset(bufMapForeground, 0, requiredSize);
  lv_anim_delete(Maps::canvasForeground, setPinchCanvasScale);
  lv_image_set_scale(Maps::canvasForeground, LV_SCALE_NONE);
  lv_image_set_pivot(Maps::canvasForeground, 0, 0);
  bindMapForegroundCanvas(Maps::canvasForeground, width, height);
  lv_obj_center(Maps::canvasForeground);

  const ScreenMapRenderSettings &style = currentMapStyleSettings();
  if (style.labelDensity != 0 && labelFontAsset.healthy()) {
    if (!Maps::getMapBlocks(Maps::viewPort.bbox, Maps::memCache) ||
        !drawStreetLabels(Maps::viewPort, Maps::memCache,
                          Maps::canvasForeground, rollingRasterWindow.zoom,
                          rollingRasterWindow.rotation, style)) {
      rollingForegroundReady = false;
      hideRollingForeground();
      return false;
    }
  }

  const auto foregroundProjection = makeMapProjection(
      Maps::viewPort.rasterOriginX, Maps::viewPort.rasterOriginY,
      Maps::viewPort.rasterCellOffsetX, Maps::viewPort.rasterCellOffsetY,
      rollingRasterWindow.zoom, rollingRasterWindow.rotation, width, height,
      map_projection::Mode::Flat);
  if (routeOverlay.hasRoute() && isRouteOverlayVisible(mapRenderSettings)) {
    routeOverlay.drawRoute(Maps::canvasForeground, foregroundProjection);
    lv_draw_buf_t *drawBuffer =
        lv_canvas_get_draw_buf(Maps::canvasForeground);
    if (drawBuffer != nullptr && drawBuffer->data != nullptr &&
        drawBuffer->header.cf == LV_COLOR_FORMAT_RGB565A8) {
      const uint32_t colorStride =
          drawBuffer->header.stride / sizeof(uint16_t);
      auto *colors = reinterpret_cast<uint16_t *>(drawBuffer->data);
      auto *alpha = static_cast<uint8_t *>(drawBuffer->data) +
                    static_cast<size_t>(drawBuffer->header.stride) * height;
      map_label_rasterizer::makeColorOpaque(
          colors, alpha, width, height, colorStride, colorStride,
          navigation_visual_style::ROUTE_BLUE_RGB565);
    }
  }

  rollingForegroundReady = true;
  lv_obj_clear_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
  lv_obj_invalidate(Maps::canvasForeground);
  if (Maps::canvasArrow != nullptr)
    lv_obj_move_foreground(Maps::canvasArrow);
  return true;
}

map_transform::PixelOffset
Maps::rollingRasterCenterOffset(Point32 center) const {
  return map_transform::rasterCellPixel(
      {static_cast<double>(center.x), static_cast<double>(center.y)},
      {rollingRasterWindow.phaseOriginX,
       rollingRasterWindow.phaseOriginY},
      {rollingRasterWindow.originPhaseOffsetX,
       rollingRasterWindow.originPhaseOffsetY},
      rollingRasterWindow.zoom, rollingRasterWindow.rotation);
}

void Maps::positionRollingRasterCanvas(Point32 center) {
  if (!rollingRasterWindow.valid || Maps::canvasMap == nullptr)
    return;
  const auto centerOffset = rollingRasterCenterOffset(center);
  lv_obj_center(Maps::canvasMap);
  lv_obj_set_pos(Maps::canvasMap, -centerOffset.x, -centerOffset.y);
  lv_obj_invalidate(Maps::canvasMap);
}

bool Maps::buildRollingRasterWindow(uint8_t requestedZoom,
                                    uint16_t viewportWidth,
                                    uint16_t viewportHeight,
                                    uint64_t signature) {
  const uint32_t buildStartMs = millis();
  rollingRasterWindow.valid = false;
  rollingRasterWindow.zoom = requestedZoom;
  const auto layout = map_raster_window::layoutForZoom(
      requestedZoom, map_transform::kMaximumRuntimeZoom);
  rollingRasterWindow.gridRadius = layout.radius;
  rollingRasterWindow.gridSpan = layout.span;
  rollingRasterWindow.tileWidth = layout.cellExtent;
  rollingRasterWindow.tileHeight = layout.cellExtent;
  rollingRasterWindow.viewportWidth = viewportWidth;
  rollingRasterWindow.viewportHeight = viewportHeight;
  rollingRasterWindow.rotation = Maps::rotationRad;
  rollingRasterWindow.phaseOriginX = Maps::point.x;
  rollingRasterWindow.phaseOriginY = Maps::point.y;
  rollingRasterWindow.originPhaseOffsetX = 0;
  rollingRasterWindow.originPhaseOffsetY = 0;
  rollingRasterWindow.signature = signature;

  const uint16_t tileWidth = rollingRasterWindow.tileWidth;
  const uint16_t tileHeight = rollingRasterWindow.tileHeight;
  const auto grid = map_raster_window::gridExtent(
      tileWidth, tileHeight, rollingRasterWindow.gridSpan);
  const uint32_t gridStride =
      lv_draw_buf_width_to_stride(grid.width, LV_COLOR_FORMAT_RGB565);
  const size_t gridSize = gridStride * grid.height;
  size_t scratchBaseOffset = 0;
  if (!preserveVisibleFrameForRollingBuild(viewportWidth, viewportHeight,
                                           scratchBaseOffset)) {
    return false;
  }
  // The previous complete frame now lives in scratch, so growing the front
  // allocation can safely release its old viewport-sized storage. Drop the
  // reloadable vector cache first to coalesce PSRAM if this upgrade happens
  // after the device has spent time on other map screens.
  if (bufMapScreenSize < gridSize) {
    for (MapBlock *block : Maps::memCache.blocks)
      delete block;
    Maps::memCache.blocks.clear();
  }
  if (!ensureMapScreenBuffer(gridSize)) {
    restoreVisibleFrameAfterRollingBuildFailure(viewportWidth,
                                                viewportHeight);
    return false;
  }

  bool centerMapFound = false;
  for (uint8_t row = 0; row < rollingRasterWindow.gridSpan; ++row) {
    for (uint8_t column = 0; column < rollingRasterWindow.gridSpan; ++column) {
      const int8_t cellX = static_cast<int8_t>(column) -
                           rollingRasterWindow.gridRadius;
      const int8_t cellY =
          static_cast<int8_t>(row) - rollingRasterWindow.gridRadius;
      const int32_t cellOffsetX = static_cast<int32_t>(cellX) * tileWidth;
      const int32_t cellOffsetY = static_cast<int32_t>(cellY) * tileHeight;
      bool cellMapFound = false;
      if (!renderRollingRasterCell(
              rollingRasterWindow.phaseOriginX,
              rollingRasterWindow.phaseOriginY,
              cellOffsetX, cellOffsetY, requestedZoom, Maps::rotationRad, 0,
              scratchBaseOffset, true,
              &cellMapFound)) {
        ESP_LOGI(TAG, "Rolling raster build interrupted at cell %d,%d", cellX,
                 cellY);
        restoreVisibleFrameAfterRollingBuildFailure(viewportWidth,
                                                    viewportHeight);
        return false;
      }
      if (cellX == 0 && cellY == 0)
        centerMapFound = cellMapFound;
      copyScratchCellToGrid(0, column, row, scratchBaseOffset);
    }
  }

  rollingRasterWindow.valid = true;
  Maps::isMapFound = centerMapFound;
  bindRollingRasterCanvas();
  updateVisibleVectorViewport();
  positionRollingRasterCanvas(Maps::point);
  ESP_LOGI(TAG,
           "Rolling raster ready: zoom=%u cells=%ux%u cell=%ux%u "
           "viewport=%ux%u grid=%ux%u center=(%d,%d) elapsedMs=%lu "
           "freePsram=%u",
           (unsigned)requestedZoom, (unsigned)rollingRasterWindow.gridSpan,
           (unsigned)rollingRasterWindow.gridSpan,
           (unsigned)tileWidth, (unsigned)tileHeight,
           (unsigned)viewportWidth, (unsigned)viewportHeight,
           (unsigned)grid.width, (unsigned)grid.height, Maps::point.x,
           Maps::point.y, (unsigned long)(millis() - buildStartMs),
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
  return true;
}

bool Maps::shiftGridPixelsHorizontal(int8_t direction) {
  const uint16_t tileWidth = rollingRasterWindow.tileWidth;
  const uint16_t tileHeight = rollingRasterWindow.tileHeight;
  const auto grid = map_raster_window::gridExtent(
      tileWidth, tileHeight, rollingRasterWindow.gridSpan);
  const uint32_t gridStride =
      lv_draw_buf_width_to_stride(grid.width, LV_COLOR_FORMAT_RGB565);
  const uint32_t tileStride =
      lv_draw_buf_width_to_stride(tileWidth, LV_COLOR_FORMAT_RGB565);
  if (gridStride != static_cast<uint32_t>(grid.width) * sizeof(uint16_t) ||
      tileStride != static_cast<uint32_t>(tileWidth) * sizeof(uint16_t)) {
    ESP_LOGE(TAG, "Rolling raster requires packed RGB565 buffers");
    return false;
  }
  map_raster_window::shiftPixelsHorizontal(
      static_cast<uint16_t *>(bufMapScreen),
      static_cast<const uint16_t *>(bufMapTemp), tileWidth, tileHeight,
      direction, rollingRasterWindow.gridSpan);
  return true;
}

bool Maps::shiftGridPixelsVertical(int8_t direction) {
  const uint16_t tileWidth = rollingRasterWindow.tileWidth;
  const uint16_t tileHeight = rollingRasterWindow.tileHeight;
  const auto grid = map_raster_window::gridExtent(
      tileWidth, tileHeight, rollingRasterWindow.gridSpan);
  const uint32_t gridStride =
      lv_draw_buf_width_to_stride(grid.width, LV_COLOR_FORMAT_RGB565);
  const uint32_t tileStride =
      lv_draw_buf_width_to_stride(tileWidth, LV_COLOR_FORMAT_RGB565);
  if (gridStride != static_cast<uint32_t>(grid.width) * sizeof(uint16_t) ||
      tileStride != static_cast<uint32_t>(tileWidth) * sizeof(uint16_t)) {
    ESP_LOGE(TAG, "Rolling raster requires packed RGB565 buffers");
    return false;
  }
  map_raster_window::shiftPixelsVertical(
      static_cast<uint16_t *>(bufMapScreen),
      static_cast<const uint16_t *>(bufMapTemp), tileWidth, tileHeight,
      direction, rollingRasterWindow.gridSpan);
  return true;
}

bool Maps::shiftRollingRasterWindow(int8_t directionX, int8_t directionY) {
  if (!rollingRasterWindow.valid ||
      ((directionX == 0) == (directionY == 0))) {
    return false;
  }
  const uint32_t shiftStartMs = millis();

  const int32_t targetOriginPhaseOffsetX =
      rollingRasterWindow.originPhaseOffsetX +
      (static_cast<int32_t>(directionX) * rollingRasterWindow.tileWidth);
  const int32_t targetOriginPhaseOffsetY =
      rollingRasterWindow.originPhaseOffsetY +
      (static_cast<int32_t>(directionY) * rollingRasterWindow.tileHeight);
  const auto targetOriginDelta = map_transform::screenToWorld(
      {static_cast<double>(targetOriginPhaseOffsetX),
       static_cast<double>(targetOriginPhaseOffsetY)},
      rollingRasterWindow.zoom, rollingRasterWindow.rotation);
  const double targetOriginX =
      rollingRasterWindow.phaseOriginX + targetOriginDelta.x;
  const double targetOriginY =
      rollingRasterWindow.phaseOriginY + targetOriginDelta.y;

  for (uint8_t index = 0; index < rollingRasterWindow.gridSpan; ++index) {
    const int8_t crossCell = static_cast<int8_t>(index) -
                             rollingRasterWindow.gridRadius;
    // targetOrigin is already one cell beyond the old origin. The replacement
    // row/column must therefore be the outermost cell around the *new* origin
    // (one cell beyond the old edge), not the old edge itself. Re-rendering
    // that old edge here duplicates map content after the pixel shift.
    const int8_t cellX =
        directionX != 0
            ? map_raster_window::replacementCellOffset(
                  directionX, rollingRasterWindow.gridRadius)
            : crossCell;
    const int8_t cellY =
        directionY != 0
            ? map_raster_window::replacementCellOffset(
                  directionY, rollingRasterWindow.gridRadius)
            : crossCell;
    const int32_t cellPhaseOffsetX =
        targetOriginPhaseOffsetX +
        (static_cast<int32_t>(cellX) * rollingRasterWindow.tileWidth);
    const int32_t cellPhaseOffsetY =
        targetOriginPhaseOffsetY +
        (static_cast<int32_t>(cellY) * rollingRasterWindow.tileHeight);
    if (!renderRollingRasterCell(rollingRasterWindow.phaseOriginX,
                                 rollingRasterWindow.phaseOriginY,
                                 cellPhaseOffsetX, cellPhaseOffsetY,
                                 rollingRasterWindow.zoom,
                                 rollingRasterWindow.rotation, index, 0,
                                 true)) {
      ESP_LOGI(TAG, "Rolling raster shift interrupted direction=%d,%d",
               directionX, directionY);
      return false;
    }
  }

  const bool shifted = directionX != 0
                           ? shiftGridPixelsHorizontal(directionX)
                           : shiftGridPixelsVertical(directionY);
  if (!shifted)
    return false;
  rollingRasterWindow.originPhaseOffsetX = targetOriginPhaseOffsetX;
  rollingRasterWindow.originPhaseOffsetY = targetOriginPhaseOffsetY;
  // Each completed edge is a consistency checkpoint. A following axis may be
  // interrupted by a new touch, so the live canvas must already use this origin.
  updateVisibleVectorViewport();
  positionRollingRasterCanvas(Maps::point);
  ESP_LOGI(TAG,
           "Rolling raster shifted direction=%d,%d elapsedMs=%lu "
           "origin=(%.0f,%.0f)",
           directionX, directionY,
           (unsigned long)(millis() - shiftStartMs), targetOriginX,
           targetOriginY);
  return true;
}

bool Maps::settleRollingRasterWindow() {
  if (!rollingRasterWindow.valid)
    return false;

  auto centerOffset = rollingRasterCenterOffset(Maps::point);
  if (!map_raster_window::centerIsCovered(
          centerOffset.x, centerOffset.y,
          rollingRasterWindow.viewportWidth,
          rollingRasterWindow.viewportHeight,
          rollingRasterWindow.tileWidth, rollingRasterWindow.tileHeight,
          rollingRasterWindow.gridSpan)) {
    return buildRollingRasterWindow(
        rollingRasterWindow.zoom, rollingRasterWindow.viewportWidth,
        rollingRasterWindow.viewportHeight, rollingRasterWindow.signature);
  }

  for (uint8_t step = 0; step < rollingRasterWindow.gridRadius; ++step) {
    const int8_t directionX = map_raster_window::recycleDirection(
        centerOffset.x, rollingRasterWindow.tileWidth);
    if (directionX == 0)
      break;
    if (!shiftRollingRasterWindow(directionX, 0))
      return false;
    centerOffset = rollingRasterCenterOffset(Maps::point);
  }

  centerOffset = rollingRasterCenterOffset(Maps::point);
  for (uint8_t step = 0; step < rollingRasterWindow.gridRadius; ++step) {
    const int8_t directionY = map_raster_window::recycleDirection(
        centerOffset.y, rollingRasterWindow.tileHeight);
    if (directionY == 0)
      break;
    if (!shiftRollingRasterWindow(0, directionY))
      return false;
    centerOffset = rollingRasterCenterOffset(Maps::point);
  }

  bindRollingRasterCanvas();
  updateVisibleVectorViewport();
  positionRollingRasterCanvas(Maps::point);
  return true;
}

bool Maps::hasPinchZoomOutBackdrop(uint8_t baseZoom) const {
  const uint16_t canvasHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  return pinchZoomOutBackdrop.prepared &&
         pinchZoomOutBackdrop.baseZoom ==
             map_transform::clampRuntimeZoom(baseZoom) &&
         pinchZoomOutBackdrop.center.x == Maps::point.x &&
         pinchZoomOutBackdrop.center.y == Maps::point.y &&
         std::fabs(pinchZoomOutBackdrop.rotation - visibleMapRotation()) <
             0.0001 &&
         pinchZoomOutBackdrop.canvasHeight == canvasHeight &&
         Maps::canvasMapTemp != nullptr;
}

void Maps::invalidatePinchZoomOutBackdrop() {
  pinchZoomOutBackdrop = {};
  dragPresentation.hasBackdrop = false;
  if (Maps::canvasMapTemp == nullptr)
    return;
  lv_anim_delete(Maps::canvasMapTemp, setPinchCanvasScale);
  lv_image_set_scale(Maps::canvasMapTemp, LV_SCALE_NONE);
  lv_image_set_pivot(Maps::canvasMapTemp, 0, 0);
  lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  lv_obj_center(Maps::canvasMapTemp);
}

bool Maps::preparePinchZoomOutBackdrop(uint8_t baseZoom) {
  power_management::ScopedLock powerLock(power_management::LockDomain::Map);
  baseZoom = map_transform::clampRuntimeZoom(baseZoom);
  if (baseZoom >= map_transform::kMaximumRuntimeZoom ||
      Maps::canvasMapTemp == nullptr || pinchPresentation.active ||
      pinchPresentation.settlementPending || dragPreviewController.active() ||
      dragPreviewController.settlementPending()) {
    return false;
  }
  if (hasPinchZoomOutBackdrop(baseZoom))
    return true;

  invalidatePinchZoomOutBackdrop();
  const uint16_t canvasHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  const uint32_t backdropStride = lv_draw_buf_width_to_stride(
      Maps::mapScrWidth, LV_COLOR_FORMAT_RGB565);
  const size_t backdropSize = backdropStride * canvasHeight;
  if (backdropSize > bufMapTempSize)
    return false;
  // Rolling edge renders leave the hidden canvas bound to a single scratch
  // cell. Rebind it to a complete viewport before preparing the pinch
  // backdrop used by zoom levels 1...4.
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, Maps::mapScrWidth,
                       canvasHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMapTemp);
  const uint8_t backdropZoom = map_transform::kMaximumRuntimeZoom;
  const double backdropRotation = visibleMapRotation();
  ViewPort backdropViewPort;
  backdropViewPort.zoom = backdropZoom;
  backdropViewPort.setCenter(Maps::point);
  const auto backdropProjection = makeMapProjection(
      backdropViewPort.rasterOriginX, backdropViewPort.rasterOriginY,
      backdropViewPort.rasterCellOffsetX,
      backdropViewPort.rasterCellOffsetY, backdropZoom, backdropRotation,
      Maps::mapScrWidth, canvasHeight, map_projection::Mode::Flat);

  const bool previousMapFound = Maps::isMapFound;
  const tileBounds previousBounds = Maps::totalBounds;
  const uint16_t previousWptX = Maps::wptPosX;
  const uint16_t previousWptY = Maps::wptPosY;
  auto restoreVisibleMapState = [&]() {
    Maps::isMapFound = previousMapFound;
    Maps::totalBounds = previousBounds;
    Maps::wptPosX = previousWptX;
    Maps::wptPosY = previousWptY;
  };

  ESP_LOGI(TAG, "Preparing pinch backdrop: baseZoom=%u renderZoom=%u",
           (unsigned)baseZoom, (unsigned)backdropZoom);
  if (!Maps::getMapBlocks(backdropViewPort.bbox, Maps::memCache) ||
      !Maps::readVectorMap(backdropViewPort, Maps::memCache,
                           Maps::canvasMapTemp, backdropZoom,
                           backdropRotation, backdropProjection)) {
    restoreVisibleMapState();
    ESP_LOGI(TAG, "Pinch backdrop preparation interrupted");
    return false;
  }

  if (shouldInterruptMapRenderForScreenCycle()) {
    restoreVisibleMapState();
    ESP_LOGI(TAG, "Pinch backdrop preparation interrupted before completion");
    return false;
  }

  if (routeOverlay.hasRoute() && isRouteOverlayVisible(mapRenderSettings)) {
    routeOverlay.drawRoute(Maps::canvasMapTemp, backdropProjection);
  }

  if (shouldInterruptMapRenderForScreenCycle()) {
    restoreVisibleMapState();
    ESP_LOGI(TAG, "Pinch backdrop preparation interrupted after route");
    return false;
  }

  restoreVisibleMapState();
  pinchZoomOutBackdrop.prepared = true;
  pinchZoomOutBackdrop.baseZoom = baseZoom;
  pinchZoomOutBackdrop.renderZoom = backdropZoom;
  pinchZoomOutBackdrop.center = Maps::point;
  pinchZoomOutBackdrop.rotation = backdropRotation;
  pinchZoomOutBackdrop.canvasHeight = canvasHeight;
  ESP_LOGI(TAG, "Pinch backdrop ready");
  return true;
}

void Maps::applyDragPreviewOffset(map_drag_preview::Offset offset) {
  map_drag_preview::Offset presented = offset;
  if (dragPresentation.waitsForRollingRaster) {
    // The first preload after a zoom change may have been interrupted by this
    // touch. Keep the last complete viewport fixed until the rolling window
    // is ready; moving that exact-size snapshot would expose empty pixels.
    presented = {};
  } else if (dragPresentation.usesRollingRaster &&
             rollingRasterWindow.valid) {
    presented.x = map_raster_window::clampDragOffset(
        dragPresentation.baseRasterOffsetX, offset.x,
        rollingRasterWindow.viewportWidth, rollingRasterWindow.tileWidth,
        rollingRasterWindow.gridSpan);
    presented.y = map_raster_window::clampDragOffset(
        dragPresentation.baseRasterOffsetY, offset.y,
        rollingRasterWindow.viewportHeight, rollingRasterWindow.tileHeight,
        rollingRasterWindow.gridSpan);
  }
  dragPresentation.presentedOffset = presented;
  const int32_t visualX = -presented.x;
  const int32_t visualY = -presented.y;
  if (Maps::canvasMap != nullptr) {
    lv_obj_set_pos(Maps::canvasMap,
                   static_cast<int32_t>(dragPresentation.canvasBaseX) +
                       visualX,
                   static_cast<int32_t>(dragPresentation.canvasBaseY) +
                       visualY);
    lv_obj_invalidate(Maps::canvasMap);
  }
  if (dragPresentation.hasBackdrop && Maps::canvasMapTemp != nullptr) {
    lv_obj_set_pos(Maps::canvasMapTemp,
                   static_cast<int32_t>(dragPresentation.canvasBaseX) +
                       visualX,
                   static_cast<int32_t>(dragPresentation.canvasBaseY) +
                       visualY);
    lv_obj_clear_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
    lv_obj_invalidate(Maps::canvasMapTemp);
  }
  if (Maps::canvasArrow != nullptr) {
    lv_obj_set_pos(Maps::canvasArrow,
                   static_cast<int32_t>(dragPresentation.markerBaseX) +
                       visualX,
                   static_cast<int32_t>(dragPresentation.markerBaseY) +
                       visualY);
    lv_obj_invalidate(Maps::canvasArrow);
  }
}

void Maps::syncDragPreviewCenterToPresentedOffset() {
  const map_transform::WorldPoint center =
      map_transform::centerAfterScreenDrag(
          {static_cast<double>(dragPresentation.baseCenter.x),
           static_cast<double>(dragPresentation.baseCenter.y)},
          {static_cast<double>(dragPresentation.presentedOffset.x),
           static_cast<double>(dragPresentation.presentedOffset.y)},
          dragPresentation.baseZoom, dragPresentation.baseRotation);
  Maps::point.x = static_cast<int32_t>(std::round(center.x));
  Maps::point.y = static_cast<int32_t>(std::round(center.y));
  Maps::isPosMoved = true;
  Maps::followGps = false;
}

void Maps::rebaseRollingDragAtVisibleEndpoint() {
  if (!rollingRasterWindow.valid || Maps::canvasMap == nullptr) {
    syncDragPreviewCenterToPresentedOffset();
    return;
  }
  const auto rebase = map_transform::rollingDragRebase(
      {static_cast<double>(dragPresentation.baseCenter.x),
       static_cast<double>(dragPresentation.baseCenter.y)},
      {static_cast<double>(dragPresentation.presentedOffset.x),
       static_cast<double>(dragPresentation.presentedOffset.y)},
      dragPresentation.baseZoom, dragPresentation.baseRotation,
      {rollingRasterWindow.phaseOriginX,
       rollingRasterWindow.phaseOriginY},
      {rollingRasterWindow.originPhaseOffsetX,
       rollingRasterWindow.originPhaseOffsetY});
  Maps::point = {rebase.center.x, rebase.center.y};
  Maps::isPosMoved = true;
  Maps::followGps = false;
  lv_obj_center(Maps::canvasMap);
  lv_obj_set_pos(Maps::canvasMap, rebase.canvasOffset.x,
                 rebase.canvasOffset.y);
  lv_obj_invalidate(Maps::canvasMap);
  dragPresentation.canvasBaseX = rebase.canvasOffset.x;
  dragPresentation.canvasBaseY = rebase.canvasOffset.y;
  dragPresentation.baseRasterOffsetX = rebase.rasterCenterOffset.x;
  dragPresentation.baseRasterOffsetY = rebase.rasterCenterOffset.y;
}

bool Maps::beginDragPreview(uint8_t baseZoom) {
  if (!mapSet.vectorMap || Maps::canvasMap == nullptr ||
      pinchPresentation.active || pinchPresentation.settlementPending ||
      dragPreviewController.active()) {
    return false;
  }

  const uint8_t normalizedZoom = map_transform::clampRuntimeZoom(baseZoom);
  const bool continuingSettlement =
      dragPreviewController.settlementPending();
  if (continuingSettlement && dragPresentation.baseZoom != normalizedZoom) {
    cancelDragPreview();
    return false;
  }

  // A new finger-down always gets a fresh presentation baseline, even if the
  // previous release is still waiting for raster recycling. Keeping the old
  // DragPresentation alive made an interrupted settlement capable of
  // restoring the first gesture's canvas origin.
  dragPreviewController.replaceCommittedOffset({});
  dragPresentation = {};
  dragPresentation.baseZoom = normalizedZoom;
  dragPresentation.baseCenter = Maps::point;
  dragPresentation.baseRotation = visibleMapRotation();
  // lv_obj_set_pos() updates the offset from the object's configured center
  // alignment, so preserve that aligned offset rather than its resolved
  // top-left coordinate. This works for both normal and oversized canvases.
  dragPresentation.canvasBaseX = lv_obj_get_x_aligned(Maps::canvasMap);
  dragPresentation.canvasBaseY = lv_obj_get_y_aligned(Maps::canvasMap);
  if (Maps::canvasArrow != nullptr) {
    dragPresentation.markerBaseX =
        lv_obj_get_x_aligned(Maps::canvasArrow);
    dragPresentation.markerBaseY =
        lv_obj_get_y_aligned(Maps::canvasArrow);
  }
  dragPresentation.usesRollingRaster =
      rollingRasterWindow.valid &&
      normalizedZoom == rollingRasterWindow.zoom && isMapScreenActive();
  // The rolling raster already covers drag exposure. Its prepared pinch
  // backdrop is viewport-sized and has a different aligned origin, so it is
  // only presented by the pinch path.
  dragPresentation.hasBackdrop =
      !dragPresentation.usesRollingRaster &&
      hasPinchZoomOutBackdrop(normalizedZoom);
  if (dragPresentation.hasBackdrop) {
    dragPresentation.backdropZoom = pinchZoomOutBackdrop.renderZoom;
  }
  dragPresentation.waitsForRollingRaster =
      shouldUseRollingRasterWindow(normalizedZoom) &&
      !rollingRasterWindow.valid;
  if (dragPresentation.usesRollingRaster) {
    const auto centerOffset = rollingRasterCenterOffset(Maps::point);
    dragPresentation.baseRasterOffsetX = centerOffset.x;
    dragPresentation.baseRasterOffsetY = centerOffset.y;
  }

  if (!dragPreviewController.begin())
    return false;

  hideRollingForeground();
  lv_obj_clear_flag(mapTile, LV_OBJ_FLAG_OVERFLOW_VISIBLE);
  if (dragPresentation.hasBackdrop && Maps::canvasMapTemp != nullptr) {
    const uint16_t height =
        mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
    const double backdropRatio = map_transform::backdropPresentationRatio(
        1.0, dragPresentation.baseZoom, dragPresentation.backdropZoom);
    const uint32_t backdropLvScale = static_cast<uint32_t>(
        std::max<double>(1.0, std::round(backdropRatio * LV_SCALE_NONE)));
    lv_image_set_pivot(Maps::canvasMapTemp,
                       mapAnchorXForWidth(Maps::mapScrWidth),
                       mapAnchorYForHeight(height));
    lv_image_set_scale(Maps::canvasMapTemp, backdropLvScale);
    lv_obj_move_background(Maps::canvasMapTemp);
    lv_obj_move_foreground(Maps::canvasMap);
    if (Maps::canvasArrow != nullptr)
      lv_obj_move_foreground(Maps::canvasArrow);
  }
  applyDragPreviewOffset(dragPreviewController.committedOffset());
  return true;
}

void Maps::updateDragPreview(int16_t sessionDx, int16_t sessionDy) {
  if (!dragPreviewController.active())
    return;
  applyDragPreviewOffset(dragPreviewController.preview(sessionDx, sessionDy));
  if (dragPresentation.usesRollingRaster ||
      dragPresentation.waitsForRollingRaster) {
    // Keep the logical map center synchronized with the pixels throughout the
    // drag. Release is now only a settlement boundary; it is no longer the
    // single point at which the drag endpoint becomes authoritative.
    syncDragPreviewCenterToPresentedOffset();
  }
}

void Maps::commitDragPreview(int16_t sessionDx, int16_t sessionDy,
                             uint32_t nowMs) {
  if (!dragPreviewController.active())
    return;
  const map_drag_preview::Offset committed =
      dragPreviewController.commit(sessionDx, sessionDy, nowMs);
  applyDragPreviewOffset(committed);
  if (dragPresentation.usesRollingRaster ||
      dragPresentation.waitsForRollingRaster) {
    const map_drag_preview::Offset presented =
        dragPresentation.presentedOffset;
    dragPreviewController.replaceCommittedOffset(presented);
    if (dragPresentation.usesRollingRaster && rollingRasterWindow.valid) {
      rebaseRollingDragAtVisibleEndpoint();
    } else {
      syncDragPreviewCenterToPresentedOffset();
    }
    // Maps::point now describes the exact endpoint already shown by the drag
    // preview. Make that endpoint the baseline immediately instead of keeping
    // the next gesture relative to the canvas position captured before the
    // first drag. Raster recycling may still be pending, but a rapid second
    // touch must start from the pixels that are currently visible.
    if (Maps::canvasArrow != nullptr) {
      dragPresentation.markerBaseX =
          lv_obj_get_x_aligned(Maps::canvasArrow);
      dragPresentation.markerBaseY =
          lv_obj_get_y_aligned(Maps::canvasArrow);
    }
    dragPresentation.presentedOffset = {};
    dragPreviewController.replaceCommittedOffset({});
    // A clamped drag can legitimately apply zero movement. It still needs one
    // generation pass to recycle/retry the window and clear settlement state.
    Maps::isPosMoved = true;
  } else {
    Maps::scrollMap(sessionDx, sessionDy);
  }
  Maps::redrawMap = true;
}

void Maps::handoffDragPreviewToPinch() {
  if (!dragPreviewController.active() &&
      !dragPreviewController.settlementPending()) {
    return;
  }

  // A two-finger gesture may arrive in the same LVGL read that releases the
  // synthetic one-finger pointer. Keep the exact endpoint already visible,
  // normalize the rolling canvas against it, and drop only the old gesture's
  // bookkeeping. Restoring dragPresentation.canvasBase* here would jump back
  // to the first finger-down origin.
  if (dragPreviewController.active() &&
      (dragPresentation.usesRollingRaster ||
       dragPresentation.waitsForRollingRaster)) {
    if (dragPresentation.usesRollingRaster && rollingRasterWindow.valid) {
      rebaseRollingDragAtVisibleEndpoint();
    } else {
      syncDragPreviewCenterToPresentedOffset();
    }
  }
  if (dragPresentation.usesRollingRaster && rollingRasterWindow.valid) {
    positionRollingRasterCanvas(Maps::point);
  }
  if (Maps::canvasMapTemp != nullptr) {
    lv_image_set_scale(Maps::canvasMapTemp, LV_SCALE_NONE);
    lv_image_set_pivot(Maps::canvasMapTemp, 0, 0);
    lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  }
  dragPreviewController.reset();
  dragPresentation = {};
  Maps::isPosMoved = true;
  Maps::redrawMap = true;
}

void Maps::resetDragPresentationVisuals() {
  if (Maps::canvasMap != nullptr) {
    if (dragPresentation.usesRollingRaster && rollingRasterWindow.valid) {
      positionRollingRasterCanvas(Maps::point);
    } else {
      lv_obj_set_pos(Maps::canvasMap, dragPresentation.canvasBaseX,
                     dragPresentation.canvasBaseY);
    }
    lv_obj_invalidate(Maps::canvasMap);
  }
  if (Maps::canvasMapTemp != nullptr) {
    lv_image_set_scale(Maps::canvasMapTemp, LV_SCALE_NONE);
    lv_image_set_pivot(Maps::canvasMapTemp, 0, 0);
    lv_obj_set_pos(Maps::canvasMapTemp, dragPresentation.canvasBaseX,
                   dragPresentation.canvasBaseY);
    lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  }
  if (Maps::canvasArrow != nullptr) {
    lv_obj_set_pos(Maps::canvasArrow, dragPresentation.markerBaseX,
                   dragPresentation.markerBaseY);
  }
}

void Maps::cancelDragPreview() {
  if (dragPreviewController.active() ||
      dragPreviewController.settlementPending()) {
    resetDragPresentationVisuals();
  }
  dragPreviewController.reset();
  dragPresentation = {};
  restoreRollingForeground();
}

void Maps::finishDragSettlement() {
  if (!dragPreviewController.settlementPending())
    return;
  resetDragPresentationVisuals();
  dragPreviewController.reset();
  dragPresentation = {};
}

bool Maps::beginPinchPreview(int16_t midpointX, int16_t midpointY,
                             uint8_t baseZoom) {
  if (Maps::canvasMap == nullptr || pinchPresentation.settlementPending ||
      dragPreviewController.active() ||
      dragPreviewController.settlementPending()) {
    return false;
  }

  pinchPresentation.active = true;
  hideRollingForeground();
  pinchPresentation.capturedFollowGps = Maps::followGps;
  pinchPresentation.baseZoom = map_transform::clampRuntimeZoom(baseZoom);
  pinchPresentation.baseCenter = Maps::point;
  pinchPresentation.baseRotation = visibleMapRotation();
  pinchPresentation.initialMidpointX = midpointX;
  pinchPresentation.initialMidpointY = midpointY;
  pinchPresentation.canvasBaseX = lv_obj_get_x_aligned(Maps::canvasMap);
  pinchPresentation.canvasBaseY = lv_obj_get_y_aligned(Maps::canvasMap);
  if (Maps::canvasArrow != nullptr) {
    pinchPresentation.markerBaseX = lv_obj_get_x_aligned(Maps::canvasArrow);
    pinchPresentation.markerBaseY = lv_obj_get_y_aligned(Maps::canvasArrow);
  }

  lv_obj_update_layout(Maps::canvasMap);
  lv_area_t canvasArea;
  lv_obj_get_coords(Maps::canvasMap, &canvasArea);
  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  const auto currentExtent =
      canvasExtent(Maps::canvasMap, Maps::mapScrWidth, viewportHeight);
  const bool usesRollingRaster =
      rollingRasterWindow.valid &&
      pinchPresentation.baseZoom == rollingRasterWindow.zoom &&
      isMapScreenActive();
  int32_t rollingCenterOffsetX = 0;
  int32_t rollingCenterOffsetY = 0;
  if (usesRollingRaster) {
    const auto centerOffset = rollingRasterCenterOffset(Maps::point);
    rollingCenterOffsetX = centerOffset.x;
    rollingCenterOffsetY = centerOffset.y;
  }
  if (Maps::followGps) {
    pinchPresentation.pivotLocalX =
        mapAnchorXForWidth(currentExtent.width) + rollingCenterOffsetX;
    pinchPresentation.pivotLocalY =
        mapAnchorYForHeight(currentExtent.height) + rollingCenterOffsetY;
  } else {
    pinchPresentation.pivotLocalX = static_cast<int16_t>(
        std::max<int32_t>(0, std::min<int32_t>(
                                 currentExtent.width - 1,
                                 midpointX - canvasArea.x1)));
    pinchPresentation.pivotLocalY = static_cast<int16_t>(
        std::max<int32_t>(0, std::min<int32_t>(
                                 currentExtent.height - 1,
                                 midpointY - canvasArea.y1)));
  }
  if (usesRollingRaster) {
    const uint16_t containerWidth = lv_obj_get_width(mapTile);
    const uint16_t containerHeight = lv_obj_get_height(mapTile);
    pinchPresentation.anchorScreenX =
        gui_layout::mapScreenAnchorX(containerWidth, Maps::mapScrWidth);
    pinchPresentation.anchorScreenY =
        gui_layout::mapScreenAnchorY(containerHeight, viewportHeight);
  } else {
    pinchPresentation.anchorScreenX =
        canvasArea.x1 + mapAnchorXForWidth(currentExtent.width);
    pinchPresentation.anchorScreenY =
        canvasArea.y1 + mapAnchorYForHeight(currentExtent.height);
  }
  pinchPresentation.hasZoomOutBackdrop =
      hasPinchZoomOutBackdrop(pinchPresentation.baseZoom);
  if (pinchPresentation.hasZoomOutBackdrop) {
    pinchPresentation.zoomOutBackdropZoom = pinchZoomOutBackdrop.renderZoom;
    pinchPresentation.backdropBaseX =
        lv_obj_get_x_aligned(Maps::canvasMapTemp);
    pinchPresentation.backdropBaseY =
        lv_obj_get_y_aligned(Maps::canvasMapTemp);
    lv_obj_update_layout(Maps::canvasMapTemp);
    lv_area_t backdropArea;
    lv_obj_get_coords(Maps::canvasMapTemp, &backdropArea);
    if (Maps::followGps) {
      pinchPresentation.backdropPivotLocalX =
          mapAnchorXForWidth(Maps::mapScrWidth);
      pinchPresentation.backdropPivotLocalY =
          mapAnchorYForHeight(viewportHeight);
    } else {
      pinchPresentation.backdropPivotLocalX = static_cast<int16_t>(
          std::max<int32_t>(0, std::min<int32_t>(
                                   Maps::mapScrWidth - 1,
                                   midpointX - backdropArea.x1)));
      pinchPresentation.backdropPivotLocalY = static_cast<int16_t>(
          std::max<int32_t>(0, std::min<int32_t>(
                                   viewportHeight - 1,
                                   midpointY - backdropArea.y1)));
    }
  }

  lv_obj_clear_flag(mapTile, LV_OBJ_FLAG_OVERFLOW_VISIBLE);
  lv_obj_set_style_bg_color(mapTile, lv_color_hex(BACKGROUND_COLOR), 0);
  lv_obj_set_style_bg_opa(mapTile, LV_OPA_COVER, 0);
  lv_image_set_pivot(Maps::canvasMap, pinchPresentation.pivotLocalX,
                     pinchPresentation.pivotLocalY);
  lv_image_set_scale(Maps::canvasMap, LV_SCALE_NONE);
  if (pinchPresentation.hasZoomOutBackdrop) {
    lv_obj_set_pos(Maps::canvasMapTemp, pinchPresentation.backdropBaseX,
                   pinchPresentation.backdropBaseY);
    lv_image_set_pivot(Maps::canvasMapTemp,
                       pinchPresentation.backdropPivotLocalX,
                       pinchPresentation.backdropPivotLocalY);
    lv_obj_move_background(Maps::canvasMapTemp);
    lv_obj_move_foreground(Maps::canvasMap);
    if (Maps::canvasArrow != nullptr)
      lv_obj_move_foreground(Maps::canvasArrow);
  }
#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
  recordPinchPreviewFrame(true);
#endif
  return true;
}

void Maps::updatePinchPreview(double previewRatio, int16_t midpointX,
                              int16_t midpointY) {
  if (!pinchPresentation.active || Maps::canvasMap == nullptr) {
    return;
  }
  const double ratio = map_transform::clampPreviewRatio(
      previewRatio, pinchPresentation.baseZoom);
  const uint32_t lvScale = static_cast<uint32_t>(
      std::max<double>(1.0, std::round(ratio * LV_SCALE_NONE)));
  const int16_t translationX = pinchPresentation.capturedFollowGps
                                   ? 0
                                   : midpointX -
                                         pinchPresentation.initialMidpointX;
  const int16_t translationY = pinchPresentation.capturedFollowGps
                                   ? 0
                                   : midpointY -
                                         pinchPresentation.initialMidpointY;

  lv_obj_set_pos(Maps::canvasMap,
                 pinchPresentation.canvasBaseX + translationX,
                 pinchPresentation.canvasBaseY + translationY);
  lv_image_set_scale(Maps::canvasMap, lvScale);
  if (pinchPresentation.hasZoomOutBackdrop && Maps::canvasMapTemp != nullptr &&
      ratio < 0.999) {
    const double backdropRatio = map_transform::backdropPresentationRatio(
        ratio, pinchPresentation.baseZoom,
        pinchPresentation.zoomOutBackdropZoom);
    const uint32_t backdropLvScale = static_cast<uint32_t>(
        std::max<double>(1.0, std::round(backdropRatio * LV_SCALE_NONE)));
    lv_obj_set_pos(Maps::canvasMapTemp,
                   pinchPresentation.backdropBaseX + translationX,
                   pinchPresentation.backdropBaseY + translationY);
    lv_image_set_scale(Maps::canvasMapTemp, backdropLvScale);
    lv_obj_clear_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
    lv_obj_invalidate(Maps::canvasMapTemp);
  } else if (Maps::canvasMapTemp != nullptr) {
    lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  }
#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
  recordPinchPreviewFrame();
#endif

  if (!pinchPresentation.capturedFollowGps && Maps::canvasArrow != nullptr) {
    const double pivotX = pinchPresentation.initialMidpointX;
    const double pivotY = pinchPresentation.initialMidpointY;
    const int16_t markerAnchorX = currentMarkerAnchorX();
    const int16_t markerAnchorY = currentMarkerAnchorY();
    const double markerCenterX = pinchPresentation.markerBaseX + markerAnchorX;
    const double markerCenterY = pinchPresentation.markerBaseY + markerAnchorY;
    const int16_t transformedX = static_cast<int16_t>(std::round(
        pivotX + ((markerCenterX - pivotX) * ratio) + translationX -
        markerAnchorX));
    const int16_t transformedY = static_cast<int16_t>(std::round(
        pivotY + ((markerCenterY - pivotY) * ratio) + translationY -
        markerAnchorY));
    lv_obj_set_pos(Maps::canvasArrow, transformedX, transformedY);
  }
  lv_obj_invalidate(Maps::canvasMap);
  if (Maps::canvasArrow != nullptr)
    lv_obj_invalidate(Maps::canvasArrow);
}

void Maps::resetPinchPresentationVisuals() {
  if (Maps::canvasMap != nullptr) {
    lv_anim_delete(Maps::canvasMap, setPinchCanvasScale);
    lv_image_set_scale(Maps::canvasMap, LV_SCALE_NONE);
    lv_image_set_pivot(Maps::canvasMap, 0, 0);
    lv_obj_set_pos(Maps::canvasMap, pinchPresentation.canvasBaseX,
                   pinchPresentation.canvasBaseY);
    lv_obj_invalidate(Maps::canvasMap);
  }
  if (Maps::canvasMapTemp != nullptr) {
    lv_anim_delete(Maps::canvasMapTemp, setPinchCanvasScale);
    lv_image_set_scale(Maps::canvasMapTemp, LV_SCALE_NONE);
    lv_image_set_pivot(Maps::canvasMapTemp, 0, 0);
    lv_obj_set_pos(
        Maps::canvasMapTemp,
        pinchPresentation.hasZoomOutBackdrop
            ? pinchPresentation.backdropBaseX
            : pinchPresentation.canvasBaseX,
        pinchPresentation.hasZoomOutBackdrop
            ? pinchPresentation.backdropBaseY
            : pinchPresentation.canvasBaseY);
    lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  }
  if (Maps::canvasArrow != nullptr) {
    lv_obj_set_pos(Maps::canvasArrow, pinchPresentation.markerBaseX,
                   pinchPresentation.markerBaseY);
  }
}

void Maps::cancelPinchPreview() {
  if (Maps::canvasMap != nullptr) {
    lv_anim_delete(Maps::canvasMap, setPinchCanvasScale);
  }
  if (pinchPresentation.active || pinchPresentation.settlementPending) {
    resetPinchPresentationVisuals();
  }
  pinchPresentation = {};
  restoreRollingForeground();
}

void Maps::commitPinchZoom(uint8_t targetZoom, double finalPreviewRatio,
                           int16_t finalMidpointX,
                           int16_t finalMidpointY) {
  if (!pinchPresentation.active) {
    return;
  }
  targetZoom = map_transform::clampRuntimeZoom(targetZoom);
  if (!pinchPresentation.capturedFollowGps) {
    const double anchorX = pinchPresentation.anchorScreenX;
    const double anchorY = pinchPresentation.anchorScreenY;
    const map_transform::WorldPoint adjusted =
        map_transform::focalPreservingCenter(
            {static_cast<double>(pinchPresentation.baseCenter.x),
             static_cast<double>(pinchPresentation.baseCenter.y)},
            {static_cast<double>(pinchPresentation.initialMidpointX) - anchorX,
             static_cast<double>(pinchPresentation.initialMidpointY) - anchorY},
            {static_cast<double>(finalMidpointX) - anchorX,
             static_cast<double>(finalMidpointY) - anchorY},
            pinchPresentation.baseZoom, targetZoom,
            pinchPresentation.baseRotation);
    Maps::point.x = static_cast<int32_t>(std::round(adjusted.x));
    Maps::point.y = static_cast<int32_t>(std::round(adjusted.y));
    Maps::followGps = false;
  } else {
    Maps::followGps = true;
  }
  // Keep the old complete frame visible while the new discrete zoom frame is
  // rendered. This also prevents the prepared backdrop from being exposed if
  // a settlement render is interrupted by a new touch.
  resetPinchPresentationVisuals();
  pinchPresentation.finalPreviewRatio = finalPreviewRatio;
  pinchPresentation.finalMidpointX = finalMidpointX;
  pinchPresentation.finalMidpointY = finalMidpointY;
  pinchPresentation.active = false;
  pinchPresentation.settlementPending = true;
  Maps::isPosMoved = true;
  Maps::redrawMap = true;
}

void Maps::finishPinchSettlement() {
  if (!pinchPresentation.settlementPending) {
    return;
  }
  if (Maps::canvasMap == nullptr) {
    pinchPresentation = {};
    return;
  }

  const double effectiveScale =
      map_transform::worldToScreenScale(pinchPresentation.baseZoom) *
      pinchPresentation.finalPreviewRatio;
  const double targetScale = map_transform::worldToScreenScale(zoomLevel);
  const uint32_t initialScale = static_cast<uint32_t>(std::round(
      (effectiveScale / targetScale) * static_cast<double>(LV_SCALE_NONE)));
  lv_obj_update_layout(Maps::canvasMap);
  lv_area_t canvasArea;
  lv_obj_get_coords(Maps::canvasMap, &canvasArea);
  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  const auto currentExtent =
      canvasExtent(Maps::canvasMap, Maps::mapScrWidth, viewportHeight);
  const int32_t pivotScreenX = pinchPresentation.capturedFollowGps
                                   ? pinchPresentation.anchorScreenX
                                   : pinchPresentation.finalMidpointX;
  const int32_t pivotScreenY = pinchPresentation.capturedFollowGps
                                   ? pinchPresentation.anchorScreenY
                                   : pinchPresentation.finalMidpointY;
  const int16_t settlementPivotX = static_cast<int16_t>(
      std::max<int32_t>(0, std::min<int32_t>(
                               currentExtent.width - 1,
                               pivotScreenX - canvasArea.x1)));
  const int16_t settlementPivotY = static_cast<int16_t>(
      std::max<int32_t>(0, std::min<int32_t>(
                               currentExtent.height - 1,
                               pivotScreenY - canvasArea.y1)));
  lv_anim_delete(Maps::canvasMap, setPinchCanvasScale);
  lv_obj_set_pos(Maps::canvasMap, pinchPresentation.canvasBaseX,
                 pinchPresentation.canvasBaseY);
  lv_image_set_pivot(Maps::canvasMap, settlementPivotX, settlementPivotY);
  lv_image_set_scale(Maps::canvasMap, initialScale);

  if (initialScale != LV_SCALE_NONE) {
    lv_anim_t animation;
    lv_anim_init(&animation);
    lv_anim_set_var(&animation, Maps::canvasMap);
    lv_anim_set_exec_cb(&animation, setPinchCanvasScale);
    lv_anim_set_values(&animation, static_cast<int32_t>(initialScale),
                       LV_SCALE_NONE);
    lv_anim_set_duration(&animation, 120);
    lv_anim_set_path_cb(&animation, lv_anim_path_ease_out);
    lv_anim_set_completed_cb(&animation, completePinchCanvasSettlement);
    lv_anim_start(&animation);
  } else {
    lv_image_set_pivot(Maps::canvasMap, 0, 0);
  }
  pinchPresentation = {};
}

/**
 * @brief Toggle Map Rotation Mode
 */
void Maps::toggleRotationMode() {
  if (rotationMode == ROT_NORTH_UP) {
    rotationMode = ROT_COURSE_UP;
    resetCourseUpHeading();
    log_i("Map Rotation: COURSE UP");
  } else {
    rotationMode = ROT_NORTH_UP;
    resetCourseUpHeading();
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
  if (!Maps::canvasArrow)
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
  if (Maps::canvasMap)
    lv_obj_invalidate(Maps::canvasMap);
  updatePositionOverlay();
}

map_transform::WorldPoint Maps::presentedGpsWorld(uint32_t nowMs) {
  const map_transform::WorldPoint raw = {
      lon2x(gps.gpsData.longitude), lat2y(gps.gpsData.latitude)};
  latestPresentedWorld = positionPresenter.update(raw, nowMs);
  hasLatestPresentedWorld = true;
  return latestPresentedWorld;
}

void Maps::updateGuidanceRouteHead(
    map_transform::WorldPoint presentedWorld) {
  // Standalone Map owns this foreground for its rolling labels/route. Only
  // guidance uses the live head, so do not hide the standalone foreground on
  // every 30 ms position update.
  if (!isMapGuidanceScreenActive())
    return;

  if (Maps::canvasForeground == nullptr || !hasVisibleProjection ||
      !routeOverlay.hasRoute() ||
      !isRouteOverlayVisible(mapRenderSettings)) {
    rollingForegroundReady = false;
    hideRollingForeground();
    return;
  }

  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  if (!ensureMapForegroundBuffer(Maps::mapScrWidth, viewportHeight)) {
    rollingForegroundReady = false;
    hideRollingForeground();
    return;
  }

  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(Maps::canvasForeground);
  if (drawBuffer == nullptr || drawBuffer->header.w != Maps::mapScrWidth ||
      drawBuffer->header.h != viewportHeight) {
    bindMapForegroundCanvas(Maps::canvasForeground, Maps::mapScrWidth,
                            viewportHeight);
  }
  lv_obj_center(Maps::canvasForeground);

  // Keep the geographic GPS anchor at the arrow's lower center so map
  // rotation still pivots around the rider, but attach the visible route line
  // to the arrow's visual center. The foreground is translated after this
  // draw; deriving the center from the presented projection keeps that
  // attachment exact during sub-fix motion as well as full map renders.
  map_transform::WorldPoint markerCenterWorld = presentedWorld;
  const auto presentedProjection =
      visibleProjection.projectWorld(presentedWorld);
  if (presentedProjection.valid) {
    const double markerCenterOffsetX =
        static_cast<double>(currentMarkerSize() / 2 - currentMarkerAnchorX());
    const double markerCenterOffsetY =
        static_cast<double>(currentMarkerSize() / 2 - currentMarkerAnchorY());
    const auto markerCenterGround = visibleProjection.groundForScreen(
        presentedProjection.x + markerCenterOffsetX,
        presentedProjection.y + markerCenterOffsetY);
    markerCenterWorld = visibleProjection.worldForGround(markerCenterGround);
  }
  routeOverlay.drawLiveHead(Maps::canvasForeground, visibleProjection,
                            presentedWorld, markerCenterWorld);
  rollingForegroundReady = false;
  lv_obj_clear_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
  lv_obj_invalidate(Maps::canvasForeground);
}

bool Maps::isGuidanceBirdsEyeProjection() const {
  return isMapGuidanceScreenActive() && hasVisibleProjection &&
         visibleProjection.isBirdsEye();
}

bool Maps::guidanceProjectionNeedsRefresh() const {
  if (!isGuidanceBirdsEyeProjection() || !hasLatestPresentedWorld)
    return false;

  const auto projected = visibleProjection.projectWorld(latestPresentedWorld);
  if (!projected.valid)
    return true;

  // Keep a generous safety margin inside the rendered world bounds. Between
  // these epochs, the lightweight guidance translation can move the map
  // continuously without repeatedly rebuilding the perspective frame for
  // every GPS fix. A new projection is rendered only when the rider is close
  // enough to an edge that the cached map blocks may no longer cover it.
  constexpr double kProjectionRefreshMarginPixels = 96.0;
  const auto &config = visibleProjection.config();
  return projected.x < kProjectionRefreshMarginPixels ||
         projected.x >
             static_cast<double>(config.viewportWidth) -
                 kProjectionRefreshMarginPixels ||
         projected.y < kProjectionRefreshMarginPixels ||
         projected.y >
             static_cast<double>(config.viewportHeight) -
                 kProjectionRefreshMarginPixels;
}

void Maps::applyGuidanceMotionOffset(
    map_transform::WorldPoint presentedWorld) {
  if (!isMapGuidanceScreenActive() || !Maps::followGps ||
      Maps::canvasMap == nullptr || !hasVisibleProjection ||
      dragPreviewController.active() || dragPreviewController.settlementPending() ||
      pinchPresentation.active || pinchPresentation.settlementPending) {
    return;
  }

  const auto projected = visibleProjection.projectWorld(presentedWorld);
  if (!projected.valid)
    return;

  // A synchronous vector render recenters the canvas. Rebase from that stable
  // origin on every frame, then apply only the small sub-fix translation. The
  // marker remains fixed at the same lower-center anchor while the route and
  // base map move together underneath it.
  lv_obj_center(Maps::canvasMap);
  const int16_t baseX = lv_obj_get_x_aligned(Maps::canvasMap);
  const int16_t baseY = lv_obj_get_y_aligned(Maps::canvasMap);
  if (Maps::canvasForeground != nullptr) {
    lv_obj_set_pos(Maps::canvasForeground, baseX, baseY);
  }
  const int32_t requestedOffsetX = map_transform::quantizePixel(
      visibleProjection.anchorX() - projected.x);
  const int32_t requestedOffsetY = map_transform::quantizePixel(
      visibleProjection.anchorY() - projected.y);
  // The guidance canvas is currently viewport-sized. Do not move it beyond
  // its parent while a new vector frame is being rendered: doing so exposes
  // the parent's background as a black/unloaded strip that looks like map
  // data arriving in chunks. If a future renderer provides overscan, these
  // same bounds naturally expand to that coverage.
  const int32_t parentWidth = lv_obj_get_width(mapTile);
  const int32_t parentHeight = lv_obj_get_height(mapTile);
  const int32_t canvasWidth = lv_obj_get_width(Maps::canvasMap);
  const int32_t canvasHeight = lv_obj_get_height(Maps::canvasMap);
  const int32_t minOffsetX = -static_cast<int32_t>(baseX);
  const int32_t maxOffsetX = parentWidth -
                             (static_cast<int32_t>(baseX) + canvasWidth);
  const int32_t minOffsetY = -static_cast<int32_t>(baseY);
  const int32_t maxOffsetY = parentHeight -
                             (static_cast<int32_t>(baseY) + canvasHeight);
  const auto clampOffset = [](int32_t value, int32_t minimum,
                              int32_t maximum) -> int32_t {
    if (minimum > maximum)
      return static_cast<int32_t>(0);
    return static_cast<int32_t>(
        std::max<int32_t>(minimum, std::min<int32_t>(maximum, value)));
  };
  const int32_t offsetX =
      clampOffset(requestedOffsetX, minOffsetX, maxOffsetX);
  const int32_t offsetY =
      clampOffset(requestedOffsetY, minOffsetY, maxOffsetY);
  if (offsetX == 0 && offsetY == 0)
    return;

  lv_obj_set_pos(Maps::canvasMap, baseX + offsetX, baseY + offsetY);
  if (Maps::canvasForeground != nullptr) {
    lv_obj_set_pos(Maps::canvasForeground, baseX + offsetX,
                   baseY + offsetY);
  }
  lv_obj_invalidate(Maps::canvasMap);
  if (Maps::canvasForeground != nullptr)
    lv_obj_invalidate(Maps::canvasForeground);
}

uint16_t Maps::courseUpHeading(double latitude, double longitude,
                               uint16_t gpsHeading) {
  uint16_t routeHeading = 0;
  const uint16_t rawHeading =
      routeOverlay.headingNear(latitude, longitude, routeHeading)
          ? routeHeading
          : gpsHeading;
  return headingPresenter.update(rawHeading, millis(), routeOverlay.revision());
}

void Maps::resetCourseUpHeading() { headingPresenter.reset(); }

void Maps::updatePositionOverlay() {
  const uint32_t displayStartMs = MAPIO_TIME_MS();
  const map_transform::WorldPoint presentedWorld =
      presentedGpsWorld(millis());
  // Update Arrow Position
  if (Maps::canvasArrow) {
    if (!Maps::isMapFound || !isCurrentPositionVisible(mapRenderSettings)) {
      lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      updateGuidanceRouteHead(presentedWorld);
      MAPIO_LOG("MAPIO: current-position marker hidden mapFound=%d visible=%d\n",
                Maps::isMapFound, isCurrentPositionVisible(mapRenderSettings));
      return;
    }

    uint16_t h = mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
    const uint16_t containerWidth = lv_obj_get_width(mapTile);
    const uint16_t containerHeight = lv_obj_get_height(mapTile);
    const int16_t mapOriginX =
        gui_layout::centeredViewportOrigin(containerWidth, Maps::mapScrWidth);
    const int16_t mapOriginY =
        gui_layout::centeredViewportOrigin(containerHeight, h);
    const bool useSharedProjection =
        isMapGuidanceScreenActive() && hasVisibleProjection;
    const int16_t anchorX = useSharedProjection
                                ? static_cast<int16_t>(
                                      map_transform::quantizePixel(
                                          visibleProjection.anchorX()))
                                : mapAnchorXForWidth(Maps::mapScrWidth);
    const int16_t anchorY = useSharedProjection
                                ? static_cast<int16_t>(
                                      map_transform::quantizePixel(
                                          visibleProjection.anchorY()))
                                : mapAnchorYForHeight(h);
    updateCurrentPositionMarker(Maps::canvasArrow);
    const int16_t markerAnchorX = currentMarkerAnchorX();
    const int16_t markerAnchorY = currentMarkerAnchorY();
    const int16_t markerVisualHalf = currentMarkerSize() / 2;
    int16_t x, y;

    if (Maps::followGps) {
      // The marker is a sibling of the centered map canvas, so translate the
      // canvas-local anchor into map-tile coordinates before applying the
      // marker's geographic lower-center anchor.
      x = mapOriginX + anchorX - markerAnchorX;
      y = mapOriginY + anchorY - markerAnchorY;
      lv_obj_clear_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      lv_obj_set_pos(Maps::canvasArrow, x, y);
    } else {
      // Calculate position relative to viewport center
      // Convert GPS lat/lon to Mercator coordinates

      if (useSharedProjection) {
        const auto markerPoint = visibleProjection.projectWorld(
            presentedWorld);
        if (!markerPoint.valid) {
          lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
          return;
        }
        x = mapOriginX + map_transform::quantizePixel(markerPoint.x) -
            markerAnchorX;
        y = mapOriginY + map_transform::quantizePixel(markerPoint.y) -
            markerAnchorY;
      } else {
        const auto markerDelta = map_transform::worldToScreen(
            {presentedWorld.x - Maps::viewPort.center.x,
             presentedWorld.y - Maps::viewPort.center.y},
            zoom, visibleMapRotation());
        x = mapOriginX + round(markerDelta.x) + anchorX - markerAnchorX;
        y = mapOriginY + round(markerDelta.y) + anchorY - markerAnchorY;
      }

      lv_obj_set_pos(Maps::canvasArrow, x, y);

      // Simple bounds check to hide if too far off screen
      const int16_t centerX = x + markerVisualHalf;
      const int16_t centerY = y + markerVisualHalf;
      if (centerX < mapOriginX - markerVisualHalf ||
          centerX > mapOriginX + (int16_t)Maps::mapScrWidth +
                        markerVisualHalf ||
          centerY < mapOriginY - markerVisualHalf ||
          centerY > mapOriginY + (int16_t)h + markerVisualHalf) {
        lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      } else {
        lv_obj_clear_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      }
    }
    lv_obj_move_foreground(Maps::canvasArrow);
  }
  updateGuidanceRouteHead(presentedWorld);
  applyGuidanceMotionOffset(presentedWorld);
  MAPIO_LOG("MAPIO: display invalidateMs=%lu hasCanvas=%d hasArrow=%d\n",
            (unsigned long)(MAPIO_TIME_MS() - displayStartMs),
            Maps::canvasMap != nullptr, Maps::canvasArrow != nullptr);
}

/**
 * @brief Generate Vector Map
 *
 * @param zoom -> Zoom Level
 */
bool Maps::generateVectorMap(uint8_t zoom) {
  power_management::ScopedLock powerLock(power_management::LockDomain::Map);
  power_metrics::MapRenderMeasurement powerMeasurement;
#if POWER_METRICS
  uint32_t powerBlocksUs = 0;
  uint32_t powerDrawUs = 0;
  uint32_t powerRouteUs = 0;
#endif
  const uint32_t generateStartMs = MAPIO_TIME_MS();
  if (Maps::canvasMap == nullptr || Maps::canvasMapTemp == nullptr) {
    ESP_LOGE(TAG, "Map render skipped: canvas double buffer is unavailable");
    return false;
  }

  // The hidden buffer is about to become the render target. Any prepared
  // zoom-out backdrop in it is no longer reusable.
  invalidatePinchZoomOutBackdrop();

  Maps::mapTileSize = Maps::vectorMapTileSize;
  Maps::zoomLevel = zoom;

  // Compute the current course-up request once per generation. A pinch
  // settlement deliberately renders with the rotation of the pixels the
  // focal calculation started from; a changed heading is rendered next.
  double requestedRotation = 0.0;
  if (rotationMode == ROT_COURSE_UP) {
    uint16_t routeHeading = 0;
    const bool hasRouteHeading = routeOverlay.headingNear(
        gps.gpsData.latitude, gps.gpsData.longitude, routeHeading);
    const uint16_t smoothedHeading = courseUpHeading(
        gps.gpsData.latitude, gps.gpsData.longitude, gps.gpsData.heading);

    // Use negative heading to rotate map so the selected navigation/course
    // direction points up.
    requestedRotation = -DEG2RAD(smoothedHeading);
    ESP_LOGI(TAG, "Course-Up: heading=%u source=%s gpsHeading=%u",
             (unsigned)smoothedHeading, hasRouteHeading ? "route" : "gps",
             (unsigned)gps.gpsData.heading);
  }
  const bool frozenPinchSettlement = isPinchSettlementPending();
  rotationRad = map_transform::renderRotationForSettlement(
      frozenPinchSettlement, pinchPresentation.baseRotation,
      requestedRotation);
  if (frozenPinchSettlement &&
      map_transform::rotationNeedsRefresh(rotationRad, requestedRotation)) {
    deferredVectorRedraw = true;
  }

  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  if (shouldUseRollingRasterWindow(zoom)) {
    const uint64_t signature = rollingRasterSignature();
    bool completed = false;
    if (rollingRasterCompatible(zoom, Maps::mapScrWidth, viewportHeight,
                                signature)) {
      completed = settleRollingRasterWindow();
    } else {
      completed = buildRollingRasterWindow(zoom, Maps::mapScrWidth,
                                            viewportHeight, signature);
    }
    if (!completed)
      return false;

#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
    const bool completedPinchSettlement = isPinchSettlementPending();
#endif
    if (isPinchSettlementPending()) {
      // A rolling-window settlement can reposition the oversized canvas as
      // its origin advances. Animate from that completed position, not the
      // position captured from the previous raster/zoom.
      pinchPresentation.canvasBaseX = lv_obj_get_x_aligned(Maps::canvasMap);
      pinchPresentation.canvasBaseY = lv_obj_get_y_aligned(Maps::canvasMap);
    }
    finishDragSettlement();
    finishPinchSettlement();
    if (!renderRollingForeground()) {
      MAPIO_LOG("MAPIO: rolling-foreground ok=0 zoom=%u\n", zoom);
      return false;
    }
    MAPIO_LOG("MAPIO: rolling-generate zoom=%u totalMs=%lu cache=%u "
              "hasRoute=%d\n",
              zoom, (unsigned long)(MAPIO_TIME_MS() - generateStartMs),
              (unsigned)Maps::memCache.blocks.size(), routeOverlay.hasRoute());
#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
    if (completedPinchSettlement) {
      Serial.printf(
          "Pinch diagnostic: rolling_settlement_ms=%lu free_psram=%u "
          "largest_psram=%u\n",
          static_cast<unsigned long>(MAPIO_TIME_MS() - generateStartMs),
          heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
          heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
    }
#endif
    return true;
  }

  invalidateRollingRasterWindow();
  const map_drag_preview::CanvasExtent renderExtent = {Maps::mapScrWidth,
                                                        viewportHeight};
  const uint32_t renderStride = lv_draw_buf_width_to_stride(
      renderExtent.width, LV_COLOR_FORMAT_RGB565);
  const size_t renderSize = renderStride * renderExtent.height;
  if (renderSize > bufMapTempSize || renderSize > bufMapScreenSize) {
    ESP_LOGE(TAG,
             "Map render skipped: %ux%u frame needs %u bytes, screen=%u "
             "temp=%u",
             (unsigned)renderExtent.width, (unsigned)renderExtent.height,
             (unsigned)renderSize, (unsigned)bufMapScreenSize,
             (unsigned)bufMapTempSize);
    return false;
  }

  // The hidden scratch buffer receives the complete target geometry before it
  // is copied into the visible allocation. Interrupted renders never touch the
  // visible frame.
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, renderExtent.width,
                       renderExtent.height, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMapTemp);

  // Viewport
  Maps::viewPort.zoom = zoom;
  Maps::viewPort.setCenterForCanvas(Maps::point, renderExtent.width,
                                    renderExtent.height, rotationRad);
  const bool birdsEyeActive =
      navigation_content_mode::usesMapGuidanceBirdsEye(
          isMapGuidanceScreenActive(),
          mapRenderSettings.mapNavigationBirdsEyeEnabled);
  const auto frameProjection = makeMapProjection(
      Maps::viewPort.rasterOriginX, Maps::viewPort.rasterOriginY,
      Maps::viewPort.rasterCellOffsetX, Maps::viewPort.rasterCellOffsetY, zoom,
      rotationRad, renderExtent.width, renderExtent.height,
      birdsEyeActive ? map_projection::Mode::BirdsEye
                     : map_projection::Mode::Flat,
      map_projection::birdsEyePerspectiveForValue(
          mapRenderSettings.mapNavigationBirdsEyePerspective));
  if (frameProjection.isBirdsEye()) {
    const auto bounds = frameProjection.worldBounds(4.0);
    Maps::viewPort.bbox.min =
        Point32(static_cast<int32_t>(std::floor(bounds.min.x)),
                static_cast<int32_t>(std::floor(bounds.min.y)));
    Maps::viewPort.bbox.max =
        Point32(static_cast<int32_t>(std::ceil(bounds.max.x)),
                static_cast<int32_t>(std::ceil(bounds.max.y)));
  }

  // Get Map Blocks
  const uint32_t blocksStartMs = MAPIO_TIME_MS();
#if POWER_METRICS
  const uint32_t powerBlocksStartUs = micros();
#endif
  if (!Maps::getMapBlocks(Maps::viewPort.bbox, Maps::memCache)) {
#if POWER_METRICS
    powerBlocksUs = micros() - powerBlocksStartUs;
    powerMeasurement.setStageDurations(powerBlocksUs, powerDrawUs,
                                       powerRouteUs);
#endif
    log_i("Map block loading interrupted to service a screen-cycle input");
    return false;
  }
#if POWER_METRICS
  powerBlocksUs = micros() - powerBlocksStartUs;
  powerMeasurement.setStageDurations(powerBlocksUs, powerDrawUs,
                                     powerRouteUs);
#endif
  const uint32_t blocksMs = MAPIO_TIME_MS() - blocksStartMs;

  ESP_LOGI(TAG,
           "generateVectorMap: zoom=%d center(%d, %d) bbox[(%d, %d), (%d, %d)]",
           zoom, Maps::viewPort.center.x, Maps::viewPort.center.y,
           Maps::viewPort.bbox.min.x, Maps::viewPort.bbox.min.y,
           Maps::viewPort.bbox.max.x, Maps::viewPort.bbox.max.y);

  // Read Vector Map to Canvas (Pass calculated rotation)
  const uint32_t drawStartMs = MAPIO_TIME_MS();
#if POWER_METRICS
  const uint32_t powerDrawStartUs = micros();
#endif
  if (!Maps::readVectorMap(Maps::viewPort, Maps::memCache, Maps::canvasMapTemp,
                           zoom, rotationRad, frameProjection)) {
#if POWER_METRICS
    powerDrawUs = micros() - powerDrawStartUs;
    powerMeasurement.setStageDurations(powerBlocksUs, powerDrawUs,
                                       powerRouteUs);
#endif
    log_i("Map render interrupted to service a screen-cycle input");
    return false;
  }
#if POWER_METRICS
  powerDrawUs = micros() - powerDrawStartUs;
  powerMeasurement.setStageDurations(powerBlocksUs, powerDrawUs,
                                     powerRouteUs);
#endif
  const uint32_t drawMs = MAPIO_TIME_MS() - drawStartMs;

  if (shouldInterruptMapRenderForScreenCycle()) {
    log_i("Map render interrupted before route overlay");
    return false;
  }

  // Draw route overlay from iOS navigation (if available)
  const uint32_t routeStartMs = MAPIO_TIME_MS();
#if POWER_METRICS
  const uint32_t powerRouteStartUs = micros();
#endif
  ESP_LOGI(TAG, "Checking for route overlay: hasRoute=%d",
           routeOverlay.hasRoute());
  if (routeOverlay.hasRoute() && isRouteOverlayVisible(mapRenderSettings) &&
      !isMapGuidanceScreenActive()) {
    ESP_LOGI(TAG, "Drawing route overlay: zoom=%d points=%d", zoom,
             routeOverlay.getPointCount());

    routeOverlay.drawRoute(Maps::canvasMapTemp, frameProjection);
    ESP_LOGI(TAG, "Route overlay draw complete (rotation=%.2f rad, canvasH=%d)",
             rotationRad, renderExtent.height);
  } else if (routeOverlay.hasRoute() && isMapGuidanceScreenActive()) {
    // Guidance draws the route head on the display cadence from the same
    // presented position as the marker. Keeping the static snapshot out of
    // the base frame prevents stale geometry from leaving a gap or trailing
    // tail while BLE route windows are refreshed.
    ESP_LOGI(TAG, "Route overlay deferred to live guidance head");
  } else if (routeOverlay.hasRoute()) {
    ESP_LOGI(TAG, "Route overlay hidden by visibility mask");
  } else {
    ESP_LOGI(TAG, "No route overlay to draw (no route data)");
  }
#if POWER_METRICS
  powerRouteUs = micros() - powerRouteStartUs;
  powerMeasurement.setStageDurations(powerBlocksUs, powerDrawUs,
                                     powerRouteUs);
#endif
  const uint32_t routeMs = MAPIO_TIME_MS() - routeStartMs;

  if (shouldInterruptMapRenderForScreenCycle()) {
    log_i("Map render interrupted before presenting completed frame");
    return false;
  }

  const size_t rowBytes =
      static_cast<size_t>(renderExtent.width) * sizeof(uint16_t);
  auto *front = static_cast<uint8_t *>(bufMapScreen);
  const auto *completedFrame = static_cast<const uint8_t *>(bufMapTemp);
  for (uint16_t y = 0; y < renderExtent.height; ++y) {
    memcpy(front + (static_cast<size_t>(y) * renderStride),
           completedFrame + (static_cast<size_t>(y) * renderStride), rowBytes);
  }
  lv_canvas_set_buffer(Maps::canvasMap, bufMapScreen, renderExtent.width,
                       renderExtent.height, LV_COLOR_FORMAT_RGB565);
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, renderExtent.width,
                       renderExtent.height, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);
  lv_obj_center(Maps::canvasMapTemp);
  visibleProjection = frameProjection;
  hasVisibleProjection = true;
  if (isPinchSettlementPending()) {
    pinchPresentation.canvasBaseX = lv_obj_get_x_aligned(Maps::canvasMap);
    pinchPresentation.canvasBaseY = lv_obj_get_y_aligned(Maps::canvasMap);
  }
#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
  const bool completedPinchSettlement = isPinchSettlementPending();
#endif
  finishDragSettlement();
  finishPinchSettlement();

  MAPIO_LOG("MAPIO: generate zoom=%u mode=%s blocksMs=%lu drawMs=%lu "
            "routeMs=%lu totalMs=%lu cache=%u hasRoute=%d\n",
            zoom, frameProjection.isBirdsEye() ? "birds-eye" : "flat",
            (unsigned long)blocksMs, (unsigned long)drawMs,
            (unsigned long)routeMs,
            (unsigned long)(MAPIO_TIME_MS() - generateStartMs),
            (unsigned)Maps::memCache.blocks.size(), routeOverlay.hasRoute());
#ifdef WAVESHARE_TOUCH_DIAGNOSTICS
  if (completedPinchSettlement) {
    Serial.printf(
        "Pinch diagnostic: settlement_ms=%lu free_psram=%u "
        "largest_psram=%u\n",
        static_cast<unsigned long>(MAPIO_TIME_MS() - generateStartMs),
        heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
        heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
  }
#endif
  // NOTE: isPosMoved flag is now cleared in updateMap() after display,
  // not here, to allow queued BLE updates to trigger new regenerations
  powerMeasurement.finish(true);
  return true;
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

  ESP_LOGI(TAG, "centerOnGps: map center updated");
}

void Maps::centerOnPresentedGps() {
  const map_transform::WorldPoint presented = presentedGpsWorld(MAPIO_TIME_MS());
  Maps::followGps = true;
  Maps::point.x = static_cast<int32_t>(std::lround(presented.x));
  Maps::point.y = static_cast<int32_t>(std::lround(presented.y));

  const double lat = Maps::mercatorY2lat(presented.y);
  const double lon = Maps::mercatorX2lon(presented.x);
  Maps::currentMapTile.tilex = Maps::lon2tilex(lon, Maps::currentMapTile.zoom);
  Maps::currentMapTile.tiley = Maps::lat2tiley(lat, Maps::currentMapTile.zoom);
  Maps::currentMapTile.lat = lat;
  Maps::currentMapTile.lon = lon;
  Maps::isPosMoved = true;
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
    const auto worldDelta = map_transform::screenToWorld(
        {static_cast<double>(dx), static_cast<double>(dy)}, zoom,
        visibleMapRotation());
    Maps::point.x += static_cast<int32_t>(std::round(worldDelta.x));
    Maps::point.y += static_cast<int32_t>(std::round(worldDelta.y));
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
