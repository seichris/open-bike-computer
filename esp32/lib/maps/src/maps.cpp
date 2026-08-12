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
#include "mapBuildingAdmission.hpp"
#include "mapBuildingWorkspace.hpp"
#include "mapSurface.hpp"
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
#include "../../renderer_diagnostics/renderer_diagnostics.hpp"
#include "../../utils/src/line_rasterizer.hpp"
#include "../../ui_scheduler/ui_scheduler.hpp"

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
#include <atomic>
#include <esp_heap_caps.h>
#include <freertos/idf_additions.h>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <limits>
#include <new>
#include <numeric>
#include <sys/stat.h>
#include <unordered_map>

namespace {

#if FIRMWARE_DIAGNOSTICS
renderer_diagnostics::JobCounters rendererJobCounters(
    const map_render_job::Diagnostics &value) {
  return {
      value.submitted,
      value.started,
      value.completed,
      value.published,
      value.stalePublications,
      value.cancelled,
      value.invariantFailures,
  };
}
#endif

// Keep the main-branch memory diagnostics stable while moving raster work off
// the LVGL task. These samples are observational only and do not alter the
// renderer's allocation or scheduling policy.
static void logMapMemorySnapshot(const char *phase) {
#if defined(WAVESHARE_MAPIO_TIMING_LOG) || defined(WAVESHARE_TOUCH_DIAGNOSTICS)
  constexpr uint32_t kMapMemorySnapshotMinIntervalMs = 250;
  static uint32_t lastSnapshotMs[4] = {};
  size_t phaseIndex = 0;
  if (strcmp(phase, "canvas-draw") == 0)
    phaseIndex = 1;
  else if (strcmp(phase, "canvas-no-map") == 0)
    phaseIndex = 2;
  else if (strcmp(phase, "canvas-draw-empty") == 0)
    phaseIndex = 3;
  const uint32_t nowMs = millis();
  if (lastSnapshotMs[phaseIndex] != 0 &&
      nowMs - lastSnapshotMs[phaseIndex] < kMapMemorySnapshotMinIntervalMs)
    return;
  lastSnapshotMs[phaseIndex] = nowMs;
  constexpr uint32_t kInternalHeapCaps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
  const uint32_t freeInternalHeap =
      heap_caps_get_free_size(kInternalHeapCaps);
  const uint32_t largestInternalHeap =
      heap_caps_get_largest_free_block(kInternalHeapCaps);
  const uint32_t freePsram = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
  const uint32_t largestPsram =
      heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
  const uint32_t psramTotal = ESP.getPsramSize();
  const uint32_t psramUsed = psramTotal > freePsram
                                 ? psramTotal - freePsram
                                 : 0U;
  MAPIO_LOG("MAPIO: memory phase=%s freeInternalHeap=%u "
            "largestInternalHeap=%u "
            "freePsram=%u largestPsram=%u psramUsed=%u psramTotal=%u\n",
            phase, (unsigned)freeInternalHeap,
            (unsigned)largestInternalHeap, (unsigned)freePsram,
            (unsigned)largestPsram, (unsigned)psramUsed,
            (unsigned)psramTotal);
#else
  (void)phase;
#endif
}

// The map renderer has exactly one non-LVGL worker.  Rendering helpers use
// this task identity to turn their existing cooperative checkpoints into
// latest-wins cancellation points without changing non-worker callers.
TaskHandle_t gMapRenderWorkerTaskHandle = nullptr;
std::atomic<uint32_t> gMapRenderLatestSequence{0};
std::atomic<uint32_t> gMapRenderActiveSequence{0};
std::atomic<uint32_t> gMapRenderCancellationGeneration{0};
std::atomic<uint32_t> gMapRenderActiveCancellationGeneration{0};
std::atomic<bool> gMapRenderWorkerShutdown{false};
std::atomic<bool> gMapRenderControlOperation{false};
std::atomic<uint32_t> gMapRenderSliceCount{0};
std::atomic<uint32_t> gMapRenderLongestSliceUs{0};
uint32_t gMapRenderLastCheckpointUs = 0;

inline bool onMapRenderWorkerTask() {
  return gMapRenderWorkerTaskHandle != nullptr &&
         xTaskGetCurrentTaskHandle() == gMapRenderWorkerTaskHandle;
}

bool shouldCancelMapRenderWork() {
  if (onMapRenderWorkerTask()) {
    const uint32_t nowUs = micros();
    if (gMapRenderLastCheckpointUs != 0) {
      const uint32_t elapsedUs = nowUs - gMapRenderLastCheckpointUs;
      gMapRenderSliceCount.fetch_add(1, std::memory_order_relaxed);
      uint32_t longest =
          gMapRenderLongestSliceUs.load(std::memory_order_relaxed);
      while (elapsedUs > longest &&
             !gMapRenderLongestSliceUs.compare_exchange_weak(
                 longest, elapsedUs, std::memory_order_relaxed)) {
      }
      if (elapsedUs >= 2000U)
        taskYIELD();
    }
    gMapRenderLastCheckpointUs = micros();
    return map_render_job::shouldCancelWorkerOperation(
        gMapRenderWorkerShutdown.load(std::memory_order_acquire),
        gMapRenderControlOperation.load(std::memory_order_acquire),
        gMapRenderActiveCancellationGeneration.load(
            std::memory_order_acquire),
        gMapRenderCancellationGeneration.load(std::memory_order_acquire));
  }
  return shouldInterruptMapRenderForScreenCycle();
}

constexpr uint16_t rgb565FromRgb888(uint32_t rgb) {
  const uint16_t red = static_cast<uint16_t>((rgb >> 19U) & 0x1FU);
  const uint16_t green = static_cast<uint16_t>((rgb >> 10U) & 0x3FU);
  const uint16_t blue = static_cast<uint16_t>((rgb >> 3U) & 0x1FU);
  return static_cast<uint16_t>((red << 11U) | (green << 5U) | blue);
}

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
    if (shouldCancelMapRenderWork()) {
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

static map_surface::Rgb565Surface rgb565SurfaceForCanvas(lv_obj_t *canvas) {
  if (canvas == nullptr)
    return {};
  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
  if (drawBuffer == nullptr || drawBuffer->data == nullptr ||
      drawBuffer->header.cf != LV_COLOR_FORMAT_RGB565)
    return {};
  return {reinterpret_cast<uint16_t *>(drawBuffer->data),
          static_cast<int32_t>(drawBuffer->header.w),
          static_cast<int32_t>(drawBuffer->header.h),
          static_cast<size_t>(drawBuffer->header.stride / sizeof(uint16_t))};
}

static map_surface::LabelSurface labelSurfaceForCanvas(
    lv_obj_t *canvas, const map_surface::Rgb565Surface *contrast = nullptr,
    int32_t contrastOffsetX = 0, int32_t contrastOffsetY = 0) {
  if (canvas == nullptr)
    return {};
  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvas);
  if (drawBuffer == nullptr || drawBuffer->data == nullptr)
    return {};
  const bool transparent = drawBuffer->header.cf == LV_COLOR_FORMAT_RGB565A8;
  if (!transparent && drawBuffer->header.cf != LV_COLOR_FORMAT_RGB565)
    return {};
  map_surface::LabelSurface surface;
  surface.color = {
      reinterpret_cast<uint16_t *>(drawBuffer->data),
      static_cast<int32_t>(drawBuffer->header.w),
      static_cast<int32_t>(drawBuffer->header.h),
      static_cast<size_t>(drawBuffer->header.stride / sizeof(uint16_t))};
  if (transparent) {
    surface.alpha = static_cast<uint8_t *>(drawBuffer->data) +
                    static_cast<size_t>(drawBuffer->header.stride) *
                        drawBuffer->header.h;
    surface.alphaStrideBytes = drawBuffer->header.stride / sizeof(uint16_t);
  }
  surface.contrast = contrast;
  surface.contrastOffsetX = contrastOffsetX;
  surface.contrastOffsetY = contrastOffsetY;
  return surface;
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

static double currentMarkerRotationDegrees = 0.0;

static lv_point_precise_t rotatedMarkerPoint(const lv_area_t &bounds,
                                             int16_t size,
                                             int16_t baseX, int16_t baseY,
                                             double rotationDegrees) {
  constexpr double kDegreesToRadians =
      3.14159265358979323846 / 180.0;
  const double centerX = bounds.x1 + size / 2.0;
  const double centerY = bounds.y1 + size / 2.0;
  const double x = markerCoord(bounds.x1, size, baseX) - centerX;
  const double y = markerCoord(bounds.y1, size, baseY) - centerY;
  const double angle = rotationDegrees * kDegreesToRadians;
  const double cosine = std::cos(angle);
  const double sine = std::sin(angle);
  // Screen Y grows downward, so this positive-angle matrix rotates the
  // north-facing glyph clockwise: heading 90 points east/right.
  return {static_cast<lv_value_precise_t>(
              std::round(centerX + x * cosine - y * sine)),
          static_cast<lv_value_precise_t>(
              std::round(centerY + x * sine + y * cosine))};
}

static void drawNavigationMarker(lv_layer_t *layer, const lv_area_t &bounds,
                                 int16_t size, lv_color_t color,
                                 double rotationDegrees) {
  // Filled Lucide navigation-2 polygon. Render horizontal spans at the final
  // on-screen size because this target's software renderer does not reliably
  // fill LVGL triangle draw tasks. The rounded outline softens the three outer
  // points without magnifying a bitmap.
  const std::array<lv_point_precise_t, 4> points = {
      rotatedMarkerPoint(bounds, size, 24, 4, rotationDegrees),
      rotatedMarkerPoint(bounds, size, 38, 42, rotationDegrees),
      rotatedMarkerPoint(bounds, size, 24, 34, rotationDegrees),
      rotatedMarkerPoint(bounds, size, 10, 42, rotationDegrees)};

  lv_draw_line_dsc_t fill;
  lv_draw_line_dsc_init(&fill);
  fill.color = color;
  fill.opa = LV_OPA_COVER;
  fill.width = 1;

  lv_value_precise_t minimumY = points.front().y;
  lv_value_precise_t maximumY = points.front().y;
  for (const auto &point : points) {
    minimumY = std::min(minimumY, point.y);
    maximumY = std::max(maximumY, point.y);
  }
  for (lv_value_precise_t y = minimumY; y <= maximumY; ++y) {
    std::array<lv_value_precise_t, 4> intersections{};
    size_t count = 0;
    for (size_t index = 0; index < points.size(); ++index) {
      const auto &start = points[index];
      const auto &end = points[(index + 1U) % points.size()];
      if (!((start.y <= y && end.y > y) ||
            (end.y <= y && start.y > y))) {
        continue;
      }
      intersections[count++] = static_cast<lv_value_precise_t>(std::round(
          start.x + static_cast<double>(end.x - start.x) *
                        static_cast<double>(y - start.y) /
                        static_cast<double>(end.y - start.y)));
    }
    std::sort(intersections.begin(), intersections.begin() + count);
    for (size_t index = 1; index < count; index += 2U) {
      fill.p1 = {intersections[index - 1U], y};
      fill.p2 = {intersections[index], y};
      lv_draw_line(layer, &fill);
    }
  }

  lv_draw_line_dsc_t outline;
  lv_draw_line_dsc_init(&outline);
  outline.color = color;
  outline.opa = LV_OPA_COVER;
  outline.width = std::max<int16_t>(
      1, 3 * size / navigation_visual_style::POSITION_MARKER_BASE_SIZE);
  outline.round_start = 1;
  outline.round_end = 1;

  for (size_t index = 0; index < points.size(); ++index) {
    outline.p1 = points[index];
    outline.p2 = points[(index + 1U) % points.size()];
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

  if (routeOverlay.hasRoute() || hasCurrentNavigationData()) {
    drawNavigationMarker(layer, bounds, size, color,
                         currentMarkerRotationDegrees);
  } else {
    drawPositionDotMarker(layer, bounds, size, color);
  }
}

static void updateCurrentPositionMarker(lv_obj_t *marker,
                                        double rotationDegrees = 0.0,
                                        bool force = false) {
  if (!marker)
    return;

  static bool hasLastShape = false;
  static bool lastWasNavigating = false;
  static uint8_t lastScale = 0;
  static int16_t lastRotationTenths = 0;

  const bool isNavigating =
      routeOverlay.hasRoute() || hasCurrentNavigationData();
  const uint8_t scale = currentMarkerScale();
  const int16_t rotationTenths = static_cast<int16_t>(
      std::round(map_presentation::normalizeDegrees(rotationDegrees) * 10.0));
  if (!force && hasLastShape && lastWasNavigating == isNavigating &&
      lastScale == scale &&
      (!isNavigating || lastRotationTenths == rotationTenths)) {
    return;
  }

  currentMarkerRotationDegrees = rotationTenths / 10.0;
  const int16_t size = currentMarkerSize();
  lv_obj_set_size(marker, size, size);
  lv_obj_invalidate(marker);
  hasLastShape = true;
  lastWasNavigating = isNavigating;
  lastScale = scale;
  lastRotationTenths = rotationTenths;
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
    // The render-ahead presenter owns the image pivot. Resetting it here runs
    // after publication has already installed the live map transform and can
    // leave the settled frame rotating around the top-left corner. Animation
    // completion owns only the temporary scale.
    lv_image_set_scale(canvas, LV_SCALE_NONE);
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
        shouldCancelMapRenderWork()) {
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
      if (shouldCancelMapRenderWork()) {
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

    if (shouldCancelMapRenderWork()) {
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
          shouldCancelMapRenderWork()) {
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
      if (shouldCancelMapRenderWork()) {
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
        if (shouldCancelMapRenderWork()) {
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
      if (shouldCancelMapRenderWork()) {
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
    if ((i & 0x1F) == 0 && shouldCancelMapRenderWork()) {
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
    if ((i & 0x1F) == 0 && shouldCancelMapRenderWork()) {
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
    if (shouldCancelMapRenderWork()) {
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
      if ((i & 0x1F) == 0 && shouldCancelMapRenderWork()) {
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
bool Maps::fillPolygon(const Polygon &p,
                       map_surface::Rgb565Surface surface) {
  if (!surface.valid() || p.points.size() < 2)
    return true;

  int16_t maxY = std::min<int32_t>(p.bbox.max.y, surface.height - 1);
  int16_t minY = std::max<int32_t>(p.bbox.min.y, 0);
  if (minY >= maxY)
    return true;

  std::vector<int16_t, PsramAllocator<int16_t>> nodeX;
  try {
    nodeX.resize(p.points.size());
  } catch (const std::bad_alloc &) {
    return false;
  }

  for (int16_t pixelY = minY; pixelY <= maxY; ++pixelY) {
    if ((pixelY & 0x0F) == 0) {
      if (shouldCancelMapRenderWork())
        return false;
    }
    int16_t nodes = 0;
    for (size_t index = 0; index + 1 < p.points.size(); ++index) {
      const Point16 &start = p.points[index];
      const Point16 &end = p.points[index + 1];
      if ((start.y < pixelY && end.y >= pixelY) ||
          (start.y >= pixelY && end.y < pixelY)) {
        if (nodes >= static_cast<int16_t>(nodeX.size()))
          return false;
        nodeX[nodes++] = static_cast<int16_t>(
            start.x + static_cast<double>(pixelY - start.y) /
                          static_cast<double>(end.y - start.y) *
                          static_cast<double>(end.x - start.x));
      }
    }
    std::sort(nodeX.begin(), nodeX.begin() + nodes);
    uint16_t *row = surface.row(pixelY);
    if (row == nullptr)
      continue;
    for (int16_t index = 0; index + 1 < nodes; index += 2) {
      int32_t startX = std::max<int32_t>(0, nodeX[index]);
      int32_t endX = std::min<int32_t>(surface.width, nodeX[index + 1]);
      if (startX >= endX)
        continue;
      std::fill(row + startX, row + endX, p.color);
    }
  }
  return true;
}

bool Maps::fillPolygon(const Polygon &p, lv_obj_t *canvas) {
  return fillPolygon(p, rgb565SurfaceForCanvas(canvas));
}

void Maps::drawLine(map_surface::Rgb565Surface surface, int16_t x1,
                    int16_t y1, int16_t x2, int16_t y2, uint16_t color,
                    uint8_t width) {
  if (!surface.valid())
    return;
  line_rasterizer::drawFilledLine(surface.pixels, surface.width, surface.height,
                                  surface.stridePixels, x1, y1, x2, y2, color,
                                  width);
}

void Maps::drawLine(lv_obj_t *canvas, int16_t x1, int16_t y1, int16_t x2,
                    int16_t y2, uint16_t color, uint8_t width) {
  drawLine(rgb565SurfaceForCanvas(canvas), x1, y1, x2, y2, color, width);
}

/**
 * @brief Get bounding objects in memory block
 *
 * @param memBlocks
 * @param bbox
 */
bool Maps::getMapBlocks(BBox &bbox, Maps::MemCache &memCache) {
  ESP_LOGI(TAG, "getMapBlocks %i", millis());
  if (shouldCancelMapRenderWork()) {
    return false;
  }
  const uint32_t blocksStartMs = MAPIO_TIME_MS();
  uint16_t cacheHits = 0;
  uint16_t loadedBlocks = 0;
  uint16_t evictedBlocks = 0;
  cachedBlockCount.store(memCache.blocks.size(), std::memory_order_release);
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
    if (shouldCancelMapRenderWork()) {
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
          cachedBlockCount.store(memCache.blocks.size(),
                                 std::memory_order_release);
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
        cachedBlockCount.store(memCache.blocks.size(),
                               std::memory_order_release);
        evictedBlocks++;
      }
    }

    MapBlock *newBlock = Maps::readMapBlock(fileName);
    if (Maps::isMapFound.load(std::memory_order_acquire)) {
      newBlock->inView = true;
      newBlock->offset = req;
      newBlock->mercatorScale = map_projection::mercatorScaleForLatitude(
          Maps::mercatorY2lat(static_cast<double>(req.y) +
                              (1 << (MAPBLOCK_SIZE_BITS - 1))));
      memCache.blocks.push_back(newBlock);
      cachedBlockCount.store(memCache.blocks.size(),
                             std::memory_order_release);
      loadedBlocks++;

      ESP_LOGI(TAG, "Block loaded: %p, offset(%d, %d)", newBlock, req.x, req.y);
      ESP_LOGI(TAG, "FreeHeap: %d", (int)esp_get_free_heap_size());
    } else {
      delete newBlock;
    }

    if (shouldCancelMapRenderWork()) {
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
  cachedBlockCount.store(memCache.blocks.size(), std::memory_order_release);

  ESP_LOGI(TAG, "memCache size: %i %i", memCache.blocks.size(), millis());
  MAPIO_LOG("MAPIO: blocks required=%u cacheHit=%u loaded=%u evicted=%u "
            "cache=%u elapsedMs=%lu\n",
            (unsigned)requiredOffsets.size(), (unsigned)cacheHits,
            (unsigned)loadedBlocks, (unsigned)evictedBlocks,
            (unsigned)memCache.blocks.size(),
            (unsigned long)(MAPIO_TIME_MS() - blocksStartMs));
  logMapMemorySnapshot("block-cache");
  return true;
}

bool Maps::drawStreetLabels(ViewPort &viewPort, MemCache &memCache,
                            map_surface::LabelSurface surface, uint8_t zoom,
                            double rotation, const RenderContext &context) {
  const ScreenMapRenderSettings &style = context.style;
  if (style.labelDensity == 0 || !labelFontAsset.healthy())
    return true;
  const uint32_t labelStartMs = MAPIO_TIME_MS();
  const uint32_t cacheHitsBefore = labelFontAsset.cacheHits();
  const uint32_t cacheMissesBefore = labelFontAsset.cacheMisses();
  const uint32_t cacheEvictionsBefore = labelFontAsset.cacheEvictions();
  size_t peakDecodedLabelBytes = 0;
  if (!surface.valid())
    return true;
  const bool transparentSurface = surface.transparent();
  const int32_t screenWidth = surface.color.width;
  const int32_t screenHeight = surface.color.height;
  const int16_t screenAnchorX = mapAnchorXForWidth(screenWidth);
  const int16_t screenAnchorY = mapAnchorYForHeight(screenHeight);
  float markerX = screenAnchorX;
  float markerY = screenAnchorY;
  bool markerVisible = false;
  if (context.showCurrentPosition) {
    if (!context.followPosition) {
      const auto markerDelta = map_transform::worldToScreen(
          {context.measuredGpsWorld.x - viewPort.center.x,
           context.measuredGpsWorld.y - viewPort.center.y},
          zoom, rotation);
      markerX += markerDelta.x;
      markerY += markerDelta.y;
    }
    const float markerHalf =
        navigation_visual_style::POSITION_MARKER_BASE_SIZE *
        std::max<uint8_t>(1, context.markerScale) * 0.5F;
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
  const bool guidance = context.guidanceScreenActive;
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
            shouldCancelMapRenderWork())
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
    const float markerSize = static_cast<float>(
        navigation_visual_style::POSITION_MARKER_BASE_SIZE *
        std::max<uint8_t>(1, context.markerScale));
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

  uint16_t *pixels = surface.color.pixels;
  const uint32_t stride = surface.color.stridePixels;
  uint8_t *alphaPixels = transparentSurface ? surface.alpha : nullptr;
  const uint32_t alphaStride =
      transparentSurface ? surface.alphaStrideBytes : 0U;
  const map_surface::Rgb565Surface *contrastSurface = surface.contrast;
  const int32_t contrastOffsetX = surface.contrastOffsetX;
  const int32_t contrastOffsetY = surface.contrastOffsetY;
  for (const auto &placement : placements) {
    if (shouldCancelMapRenderWork())
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
    } else if (contrastSurface != nullptr && contrastSurface->valid()) {
      const int32_t contrastX = centerX + contrastOffsetX;
      const int32_t contrastY = centerY + contrastOffsetY;
      if (contrastSurface->contains(contrastX, contrastY)) {
        background = contrastSurface->pixels[
            static_cast<size_t>(contrastY) * contrastSurface->stridePixels +
            static_cast<size_t>(contrastX)];
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
              streetLabelFontHealthy.store(false, std::memory_order_release);
              streetLabelRuntimeFailure.store(labelFontAsset.runtimeError(),
                                              std::memory_order_release);
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
                        shouldCancelMapRenderWork)
                  : map_label_rasterizer::drawGlyphPass(
                        pixels, screenWidth, screenHeight, stride, bitmap.fill,
                        bitmap.distance, bitmap.width, bitmap.height,
                        glyphX26_6, glyphY26_6, transform, pass, fillColor,
                        haloColor, shouldCancelMapRenderWork);
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

bool Maps::drawStreetLabels(ViewPort &viewPort, MemCache &memCache,
                            lv_obj_t *canvas, uint8_t zoom, double rotation,
                            const ScreenMapRenderSettings &style) {
  RenderContext context = captureRenderContext();
  context.style = style;
  map_surface::Rgb565Surface contrast{};
  int32_t offsetX = 0;
  int32_t offsetY = 0;
  if (canvas != nullptr && canvasMap != nullptr) {
    contrast = rgb565SurfaceForCanvas(canvasMap);
    offsetX = lv_obj_get_x_aligned(canvas) - lv_obj_get_x_aligned(canvasMap);
    offsetY = lv_obj_get_y_aligned(canvas) - lv_obj_get_y_aligned(canvasMap);
  }
  const map_surface::Rgb565Surface *contrastPtr =
      contrast.valid() ? &contrast : nullptr;
  return drawStreetLabels(
      viewPort, memCache,
      labelSurfaceForCanvas(canvas, contrastPtr, offsetX, offsetY), zoom,
      rotation, context);
}




/**
 * @brief Generate vectorized map
 *
 * @param viewPort
 * @param memblocks
 * @param map -> Map Sprite
 * @param zoom -> Zoom Level
 */
bool Maps::readVectorMap(
    ViewPort &viewPort, MemCache &memCache,
    map_surface::Rgb565Surface surface, uint8_t zoom, double rotation,
    const map_projection::Projection &projection, const RenderContext &context,
    bool drawLabels, bool suppressBuildings,
    RasterDiagnostics *diagnostics) {
  if (diagnostics != nullptr)
    *diagnostics = {};
  if (!surface.valid())
    return false;

  const ScreenMapRenderSettings &style = context.style;
  const bool mapNavigationActive = context.guidanceScreenActive;
  const uint32_t drawStartMs = MAPIO_TIME_MS();
  surface.clear(BACKGROUND_COLOR);

  if (!Maps::isMapFound.load(std::memory_order_acquire) ||
      memCache.blocks.empty()) {
    MAPIO_LOG("MAPIO: raw-map ok=1 mapFound=0 blocks=%u totalMs=%lu\n",
              (unsigned)memCache.blocks.size(),
              (unsigned long)(MAPIO_TIME_MS() - drawStartMs));
    return true;
  }

  Polygon projectedPolygon;
  std::vector<map_projection::GroundPoint> groundPolygon;
  std::vector<map_projection::GroundPoint> clippedGroundPolygon;
  uint32_t projectionClippedCount = 0;
  uint32_t projectionRejectedCount = 0;

  for (MapBlock *block : memCache.blocks) {
    if (shouldCancelMapRenderWork())
      return false;
    if (block == nullptr || !block->inView)
      continue;

    ScreenMapRenderSettings blockStyle = style;
    blockStyle.visibilityMask =
        map_profile_protocol::visibilityMaskForMapVersion(
            style.visibilityMask, block->formatVersion);
    const BBox localViewport = viewPort.bbox - block->offset;
    const auto worldPoint = [&](Point16 point) -> map_transform::WorldPoint {
      return {static_cast<double>(point.x) + block->offset.x,
              static_cast<double>(point.y) + block->offset.y};
    };

    const size_t polygonCount = block->polygons.size();
    std::vector<bool> visited(polygonCount, false);
    const int minCellX =
        std::max(0, static_cast<int>(localViewport.min.x >> CELL_SHIFT));
    const int maxCellX = std::min(
        GRID_SIZE - 1,
        static_cast<int>(localViewport.max.x >> CELL_SHIFT));
    const int minCellY =
        std::max(0, static_cast<int>(localViewport.min.y >> CELL_SHIFT));
    const int maxCellY = std::min(
        GRID_SIZE - 1,
        static_cast<int>(localViewport.max.y >> CELL_SHIFT));
    size_t polygonChecks = 0;

    const auto drawPolygonRecord = [&](size_t polygonIndex) -> bool {
      if (polygonIndex >= polygonCount || visited[polygonIndex])
        return true;
      visited[polygonIndex] = true;
      if ((polygonChecks++ & 0x0fU) == 0 && shouldCancelMapRenderWork())
        return false;
      const Polygon &polygon = block->polygons[polygonIndex];
      if (zoom > polygon.maxZoom || !polygon.bbox.intersects(localViewport) ||
          !isPolygonVisible(polygon.typeId, polygon.color, blockStyle)) {
        return true;
      }

      groundPolygon.clear();
      groundPolygon.reserve(polygon.points.size());
      for (size_t pointIndex = 0; pointIndex < polygon.points.size();
           ++pointIndex) {
        if ((pointIndex & 0x1fU) == 0 && shouldCancelMapRenderWork())
          return false;
        groundPolygon.push_back(
            projection.groundForWorld(worldPoint(polygon.points[pointIndex])));
      }
      const auto *projectedGround = &groundPolygon;
      if (projection.isBirdsEye()) {
        map_projection::clipPolygonToNearPlane(
            projection, groundPolygon, clippedGroundPolygon);
        projectedGround = &clippedGroundPolygon;
        if (clippedGroundPolygon.size() != groundPolygon.size())
          ++projectionClippedCount;
      }
      if (projectedGround->size() < 3) {
        ++projectionRejectedCount;
        return true;
      }

      projectedPolygon.points.clear();
      projectedPolygon.points.reserve(projectedGround->size() + 1U);
      projectedPolygon.color = polygon.color;
      int16_t minX = 32767;
      int16_t minY = 32767;
      int16_t maxX = -32768;
      int16_t maxY = -32768;
      for (const auto &ground : *projectedGround) {
        const auto projected = projection.projectGround(ground);
        if (!projected.valid)
          continue;
        const Point16 point(
            static_cast<int16_t>(map_transform::quantizePixel(projected.x)),
            static_cast<int16_t>(map_transform::quantizePixel(projected.y)));
        projectedPolygon.points.push_back(point);
        minX = std::min(minX, point.x);
        minY = std::min(minY, point.y);
        maxX = std::max(maxX, point.x);
        maxY = std::max(maxY, point.y);
      }
      if (projectedPolygon.points.size() < 3)
        return true;
      if (!(projectedPolygon.points.front().x ==
                projectedPolygon.points.back().x &&
            projectedPolygon.points.front().y ==
                projectedPolygon.points.back().y)) {
        projectedPolygon.points.push_back(projectedPolygon.points.front());
      }
      projectedPolygon.bbox.min = Point16(minX, minY);
      projectedPolygon.bbox.max = Point16(maxX, maxY);
      const uint8_t minimumSize = effectiveMinPolygonSize(blockStyle);
      const int32_t area = static_cast<int32_t>(maxX - minX) *
                           static_cast<int32_t>(maxY - minY);
      if (minimumSize != 0 &&
          area < static_cast<int32_t>(minimumSize) * minimumSize) {
        return true;
      }
      return fillPolygon(projectedPolygon, surface);
    };

    if (!block->polygonGrid.empty()) {
      for (int cellY = minCellY; cellY <= maxCellY; ++cellY) {
        for (int cellX = minCellX; cellX <= maxCellX; ++cellX) {
          const int cellIndex = cellY * GRID_SIZE + cellX;
          if (cellIndex < 0 ||
              cellIndex >= static_cast<int>(block->polygonGrid.size())) {
            continue;
          }
          for (const uint16_t polygonIndex : block->polygonGrid[cellIndex]) {
            if (!drawPolygonRecord(polygonIndex))
              return false;
          }
        }
      }
    } else {
      for (size_t polygonIndex = 0; polygonIndex < polygonCount;
           ++polygonIndex) {
        if (!drawPolygonRecord(polygonIndex))
          return false;
      }
    }

    for (const Polyline &line : block->polylines) {
      if (shouldCancelMapRenderWork())
        return false;
      if (zoom > line.maxZoom || line.points.size() < 2 ||
          !line.bbox.intersects(localViewport) ||
          !isLineVisible(line.typeId, line.color, line.width, blockStyle)) {
        continue;
      }
      const uint16_t displayColor = map_line_style::displayColor(
          line.typeId, line.color, line.width, mapNavigationActive);
      const uint8_t baseWidth =
          shouldBoostLineWidth(line.typeId, line.width)
              ? blockStyle.streetLineWidth
              : static_cast<uint8_t>(std::max<int32_t>(line.width, 1));
      for (size_t index = 0; index + 1 < line.points.size(); ++index) {
        if ((index & 0x0fU) == 0 && shouldCancelMapRenderWork())
          return false;
        auto start = projection.groundForWorld(worldPoint(line.points[index]));
        auto end =
            projection.groundForWorld(worldPoint(line.points[index + 1]));
        if (!projection.clipSegmentToNearPlane(start, end)) {
          ++projectionRejectedCount;
          continue;
        }
        const auto projectedStart = projection.projectGround(start);
        const auto projectedEnd = projection.projectGround(end);
        if (!projectedStart.valid || !projectedEnd.valid) {
          ++projectionRejectedCount;
          continue;
        }
        const uint8_t width = projection.scaledLineWidth(
            baseWidth,
            (projectedStart.depthScale + projectedEnd.depthScale) * 0.5, 24);
        drawLine(
            surface,
            static_cast<int16_t>(
                map_transform::quantizePixel(projectedStart.x)),
            static_cast<int16_t>(
                map_transform::quantizePixel(projectedStart.y)),
            static_cast<int16_t>(map_transform::quantizePixel(projectedEnd.x)),
            static_cast<int16_t>(map_transform::quantizePixel(projectedEnd.y)),
            displayColor, width);
      }
    }
  }

  struct BuildingItem {
    MapBlock *block = nullptr;
    const map_building_block::Building *building = nullptr;
    uint16_t recordIndex = 0;
    double painterDepth = 0.0;
    bool extruded = false;
  };
  map_building_admission::Diagnostics admissionDiagnostics{};
  uint32_t candidateBuildings = 0;
  uint32_t renderedBuildings = 0;
  uint32_t oversizedBuildings = 0;
  uint32_t extrudedP90DistancePx = 0;
  uint32_t extrudedFarthestDistancePx = 0;
  uint32_t courtyardDeferred = 0;
  uint32_t buildingProjectionMs = 0;
  uint32_t buildingDrawMs = 0;
  uint32_t metadataDeferredBuildings = 0;
  bool buildingAllocationFailed = false;
  uint32_t courtyardSnapshotCount = 0;
  size_t largestCourtyardBytes = 0;
  uint32_t buildingFailureInternalHeapFree = 0;
  uint32_t buildingFailureInternalHeapLargest = 0;
  uint32_t buildingFailurePsramFree = 0;
  uint32_t buildingFailurePsramLargest = 0;

  uint64_t buildingContextSignature = 1469598103934665603ULL;
  const auto mixBuildingContext = [&](uint64_t value) {
    buildingContextSignature ^= value;
    buildingContextSignature *= 1099511628211ULL;
  };
  mixBuildingContext(zoom);
  mixBuildingContext(projection.isBirdsEye() ? 1U : 0U);
  mixBuildingContext(style.visibilityMask);
  mixBuildingContext(context.buildings3DEnabled ? 1U : 0U);
  mixBuildingContext(context.birdsEyePerspective);
  const map_building_renderer::RenderRegion buildingRenderRegion{
      viewPort.bbox.min.x, viewPort.bbox.min.y, viewPort.bbox.max.x,
      viewPort.bbox.max.y};
  const bool flatFallbackOnly =
      suppressBuildings || buildingFailureRetryCooldown.shouldSuppress(
                               millis(), buildingContextSignature,
                               buildingRenderRegion);
  const bool buildingsVisible =
      (style.visibilityMask & MAP_VISIBILITY_BUILDINGS) != 0;
  const bool extrusionRequested =
      !flatFallbackOnly &&
      navigation_content_mode::extrudesMapGuidanceBuildings(
          buildingsVisible, context.guidanceScreenActive,
          projection.isBirdsEye(),
          context.buildings3DEnabled);

  if (buildingsVisible) {
    if (flatFallbackOnly) {
      // FMB v4 removes extrudable buildings from the generic polygon stream,
      // so suppressing the 3D pass must not suppress every building.  This
      // exceptional path keeps a small deterministic nearest set of flat
      // footprints without allocating the normal candidate/sort workspace.
      // It intentionally omits courtyard restoration if memory is already in
      // a failed/cooldown state; preserving a useful flat city is preferable
      // to recursively failing or publishing a building-free frame.
      constexpr size_t kFallbackCandidateLimit = 48;
      constexpr size_t kFallbackPointLimit = 4096;
      constexpr uint64_t kFallbackPixelLimit = 120000;
      std::array<map_building_admission::Candidate,
                 kFallbackCandidateLimit>
          fallbackCandidates{};
      size_t fallbackCandidateCount = 0;
      size_t fallbackVisible = 0;

      const auto retainFallbackCandidate =
          [&](const map_building_admission::Candidate &candidate) {
            if (fallbackCandidateCount < kFallbackCandidateLimit) {
              fallbackCandidates[fallbackCandidateCount++] = candidate;
              return;
            }
            size_t farthest = 0;
            for (size_t index = 1; index < fallbackCandidateCount; ++index) {
              if (map_building_admission::nearer(
                      fallbackCandidates[farthest].key,
                      fallbackCandidates[index].key)) {
                farthest = index;
              }
            }
            if (map_building_admission::nearer(
                    candidate.key, fallbackCandidates[farthest].key)) {
              fallbackCandidates[farthest] = candidate;
            }
          };

      for (MapBlock *block : memCache.blocks) {
        if (shouldCancelMapRenderWork())
          return false;
        if (block == nullptr || !block->inView || block->formatVersion < 4)
          continue;
        const BBox localViewport = viewPort.bbox - block->offset;
        for (size_t recordIndex = 0;
             recordIndex < block->buildingData.buildings.size();
             ++recordIndex) {
          if ((recordIndex & 0x1fU) == 0 && shouldCancelMapRenderWork())
            return false;
          const auto &building = block->buildingData.buildings[recordIndex];
          const BBox bounds(Point32(building.minX, building.minY),
                            Point32(building.maxX, building.maxY));
          if (!bounds.intersects(localViewport))
            continue;
          size_t pointCount = 0;
          for (const auto &ring : building.rings)
            pointCount += ring.points.size();
          if (pointCount < 3 ||
              pointCount >
                  map_building_renderer::kMaximumRenderedBuildingPointsPerRecord) {
            ++oversizedBuildings;
            continue;
          }

          const double centerX = static_cast<double>(block->offset.x) +
                                 (building.minX + building.maxX) * 0.5;
          const double centerY = static_cast<double>(block->offset.y) +
                                 (building.minY + building.maxY) * 0.5;
          const double dx = centerX - context.presentedWorld.x;
          const double dy = centerY - context.presentedWorld.y;

          double minX = std::numeric_limits<double>::infinity();
          double minY = std::numeric_limits<double>::infinity();
          double maxX = -std::numeric_limits<double>::infinity();
          double maxY = -std::numeric_limits<double>::infinity();
          const std::array<map_transform::WorldPoint, 4> corners{{
              {static_cast<double>(block->offset.x + building.minX),
               static_cast<double>(block->offset.y + building.minY)},
              {static_cast<double>(block->offset.x + building.maxX),
               static_cast<double>(block->offset.y + building.minY)},
              {static_cast<double>(block->offset.x + building.maxX),
               static_cast<double>(block->offset.y + building.maxY)},
              {static_cast<double>(block->offset.x + building.minX),
               static_cast<double>(block->offset.y + building.maxY)},
          }};
          size_t validCorners = 0;
          for (const auto &corner : corners) {
            const auto projected = projection.projectWorld(corner);
            if (!projected.valid)
              continue;
            ++validCorners;
            minX = std::min(minX, projected.x);
            minY = std::min(minY, projected.y);
            maxX = std::max(maxX, projected.x);
            maxY = std::max(maxY, projected.y);
          }
          if (validCorners < 2)
            continue;
          const uint64_t projectedPixels = static_cast<uint64_t>(std::max(
              1.0, std::ceil(std::max(0.0, maxX - minX) *
                             std::max(0.0, maxY - minY))));
          map_building_admission::Candidate candidate;
          candidate.key = {dx * dx + dy * dy, block->offset.x,
                           block->offset.y,
                           static_cast<uint32_t>(recordIndex)};
          candidate.pointCount = pointCount;
          candidate.projectedPixels = projectedPixels;
          retainFallbackCandidate(candidate);
          ++fallbackVisible;
        }
      }

      std::sort(fallbackCandidates.begin(),
                fallbackCandidates.begin() + fallbackCandidateCount,
                [](const auto &left, const auto &right) {
                  return map_building_admission::nearer(left.key, right.key);
                });

      const auto rgb565 = [](uint32_t rgb) -> uint16_t {
        return static_cast<uint16_t>(((rgb >> 8U) & 0xf800U) |
                                     ((rgb >> 5U) & 0x07e0U) |
                                     ((rgb >> 3U) & 0x001fU));
      };
      const uint16_t roofColor = rgb565(0xB9B2A8);
      size_t selectedRecords = 0;
      size_t selectedPoints = 0;
      uint64_t selectedPixels = 0;
      Polygon buildingPolygon;
      std::vector<Point16, PsramAllocator<Point16>> screenPoints;
      map_building_renderer::SurfaceStats fallbackSurfaceStats{};
      for (size_t candidateIndex = 0;
           candidateIndex < fallbackCandidateCount; ++candidateIndex) {
        if (shouldCancelMapRenderWork())
          return false;
        const auto &candidate = fallbackCandidates[candidateIndex];
        if (candidate.pointCount > kFallbackPointLimit - selectedPoints ||
            candidate.projectedPixels >
                kFallbackPixelLimit - selectedPixels) {
          continue;
        }
        MapBlock *block = nullptr;
        for (MapBlock *item : memCache.blocks) {
          if (item != nullptr && item->offset.x == candidate.key.blockX &&
              item->offset.y == candidate.key.blockY) {
            block = item;
            break;
          }
        }
        if (block == nullptr ||
            candidate.key.recordIndex >=
                block->buildingData.buildings.size()) {
          continue;
        }
        const auto &building =
            block->buildingData.buildings[candidate.key.recordIndex];
        bool rendered = false;
        bool drewFootprint = false;
        try {
          rendered = map_building_renderer::renderSurfaces(
              building, block->offset.x, block->offset.y,
              block->mercatorScale, projection, false,
              [&](map_building_renderer::Surface kind,
                  const auto &points) -> bool {
                if (shouldCancelMapRenderWork())
                  return false;
                if (kind != map_building_renderer::Surface::Roof ||
                    points.size() < 3) {
                  return true;
                }
                screenPoints.clear();
                screenPoints.reserve(points.size() + 1U);
                int16_t polygonMinX = 32767;
                int16_t polygonMinY = 32767;
                int16_t polygonMaxX = -32768;
                int16_t polygonMaxY = -32768;
                for (const auto &point : points) {
                  const Point16 converted(static_cast<int16_t>(point.x),
                                          static_cast<int16_t>(point.y));
                  screenPoints.push_back(converted);
                  polygonMinX = std::min(polygonMinX, converted.x);
                  polygonMinY = std::min(polygonMinY, converted.y);
                  polygonMaxX = std::max(polygonMaxX, converted.x);
                  polygonMaxY = std::max(polygonMaxY, converted.y);
                }
                screenPoints.push_back(screenPoints.front());
                buildingPolygon.points = screenPoints;
                buildingPolygon.color = roofColor;
                buildingPolygon.bbox.min = Point16(polygonMinX, polygonMinY);
                buildingPolygon.bbox.max = Point16(polygonMaxX, polygonMaxY);
                // A false result can mean cancellation or a small workspace
                // allocation failure. Cancellation aborts the job; otherwise
                // skip this footprint and preserve the rest of the flat city.
                const bool filled = fillPolygon(buildingPolygon, surface);
                drewFootprint = drewFootprint || filled;
                return filled || !shouldCancelMapRenderWork();
              },
              &fallbackSurfaceStats, shouldCancelMapRenderWork);
        } catch (const std::bad_alloc &) {
          rendered = false;
        }
        if (!rendered && shouldCancelMapRenderWork())
          return false;
        if (!rendered || !drewFootprint)
          continue;
        ++selectedRecords;
        selectedPoints += candidate.pointCount;
        selectedPixels += candidate.projectedPixels;
      }
      admissionDiagnostics.candidates = fallbackVisible;
      candidateBuildings = static_cast<uint32_t>(fallbackVisible);
      admissionDiagnostics.selected = selectedRecords;
      admissionDiagnostics.flat = selectedRecords;
      admissionDiagnostics.deferred = fallbackVisible - selectedRecords;
      admissionDiagnostics.selectedPoints = selectedPoints;
      admissionDiagnostics.selectedPixels = selectedPixels;
      MAPIO_LOG(
          "MAPIO: buildings fallback=flat candidates=%u retained=%u "
          "selected=%u deferred=%u points=%u pixels=%llu\n",
          (unsigned)fallbackVisible, (unsigned)fallbackCandidateCount,
          (unsigned)selectedRecords,
          (unsigned)(fallbackVisible - selectedRecords),
          (unsigned)selectedPoints,
          (unsigned long long)selectedPixels);
    } else {
    try {
      const uint32_t projectionStartMs = millis();
      // Candidate metadata is bounded independently of scene density and kept
      // in PSRAM. Selection still visits every visible FMB v4 record and
      // retains the globally nearest set, so cache/block iteration order cannot
      // change which buildings survive.
      constexpr size_t kMaximumCandidateMetadata = 384;
      std::vector<map_building_admission::Candidate,
                  PsramAllocator<map_building_admission::Candidate>>
          candidates;
      candidates.reserve(kMaximumCandidateMetadata);
      uint32_t visibleRecords = 0;

      for (MapBlock *block : memCache.blocks) {
        if (shouldCancelMapRenderWork())
          return false;
        if (block == nullptr || !block->inView || block->formatVersion < 4)
          continue;
        const BBox localViewport = viewPort.bbox - block->offset;
        for (size_t recordIndex = 0;
             recordIndex < block->buildingData.buildings.size();
             ++recordIndex) {
          if ((recordIndex & 0x1fU) == 0 && shouldCancelMapRenderWork())
            return false;
          const auto &building = block->buildingData.buildings[recordIndex];
          const bool mayExtrude =
              extrusionRequested && map_building_renderer::usesExtrusion(
                                        true, building.flags);
          const int32_t heightMargin = mayExtrude
              ? static_cast<int32_t>(std::ceil(
                    building.heightDm / 10.0 * block->mercatorScale))
              : 0;
          const BBox bounds(
              Point32(building.minX - heightMargin,
                      building.minY - heightMargin),
              Point32(building.maxX + heightMargin,
                      building.maxY + heightMargin));
          if (!bounds.intersects(localViewport))
            continue;

          size_t pointCount = 0;
          for (const auto &ring : building.rings)
            pointCount += ring.points.size();
          if (pointCount < 3 ||
              pointCount >
                  map_building_renderer::kMaximumRenderedBuildingPointsPerRecord) {
            ++oversizedBuildings;
            continue;
          }
          // Discovery must stay independent of ring complexity. FMB v4
          // already carries validated record bounds, so use their projected
          // screen extent for the global nearest prepass and reserve exact
          // ring projection for the bounded retained set below.
          double projectedMinX = std::numeric_limits<double>::infinity();
          double projectedMinY = std::numeric_limits<double>::infinity();
          double projectedMaxX = -std::numeric_limits<double>::infinity();
          double projectedMaxY = -std::numeric_limits<double>::infinity();
          const std::array<map_transform::WorldPoint, 4> corners{{
              {static_cast<double>(block->offset.x + building.minX),
               static_cast<double>(block->offset.y + building.minY)},
              {static_cast<double>(block->offset.x + building.maxX),
               static_cast<double>(block->offset.y + building.minY)},
              {static_cast<double>(block->offset.x + building.maxX),
               static_cast<double>(block->offset.y + building.maxY)},
              {static_cast<double>(block->offset.x + building.minX),
               static_cast<double>(block->offset.y + building.maxY)},
          }};
          size_t validCorners = 0;
          for (const auto &corner : corners) {
            const auto projected = projection.projectWorld(corner);
            if (!projected.valid)
              continue;
            ++validCorners;
            projectedMinX = std::min(projectedMinX, projected.x);
            projectedMinY = std::min(projectedMinY, projected.y);
            projectedMaxX = std::max(projectedMaxX, projected.x);
            projectedMaxY = std::max(projectedMaxY, projected.y);
          }
          if (validCorners < 2)
            continue;
          const double projectedArea =
              std::max(1.0, std::ceil(
                                std::max(0.0, projectedMaxX - projectedMinX) *
                                std::max(0.0, projectedMaxY - projectedMinY)));

          ++visibleRecords;
          const double centerX = static_cast<double>(block->offset.x) +
                                 (building.minX + building.maxX) * 0.5;
          const double centerY = static_cast<double>(block->offset.y) +
                                 (building.minY + building.maxY) * 0.5;
          const double dx = centerX - context.presentedWorld.x;
          const double dy = centerY - context.presentedWorld.y;
          map_building_admission::Candidate candidate;
          candidate.key = {dx * dx + dy * dy, block->offset.x,
                           block->offset.y,
                           static_cast<uint32_t>(recordIndex)};
          candidate.pointCount = pointCount;
          candidate.projectedPixels = static_cast<uint64_t>(
              std::max(1.0, std::ceil(projectedArea)));
          candidate.extrusionEligible =
              mayExtrude &&
              map_building_renderer::eligibleExtrusionZoom(zoom) &&
              projectedArea >=
                  context.tuning.minimumExtrusionAreaPixels;
          map_building_admission::retainNearest(
              candidates, candidate, kMaximumCandidateMetadata);
        }
      }
      buildingProjectionMs = millis() - projectionStartMs;

      // Exact ring projection is deliberately after nearest retention. At
      // most kMaximumCandidateMetadata records can reach this phase, no matter
      // how many building records intersect the loaded blocks.
      MapBuildingVector<map_projection::GroundPoint> areaGround;
      MapBuildingVector<map_projection::GroundPoint> areaClipped;
      size_t usefulCandidateCount = 0;
      for (size_t candidateIndex = 0; candidateIndex < candidates.size();
           ++candidateIndex) {
        if (shouldCancelMapRenderWork())
          return false;
        auto candidate = candidates[candidateIndex];
        MapBlock *candidateBlock = nullptr;
        for (MapBlock *block : memCache.blocks) {
          if (block != nullptr && block->offset.x == candidate.key.blockX &&
              block->offset.y == candidate.key.blockY) {
            candidateBlock = block;
            break;
          }
        }
        if (candidateBlock == nullptr ||
            candidate.key.recordIndex >=
                candidateBlock->buildingData.buildings.size()) {
          continue;
        }
        const auto &building = candidateBlock->buildingData.buildings[
            candidate.key.recordIndex];
        const double projectedArea =
            map_building_renderer::projectedFootprintAreaPixels(
                building, candidateBlock->offset.x, candidateBlock->offset.y,
                projection, areaGround, areaClipped,
                shouldCancelMapRenderWork);
        if (shouldCancelMapRenderWork())
          return false;
        if (!(projectedArea > 0.0))
          continue;
        candidate.projectedPixels = static_cast<uint64_t>(
            std::max(1.0, std::ceil(projectedArea)));
        candidate.extrusionEligible =
            extrusionRequested &&
            map_building_renderer::usesExtrusion(true, building.flags) &&
            map_building_renderer::eligibleExtrusionZoom(zoom) &&
            projectedArea >=
                context.tuning.minimumExtrusionAreaPixels;
        candidates[usefulCandidateCount++] = candidate;
      }
      candidates.resize(usefulCandidateCount);
      buildingProjectionMs = millis() - projectionStartMs;

      std::sort(candidates.begin(), candidates.end(),
                [](const auto &left, const auto &right) {
                  return map_building_admission::nearer(left.key, right.key);
                });
      for (size_t index = 0; index < candidates.size(); ++index)
        candidates[index].sourceIndex = index;

      // The profile is copied into the immutable render request. A debug
      // session can therefore cancel and replace a job between bounded units,
      // but can never change its admission limits halfway through a pass.
      const map_building_admission::Quotas &quotas = context.tuning.buildings;
      const auto decisions = map_building_admission::select(
          candidates, quotas, &admissionDiagnostics);
      candidateBuildings = visibleRecords;
      const size_t metadataDeferred =
          visibleRecords > candidates.size() ? visibleRecords - candidates.size()
                                             : 0U;
      metadataDeferredBuildings = static_cast<uint32_t>(metadataDeferred);
      std::vector<uint8_t> admission(candidates.size(), 0);
#if FIRMWARE_DIAGNOSTICS
      std::array<uint32_t, 96> extrudedDistancesPx{};
      size_t extrudedDistanceCount = 0;
#endif
      for (const auto &decision : decisions) {
        if (decision.sourceIndex >= admission.size())
          continue;
        admission[decision.sourceIndex] =
            decision.admitted ? (decision.extruded ? 2U : 1U) : 0U;
#if FIRMWARE_DIAGNOSTICS
        if (decision.extruded &&
            extrudedDistanceCount < extrudedDistancesPx.size()) {
          const double distancePx =
              std::sqrt(candidates[decision.sourceIndex].key.distanceSquared) *
              map_transform::worldToScreenScale(zoom);
          extrudedDistancesPx[extrudedDistanceCount++] =
              static_cast<uint32_t>(std::max(0.0, std::round(distancePx)));
        }
#endif
      }
#if FIRMWARE_DIAGNOSTICS
      if (extrudedDistanceCount != 0) {
        std::sort(extrudedDistancesPx.begin(),
                  extrudedDistancesPx.begin() + extrudedDistanceCount);
        const size_t p90Index =
            (extrudedDistanceCount * 90U + 99U) / 100U - 1U;
        extrudedP90DistancePx = extrudedDistancesPx[p90Index];
        extrudedFarthestDistancePx =
            extrudedDistancesPx[extrudedDistanceCount - 1U];
      }
#endif

      std::vector<BuildingItem, PsramAllocator<BuildingItem>> items;
      items.reserve(admissionDiagnostics.selected);
      for (size_t candidateIndex = 0; candidateIndex < candidates.size();
           ++candidateIndex) {
        if (admission[candidateIndex] == 0)
          continue;
        const auto &candidate = candidates[candidateIndex];
        MapBlock *selectedBlock = nullptr;
        for (MapBlock *block : memCache.blocks) {
          if (block != nullptr && block->offset.x == candidate.key.blockX &&
              block->offset.y == candidate.key.blockY) {
            selectedBlock = block;
            break;
          }
        }
        if (selectedBlock == nullptr ||
            candidate.key.recordIndex >=
                selectedBlock->buildingData.buildings.size()) {
          continue;
        }
        const auto &building = selectedBlock->buildingData.buildings[
            candidate.key.recordIndex];
        const map_transform::WorldPoint center{
            static_cast<double>(selectedBlock->offset.x) +
                (building.minX + building.maxX) * 0.5,
            static_cast<double>(selectedBlock->offset.y) +
                (building.minY + building.maxY) * 0.5};
        items.push_back({selectedBlock, &building,
                         static_cast<uint16_t>(candidate.key.recordIndex),
                         projection.groundForWorld(center).forward,
                         admission[candidateIndex] == 2U});
      }
      std::sort(items.begin(), items.end(),
                [](const BuildingItem &left, const BuildingItem &right) {
                  return map_building_renderer::rendersBefore(
                      {left.painterDepth, left.block->offset.x,
                       left.block->offset.y, left.recordIndex},
                      {right.painterDepth, right.block->offset.x,
                       right.block->offset.y, right.recordIndex});
                });

      const auto rgb565 = [](uint32_t rgb) -> uint16_t {
        return static_cast<uint16_t>(((rgb >> 8U) & 0xf800U) |
                                     ((rgb >> 5U) & 0x07e0U) |
                                     ((rgb >> 3U) & 0x001fU));
      };
      const uint16_t roofColor = rgb565(0xB9B2A8);
      const uint16_t wallLight = rgb565(0x958E84);
      const uint16_t wallMiddle = rgb565(0x827B72);
      const uint16_t wallDark = rgb565(0x6D665E);
      constexpr size_t kMaximumCourtyardWorkspacePixels = 180000;

      Polygon buildingPolygon;
      std::vector<Point16, PsramAllocator<Point16>> screenPoints;
      std::vector<int32_t, PsramAllocator<int32_t>> scanlineNodes;
      MapBuildingVector<map_projection::GroundPoint> holeGround;
      MapBuildingVector<map_projection::GroundPoint> holeClipped;
      MapBuildingVector<map_building_renderer::ScreenPoint> holeScreen;
      map_building_renderer::SurfaceStats surfaceStats{};
      const uint32_t buildingDrawStartMs = millis();

      struct CourtyardSnapshot {
        map_building_workspace::Region region{};
        std::vector<uint16_t, PsramAllocator<uint16_t>> pixels;
        bool ready = false;
      };

      for (const BuildingItem &item : items) {
        if (shouldCancelMapRenderWork())
          return false;

        size_t projectedCourtyardPixels = 0;
        const double roofHeight = item.extruded
                                      ? item.building->heightDm / 10.0
                                      : 0.0;
        bool courtyardFits = true;
        for (const auto &ring : item.building->rings) {
          if (!ring.hole)
            continue;
          holeGround.clear();
          holeGround.reserve(ring.points.size());
          for (const auto &point : ring.points) {
            holeGround.push_back(projection.groundForWorld(
                {static_cast<double>(item.block->offset.x + point.x),
                 static_cast<double>(item.block->offset.y + point.y)}));
          }
          const auto *roof = &holeGround;
          if (projection.isBirdsEye()) {
            map_projection::clipPolygonToNearPlane(
                projection, holeGround, holeClipped);
            roof = &holeClipped;
          }
          holeScreen.clear();
          for (const auto &ground : *roof) {
            const auto point = projection.projectElevatedGround(
                ground, roofHeight, item.block->mercatorScale);
            if (point.valid) {
              holeScreen.push_back(
                  {map_transform::quantizePixel(point.x),
                   map_transform::quantizePixel(point.y)});
            }
          }
          const auto region = map_building_workspace::clippedRegion(
              holeScreen, surface.width, surface.height);
          if (region.valid())
            projectedCourtyardPixels += region.pixels();
          if (map_building_workspace::courtyardPolicy(
                  projectedCourtyardPixels,
                  kMaximumCourtyardWorkspacePixels,
                  static_cast<std::size_t>(surface.width) *
                      static_cast<std::size_t>(surface.height)) ==
              map_building_workspace::CourtyardPolicy::SolidRoofFallback) {
            courtyardFits = false;
            break;
          }
        }
        const bool preserveCourtyards = courtyardFits;
        if (!preserveCourtyards) {
          // Keep the admitted building and its walls/roof. Only the underlay
          // restoration is degraded, producing a deterministic solid roof
          // instead of making a large stadium or mall disappear entirely.
          ++courtyardDeferred;
        }

        std::vector<CourtyardSnapshot, PsramAllocator<CourtyardSnapshot>>
            courtyardSnapshots;
        if (preserveCourtyards)
          courtyardSnapshots.reserve(item.building->rings.size());
        size_t restoreIndex = 0;
        const bool rendered = map_building_renderer::renderSurfaces(
            *item.building, item.block->offset.x, item.block->offset.y,
            item.block->mercatorScale, projection, item.extruded,
            [&](map_building_renderer::Surface kind,
                const auto &points) -> bool {
              if (shouldCancelMapRenderWork())
                return false;
              if (kind ==
                  map_building_renderer::Surface::CourtyardCapture) {
                if (!preserveCourtyards)
                  return true;
                CourtyardSnapshot snapshot;
                snapshot.region = map_building_workspace::clippedRegion(
                    points, surface.width, surface.height);
                if (snapshot.region.valid()) {
                  snapshot.ready = map_building_workspace::captureRegion(
                      surface, snapshot.region, snapshot.pixels,
                      kMaximumCourtyardWorkspacePixels);
                  if (!snapshot.ready)
                    throw std::bad_alloc();
                  ++courtyardSnapshotCount;
                  largestCourtyardBytes = std::max(
                      largestCourtyardBytes,
                      snapshot.pixels.capacity() * sizeof(uint16_t));
                }
                courtyardSnapshots.push_back(std::move(snapshot));
                return true;
              }
              if (kind == map_building_renderer::Surface::Courtyard) {
                if (!preserveCourtyards)
                  return true;
                if (restoreIndex >= courtyardSnapshots.size())
                  return false;
                const auto &snapshot = courtyardSnapshots[restoreIndex++];
                if (!snapshot.ready)
                  return true;
                return map_building_workspace::restorePolygon(
                    points, surface, snapshot.region, snapshot.pixels,
                    scanlineNodes, shouldCancelMapRenderWork);
              }

              uint16_t color = roofColor;
              switch (kind) {
              case map_building_renderer::Surface::WallLight:
                color = wallLight;
                break;
              case map_building_renderer::Surface::WallMiddle:
                color = wallMiddle;
                break;
              case map_building_renderer::Surface::WallDark:
                color = wallDark;
                break;
              case map_building_renderer::Surface::Roof:
              case map_building_renderer::Surface::CourtyardCapture:
              case map_building_renderer::Surface::Courtyard:
                break;
              }
              if (points.size() < 3)
                return true;
              screenPoints.clear();
              screenPoints.reserve(points.size() + 1U);
              int16_t minX = 32767;
              int16_t minY = 32767;
              int16_t maxX = -32768;
              int16_t maxY = -32768;
              for (const auto &point : points) {
                const Point16 converted(
                    static_cast<int16_t>(point.x),
                    static_cast<int16_t>(point.y));
                screenPoints.push_back(converted);
                minX = std::min(minX, converted.x);
                minY = std::min(minY, converted.y);
                maxX = std::max(maxX, converted.x);
                maxY = std::max(maxY, converted.y);
              }
              screenPoints.push_back(screenPoints.front());
              buildingPolygon.points = screenPoints;
              buildingPolygon.color = color;
              buildingPolygon.bbox.min = Point16(minX, minY);
              buildingPolygon.bbox.max = Point16(maxX, maxY);
              const bool filled = fillPolygon(buildingPolygon, surface);
              if (!filled && !shouldCancelMapRenderWork()) {
                // fillPolygon uses a bounded PSRAM node workspace and reports
                // allocation failure as false. Promote that result into the
                // surrounding allocation-safe building pass so it can render
                // the deterministic flat fallback instead of retrying the
                // same failing 3D job forever.
                throw std::bad_alloc();
              }
              return filled;
            },
            &surfaceStats, shouldCancelMapRenderWork);
        if (!rendered)
          return false;
        ++renderedBuildings;
      }
      buildingDrawMs = millis() - buildingDrawStartMs;

      MAPIO_LOG(
          "MAPIO: buildings candidates=%u retained=%u selected=%u "
          "extruded=%u flat=%u deferred=%u visible=%u oversized=%u "
          "rendered=%u courtyardDeferred=%u projectionMs=%lu drawMs=%lu "
          "courtyardSnapshots=%u courtyardMaxBytes=%u "
          "freeInternalHeap=%u largestInternalHeap=%u "
          "psramFree=%u psramLargest=%u wallFaces=%u suppressedWalls=%u\n",
          (unsigned)admissionDiagnostics.candidates,
          (unsigned)candidates.size(),
          (unsigned)admissionDiagnostics.selected,
          (unsigned)admissionDiagnostics.extruded,
          (unsigned)admissionDiagnostics.flat,
          (unsigned)(admissionDiagnostics.deferred + metadataDeferred),
          (unsigned)visibleRecords,
          (unsigned)oversizedBuildings, (unsigned)renderedBuildings,
          (unsigned)courtyardDeferred, (unsigned long)buildingProjectionMs,
          (unsigned long)buildingDrawMs,
          (unsigned)courtyardSnapshotCount,
          (unsigned)largestCourtyardBytes,
          (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL |
                                            MALLOC_CAP_8BIT),
          (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL |
                                                     MALLOC_CAP_8BIT),
          (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
          (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM),
          (unsigned)surfaceStats.generatedWallFaces,
          (unsigned)surfaceStats.suppressedWallFaces);
    } catch (const std::bad_alloc &) {
      buildingAllocationFailed = true;
      buildingFailureInternalHeapFree =
          heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
      buildingFailureInternalHeapLargest = heap_caps_get_largest_free_block(
          MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
      buildingFailurePsramFree = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
      buildingFailurePsramLargest =
          heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
    }
    }
  }

  if (diagnostics != nullptr) {
    diagnostics->candidateBuildings = candidateBuildings;
    diagnostics->selectedBuildings =
        static_cast<uint32_t>(admissionDiagnostics.selected);
    diagnostics->extrudedBuildings =
        static_cast<uint32_t>(admissionDiagnostics.extruded);
    diagnostics->flatBuildings =
        static_cast<uint32_t>(admissionDiagnostics.flat);
    diagnostics->deferredBuildings = static_cast<uint32_t>(
        admissionDiagnostics.deferred + metadataDeferredBuildings +
        courtyardDeferred);
    diagnostics->oversizedBuildings = oversizedBuildings;
    diagnostics->renderedBuildings = renderedBuildings;
    diagnostics->extrudedP90DistancePx = extrudedP90DistancePx;
    diagnostics->extrudedFarthestDistancePx =
        extrudedFarthestDistancePx;
    diagnostics->buildingProjectionMs = buildingProjectionMs;
    diagnostics->buildingDrawMs = buildingDrawMs;
    diagnostics->buildingLimiterFlags = admissionDiagnostics.limiterFlags;
    diagnostics->allocationFallback = buildingAllocationFailed;
  }

  if (buildingAllocationFailed) {
    buildingFailureRetryCooldown.recordFailure(
        millis(), buildingContextSignature, buildingRenderRegion);
    MAPIO_LOG("MAPIO: buildings failure=allocation fallback=bounded-flat "
              "courtyardSnapshots=%u courtyardMaxBytes=%u "
              "freeInternalHeap=%u largestInternalHeap=%u "
              "buildingFailureInternalHeapFree=%u "
              "buildingFailureInternalHeapLargest=%u "
              "psramFree=%u psramLargest=%u\n",
              (unsigned)courtyardSnapshotCount,
              (unsigned)largestCourtyardBytes,
              (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL |
                                                MALLOC_CAP_8BIT),
              (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL |
                                                         MALLOC_CAP_8BIT),
              (unsigned)buildingFailureInternalHeapFree,
              (unsigned)buildingFailureInternalHeapLargest,
              (unsigned)buildingFailurePsramFree,
              (unsigned)buildingFailurePsramLargest);
    // reason=interrupt fallback=deferred: semantic invalidation keeps the
    // last complete frame visible and schedules the newest request.
    if (!suppressBuildings && !shouldCancelMapRenderWork()) {
      RasterDiagnostics fallbackDiagnostics{};
      const bool fallbackRendered = readVectorMap(
          viewPort, memCache, surface, zoom, rotation, projection, context,
          drawLabels, true, &fallbackDiagnostics);
      fallbackDiagnostics.allocationFallback = true;
      if (diagnostics != nullptr)
        *diagnostics = fallbackDiagnostics;
      return fallbackRendered;
    }
    return false;
  }

  if (drawLabels) {
    map_surface::LabelSurface labelSurface;
    labelSurface.color = surface;
    if (!drawStreetLabels(viewPort, memCache, labelSurface, zoom, rotation,
                          context)) {
      return false;
    }
  }

  MAPIO_LOG("MAPIO: raw-map ok=1 mode=%s clipped=%lu rejected=%lu "
            "blocks=%u totalMs=%lu\n",
            projection.isBirdsEye() ? "birds-eye" : "flat",
            (unsigned long)projectionClippedCount,
            (unsigned long)projectionRejectedCount,
            (unsigned)memCache.blocks.size(),
            (unsigned long)(MAPIO_TIME_MS() - drawStartMs));
  return true;
}

Maps::RenderContext Maps::captureRenderContext(uint32_t nowMs) {
  return captureRenderContextForScreen(
      nowMs, isMapScreenActive() || isMapGuidanceScreenActive(),
      isMapGuidanceScreenActive());
}

Maps::RenderContext Maps::captureRenderContextForScreen(
    uint32_t nowMs, bool mapVisible, bool guidanceScreenActive) {
  RenderContext context;
  context.tuning = renderer_tuning::definition(rendererTuningProfile_);
#if FIRMWARE_DIAGNOSTICS
  context.rendererDiagnosticsWindowId =
      renderer_diagnostics::currentWindowId();
#endif
  context.style = map_profile_protocol::select(
      mapRenderSettings.mapStyle, mapRenderSettings.mapNavigationStyle,
      guidanceScreenActive);
  context.measuredGpsWorld = {lon2x(gps.gpsData.longitude),
                              lat2y(gps.gpsData.latitude)};
  if (nowMs != 0)
    updatePresentedPoseForScreen(nowMs, mapVisible);
  context.presentedWorld = hasPresentedPose
                               ? map_transform::WorldPoint{
                                     presentedPose.position.x,
                                     presentedPose.position.y}
                               : context.measuredGpsWorld;
  context.guidanceScreenActive = guidanceScreenActive;
  context.navigationSessionActive =
      routeOverlay.hasRoute() || hasCurrentNavigationData();
  context.followPosition = followGps || guidanceScreenActive;
  context.showCurrentPosition = isCurrentPositionVisible(mapRenderSettings);
  context.buildings3DEnabled =
      mapRenderSettings.mapNavigation3DBuildingsEnabled;
  context.markerScale = static_cast<uint8_t>(std::min(
      std::max(static_cast<int>(context.style.positionMarkerScale), 1), 5));
  context.birdsEyePerspective =
      mapRenderSettings.mapNavigationBirdsEyePerspective;
  return context;
}

bool Maps::readVectorMap(ViewPort &viewPort, MemCache &memCache,
                         lv_obj_t *canvas, uint8_t zoom, double rotation,
                         const map_projection::Projection &projection,
                         bool drawLabels, bool suppressBuildings) {
  RenderContext context = captureRenderContext();
  return readVectorMap(viewPort, memCache, rgb565SurfaceForCanvas(canvas), zoom,
                       rotation, projection, context, drawLabels,
                       suppressBuildings);
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
namespace {

uint64_t fnvMix64(uint64_t hash, uint64_t value) {
  hash ^= value;
  return hash * 1099511628211ULL;
}

uint64_t doubleBits(double value) {
  uint64_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value), "unexpected double size");
  memcpy(&bits, &value, sizeof(bits));
  return bits;
}

int16_t mapAngleTenths(double radians) {
  constexpr double kRadiansToTenths = 1800.0 / 3.14159265358979323846;
  double tenths = radians * kRadiansToTenths;
  while (tenths > 1800.0)
    tenths -= 3600.0;
  while (tenths < -1800.0)
    tenths += 3600.0;
  return static_cast<int16_t>(std::round(tenths));
}

} // namespace

uint64_t Maps::styleSignature(const ScreenMapRenderSettings &style) const {
  uint64_t hash = 1469598103934665603ULL;
  hash = fnvMix64(hash, style.minPolygonSize);
  hash = fnvMix64(hash, style.detailLevel);
  hash = fnvMix64(hash, style.routeLineWidth);
  hash = fnvMix64(hash, style.streetLineWidth);
  hash = fnvMix64(hash, style.positionMarkerScale);
  hash = fnvMix64(hash, style.zoomLevel);
  hash = fnvMix64(hash, style.visibilityMask);
  hash = fnvMix64(hash, style.labelDensity);
  hash = fnvMix64(hash, style.labelLanguageMode);
  hash = fnvMix64(hash, style.labelTextSize);
  hash = fnvMix64(hash, style.labelOrientation);
  hash = fnvMix64(hash, mapRenderSettings.navigationOverlayVisibilityMask);
  hash = fnvMix64(hash,
                  mapRenderSettings.mapNavigation3DBuildingsEnabled ? 1U : 0U);
  hash = fnvMix64(hash,
                  mapRenderSettings.mapNavigationBirdsEyeEnabled ? 1U : 0U);
  hash = fnvMix64(hash,
                  mapRenderSettings.mapNavigationBirdsEyePerspective);
  hash = fnvMix64(
      hash,
      renderer_tuning::fingerprint(
          renderer_tuning::definition(rendererTuningProfile_)));
  return hash;
}

bool Maps::setRendererTuningProfile(renderer_tuning::Profile profile,
                                    uint32_t nowMs) {
  if (rendererTuningProfile_ == profile) {
    renderer_diagnostics::setProfile(profile);
    return true;
  }
  rendererTuningProfile_ = profile;
  renderer_diagnostics::setProfile(profile);
  invalidateRenderSemantics(nowMs);
  return true;
}

renderer_diagnostics::JobCounters Maps::rendererDiagnosticsJobCounters() const {
#if !FIRMWARE_DIAGNOSTICS
  return {};
#else
  if (renderStateMutex == nullptr ||
      xSemaphoreTake(renderStateMutex, portMAX_DELAY) != pdTRUE) {
    return {};
  }
  const renderer_diagnostics::JobCounters counters =
      rendererJobCounters(renderJobs.diagnostics());
  xSemaphoreGive(renderStateMutex);
  return counters;
#endif
}

uint64_t
Maps::navigationSignatureForScreen(bool guidanceScreenActive) const {
  // Only state that changes the base-frame contract belongs here. Maneuver
  // text/distance remains a lightweight LVGL overlay and must not cancel an
  // expensive base render every time its packet advances.
  uint64_t hash = 1469598103934665603ULL;
  const bool guidanceSession =
      routeOverlay.hasRoute() || hasCurrentNavigationData();
  hash = fnvMix64(hash, guidanceSession ? 1U : 0U);
  hash = fnvMix64(hash, guidanceScreenActive ? 1U : 0U);
  hash = fnvMix64(hash, static_cast<uint8_t>(rotationMode));
  return hash;
}

uint64_t Maps::projectionSignature(uint8_t requestedZoom,
                                   uint16_t viewportWidth,
                                   uint16_t viewportHeight, bool birdsEye,
                                   uint8_t perspective) const {
  uint64_t hash = 1469598103934665603ULL;
  hash = fnvMix64(hash, requestedZoom);
  hash = fnvMix64(hash, viewportWidth);
  hash = fnvMix64(hash, viewportHeight);
  hash = fnvMix64(hash, birdsEye ? 1U : 0U);
  hash = fnvMix64(hash, perspective);
  hash = fnvMix64(hash, MAP_RENDER_OVERSCAN_PIXELS);
  return hash;
}

void Maps::invalidateRenderSemantics(uint32_t nowMs) {
  invalidateRenderSemanticsForScreen(
      nowMs, zoom, isMapScreenActive() || isMapGuidanceScreenActive(),
      isMapGuidanceScreenActive());
}

void Maps::invalidateRenderSemanticsForScreen(uint32_t nowMs,
                                              uint8_t requestedZoom,
                                              bool mapVisible,
                                              bool guidanceScreenActive) {
  bool semanticChanged = false;
  const ScreenMapRenderSettings &style = map_profile_protocol::select(
      mapRenderSettings.mapStyle, mapRenderSettings.mapNavigationStyle,
      guidanceScreenActive);
  const uint64_t currentStyle = styleSignature(style);
  if (lastStyleSignature == 0) {
    lastStyleSignature = currentStyle;
  } else if (lastStyleSignature != currentStyle) {
    lastStyleSignature = currentStyle;
    ++styleEpoch;
    isPosMoved = true;
    redrawMap = true;
    semanticChanged = true;
  }

  const uint64_t currentNavigation =
      navigationSignatureForScreen(guidanceScreenActive);
  if (lastNavigationSignature == 0) {
    lastNavigationSignature = currentNavigation;
  } else if (lastNavigationSignature != currentNavigation) {
    lastNavigationSignature = currentNavigation;
    ++navigationEpoch;
    isPosMoved = true;
    redrawMap = true;
    semanticChanged = true;
  }

  // Heading memory belongs to an explicit presentation session. Ordinary
  // sliding-window replacements are deliberately excluded: route geometry is
  // live foreground state, and resetting prediction on every packet makes the
  // rider jump back to the last raw GPS coordinate. A newly received route
  // bearing still replaces remembered heading through resolve().
  uint64_t headingSession = 1469598103934665603ULL;
  const bool routeActive = routeOverlay.hasRoute();
  const bool maneuverActive = hasCurrentNavigationData();
  headingSession = fnvMix64(headingSession, mapVisible ? 1U : 0U);
  headingSession =
      fnvMix64(headingSession, guidanceScreenActive ? 1U : 0U);
  headingSession = fnvMix64(
      headingSession, (routeActive || maneuverActive) ? 1U : 0U);
  headingSession = fnvMix64(headingSession,
                            static_cast<uint8_t>(rotationMode));
  if (lastHeadingSessionSignature == 0) {
    lastHeadingSessionSignature = headingSession;
  } else if (lastHeadingSessionSignature != headingSession) {
    lastHeadingSessionSignature = headingSession;
    ++headingSessionEpoch;
    headingResolver.setNavigationSession(false, headingSessionEpoch);
    posePresenter.resetHeading(nowMs);
    presentedPose.headingDegrees = 0.0;
    presentedPose.headingValid = false;
    // Re-run display heading through the new epoch without manufacturing a
    // fresh physical observation from the retained GPS fix.
    poseInputTracker.invalidateHeading();
  }

  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? mapScrFull : mapScrHeight;
  const bool birdsEye = navigation_content_mode::usesMapGuidanceBirdsEye(
      guidanceScreenActive,
      mapRenderSettings.mapNavigationBirdsEyeEnabled);
  const uint64_t currentProjection = projectionSignature(
      requestedZoom, mapScrWidth, viewportHeight, birdsEye,
      mapRenderSettings.mapNavigationBirdsEyePerspective);
  if (lastProjectionSignature == 0) {
    lastProjectionSignature = currentProjection;
  } else if (lastProjectionSignature != currentProjection) {
    lastProjectionSignature = currentProjection;
    ++projectionEpoch;
    isPosMoved = true;
    redrawMap = true;
    semanticChanged = true;
  }

  if (semanticChanged)
    cancelActiveRenderWork();
}

void Maps::cancelActiveRenderWork() {
  if (renderStateMutex == nullptr) {
    gMapRenderCancellationGeneration.fetch_add(1, std::memory_order_acq_rel);
    return;
  }
  if (xSemaphoreTake(renderStateMutex, portMAX_DELAY) == pdTRUE) {
    // The cooperative token and LatestWins generation cross one mutex
    // boundary. A worker can therefore only capture the generation before or
    // after this cancellation, never the new atomic token with old job state.
    gMapRenderCancellationGeneration.fetch_add(1, std::memory_order_acq_rel);
    renderJobs.requestCancellation();
    xSemaphoreGive(renderStateMutex);
  }
}

void Maps::updatePresentedPose(uint32_t nowMs) {
  updatePresentedPoseForScreen(
      nowMs, isMapScreenActive() || isMapGuidanceScreenActive());
}

void Maps::updatePresentedPoseForScreen(uint32_t nowMs, bool mapVisible) {
  const bool routeActive = routeOverlay.hasRoute();
  const bool maneuverActive = hasCurrentNavigationData();
  // The session is explicit and screen-scoped. A route window or a maneuver
  // snapshot is independently sufficient to make guidance course-up valid.
  const bool sessionActive =
      mapVisible &&
      (rotationMode == ROT_COURSE_UP || routeActive || maneuverActive);
  headingResolver.setNavigationSession(sessionActive, headingSessionEpoch);

  double routeDegrees = 0.0;
  uint16_t routeHeading = 0;
  const bool routeValid =
      routeActive &&
      routeOverlay.headingNear(gps.gpsData.latitude, gps.gpsData.longitude,
                               routeHeading);
  if (routeValid)
    routeDegrees = routeHeading;

  double resolvedHeading = 0.0;
  const bool measuredValid = gps.gpsData.headingValid &&
                             gps.gpsData.heading < 360U;
  const bool headingValid = headingResolver.resolve(
      measuredValid, gps.gpsData.heading, routeValid, routeDegrees,
      resolvedHeading, !bleNavServer.supportsExplicitInvalidGpsHeading());
  const BLEDebugStats bleStats = bleNavServer.getDebugStats();

  uint64_t gpsPositionSignature = 1469598103934665603ULL;
  gpsPositionSignature =
      fnvMix64(gpsPositionSignature, doubleBits(gps.gpsData.latitude));
  gpsPositionSignature =
      fnvMix64(gpsPositionSignature, doubleBits(gps.gpsData.longitude));
  gpsPositionSignature = fnvMix64(gpsPositionSignature, gps.gpsData.speed);
  // Identical coordinates are still a new physical fix. Packet timing and
  // count belong to the position signature; route-derived headings do not.
  gpsPositionSignature =
      fnvMix64(gpsPositionSignature, bleStats.lastGpsPacketMs);
  gpsPositionSignature =
      fnvMix64(gpsPositionSignature, bleStats.gpsPacketCount);
  uint64_t gpsSignature = gpsPositionSignature;
  gpsSignature = fnvMix64(gpsSignature, headingValid ? 1U : 0U);
  gpsSignature = fnvMix64(gpsSignature, doubleBits(resolvedHeading));
  const map_pose_input_policy::Action poseInputAction =
      poseInputTracker.classify(gpsPositionSignature, gpsSignature,
                                posePresenter.hasFix());
  if (poseInputAction != map_pose_input_policy::Action::None) {
    map_presentation::Fix fix;
    fix.position = {lon2x(gps.gpsData.longitude),
                    lat2y(gps.gpsData.latitude)};
    fix.headingDegrees = resolvedHeading;
    fix.headingValid = headingValid;
    fix.speedMetersPerSecond = gps.gpsData.speed / 3.6;
    const double latitudeRadians =
        gps.gpsData.latitude * 3.14159265358979323846 / 180.0;
    fix.worldUnitsPerMeter =
        1.0 / std::max(0.2, std::fabs(std::cos(latitudeRadians)));
    // The accepted transport timestamp owns physical freshness. Route-bearing
    // changes use updateHeading below and cannot re-observe this position.
    fix.timestampMs = bleStats.gpsPacketCount != 0
                          ? bleStats.lastGpsPacketMs
                          : nowMs;
    if (poseInputAction ==
        map_pose_input_policy::Action::ObservePhysicalFix) {
      posePresenter.observe(fix, nowMs);
    } else {
      posePresenter.updateHeading(resolvedHeading, headingValid, nowMs);
    }
  }
  if (posePresenter.hasFix()) {
    const bool firstPose = !hasPresentedPose;
    const bool wasGraceActive =
        hasPresentedPose && presentedPose.predictionGraceActive;
    const bool wasExhausted =
        hasPresentedPose && presentedPose.predictionExhausted;
    presentedPose = posePresenter.present(nowMs);
    hasPresentedPose = true;
    if (presentedPose.predictionExhausted && !wasExhausted) {
      ++predictionExhaustionCount;
      lastPredictionExhaustedMs = nowMs;
    }
    if (firstPose ||
        wasGraceActive != presentedPose.predictionGraceActive ||
        wasExhausted != presentedPose.predictionExhausted) {
      MAPIO_LOG(
          "MAPIO: presentation gpsAgeMs=%lu lastGpsGapMs=%lu "
          "maxGpsGapMs=%lu predictionAgeMs=%lu grace=%u "
          "predictionExhausted=%u exhaustionCount=%lu "
          "lastExhaustedMs=%lu\n",
          (unsigned long)presentedPose.observationAgeMs,
          (unsigned long)bleStats.lastGpsPacketGapMs,
          (unsigned long)bleStats.maximumGpsPacketGapMs,
          (unsigned long)presentedPose.predictionAgeMs,
          presentedPose.predictionGraceActive ? 1U : 0U,
          presentedPose.predictionExhausted ? 1U : 0U,
          (unsigned long)predictionExhaustionCount,
          (unsigned long)lastPredictionExhaustedMs);
    }
  }
}
map_projection::Projection
Maps::makeRequestProjection(const RenderRequest &request) const {
  map_projection::Config config;
  config.viewportWidth = request.renderWidth;
  config.viewportHeight = request.renderHeight;
  config.worldOrigin = request.center;
  config.zoom = request.zoom;
  config.rotationRad = request.rotationRad;
  config.anchorX = request.overscanPixels +
                   gui_layout::mapAnchorX(request.viewportWidth);
  config.anchorY = request.overscanPixels +
                   (request.birdsEye
                        ? map_projection::birdsEyeAnchorY(
                              request.viewportHeight)
                        : gui_layout::mapAnchorY(request.viewportHeight));
  config.mode = request.birdsEye ? map_projection::Mode::BirdsEye
                                 : map_projection::Mode::Flat;
  config.topEdgeScale = map_projection::birdsEyeTopEdgeScale(
      map_projection::birdsEyePerspectiveForValue(
          request.context.birdsEyePerspective));
  return map_projection::Projection(config);
}

bool Maps::buildRenderRequest(uint8_t requestedZoom, uint32_t nowMs,
                              RenderRequest &request) {
  return buildRenderRequestForScreen(
      requestedZoom, nowMs,
      isMapScreenActive() || isMapGuidanceScreenActive(),
      isMapGuidanceScreenActive(), request);
}

bool Maps::buildRenderRequestForScreen(uint8_t requestedZoom, uint32_t nowMs,
                                       bool mapVisible,
                                       bool guidanceScreenActive,
                                       RenderRequest &request) {
  invalidateRenderSemanticsForScreen(nowMs, requestedZoom, mapVisible,
                                     guidanceScreenActive);
  updatePresentedPoseForScreen(nowMs, mapVisible);

  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? mapScrFull : mapScrHeight;
  if (mapScrWidth == 0 || viewportHeight == 0)
    return false;

  request = {};
  request.zoom = requestedZoom;
  request.viewportWidth = mapScrWidth;
  request.viewportHeight = viewportHeight;
  request.overscanPixels = MAP_RENDER_OVERSCAN_PIXELS;
  request.renderWidth = static_cast<uint16_t>(
      request.viewportWidth + request.overscanPixels * 2U);
  request.renderHeight = static_cast<uint16_t>(
      request.viewportHeight + request.overscanPixels * 2U);
  request.renderStridePixels =
      lv_draw_buf_width_to_stride(request.renderWidth,
                                  LV_COLOR_FORMAT_RGB565) /
      sizeof(uint16_t);
  request.birdsEye = navigation_content_mode::usesMapGuidanceBirdsEye(
      guidanceScreenActive,
      mapRenderSettings.mapNavigationBirdsEyeEnabled);
  request.context = captureRenderContextForScreen(
      nowMs, mapVisible, guidanceScreenActive);
  request.styleSignature = styleSignature(request.context.style);
  request.navigationSignature =
      navigationSignatureForScreen(guidanceScreenActive);
  request.projectionSignature = projectionSignature(
      request.zoom, request.viewportWidth, request.viewportHeight,
      request.birdsEye, request.context.birdsEyePerspective);

  const bool followPosition = request.context.followPosition;
  request.center = followPosition && hasPresentedPose
                       ? map_transform::WorldPoint{presentedPose.position.x,
                                                   presentedPose.position.y}
                       : map_transform::WorldPoint{static_cast<double>(point.x),
                                                   static_cast<double>(point.y)};
  request.context.presentedWorld =
      hasPresentedPose
          ? map_transform::WorldPoint{presentedPose.position.x,
                                      presentedPose.position.y}
          : request.context.measuredGpsWorld;

  request.rotationRad = 0.0;
  if (rotationMode == ROT_COURSE_UP) {
    if (hasPresentedPose && presentedPose.headingValid) {
      request.rotationRad =
          -presentedPose.headingDegrees * 3.14159265358979323846 / 180.0;
    } else if (publishedMapFrame &&
               visibleRenderResult.version.navigationEpoch ==
                   navigationEpoch) {
      request.rotationRad = visibleRenderResult.rotationRad;
    } else if (!request.context.navigationSessionActive) {
      // Course-up has no semantic direction before guidance starts. Permit an
      // initial north-up base so the idle Map + Navigation screen can show its
      // configured bird's-eye/3D scene. Once a route or maneuver is active,
      // the branch below still refuses to invent north from a missing course.
      request.rotationRad = 0.0;
    } else {
      ESP_LOGW(TAG,
               "Course-up frame deferred: neither measured course nor route "
               "bearing is valid");
      return false;
    }
  }

  // Render toward where the rider is expected when this worker pass finishes,
  // while capping the lead to the proven overscan budget. Presentation still
  // anchors the live rider at the normal screen point; only the source-frame
  // coverage is asymmetric in the direction of travel.
  if (followPosition && hasPresentedPose && presentedPose.headingValid) {
    const double speedMetersPerSecond = gps.gpsData.speed / 3.6;
    const double latitudeRadians =
        gps.gpsData.latitude * 3.14159265358979323846 / 180.0;
    const double worldUnitsPerMeter =
        1.0 / std::max(0.2, std::fabs(std::cos(latitudeRadians)));
    const double pixelsPerMeter =
        worldUnitsPerMeter * map_transform::worldToScreenScale(request.zoom);
    const uint32_t expectedLatencyMs =
        std::max<uint32_t>(250U,
                           std::min<uint32_t>(5000U,
                                              lastCompletedRenderDurationMs));
    const double leadPixels = map_presentation::refreshLeadPixels(
        speedMetersPerSecond, pixelsPerMeter, expectedLatencyMs, 0.0, 0.0,
        MAP_RENDER_OVERSCAN_PIXELS - MAP_RENDER_SAFETY_PIXELS);
    if (pixelsPerMeter > 0.0 && leadPixels > 0.0) {
      const double leadWorld =
          leadPixels / pixelsPerMeter * worldUnitsPerMeter;
      const double headingRadians =
          map_presentation::normalizeDegrees(presentedPose.headingDegrees) *
          3.14159265358979323846 / 180.0;
      request.center.x += std::sin(headingRadians) * leadWorld;
      request.center.y += std::cos(headingRadians) * leadWorld;
    }
  }

  request.version.routeRevision = routeOverlay.revision();
  request.version.navigationEpoch = navigationEpoch;
  request.version.styleEpoch = styleEpoch;
  request.version.mapEpoch = mapEpoch;
  request.version.projectionEpoch = projectionEpoch;
  return true;
}

bool Maps::submitRenderRequest(const RenderRequest &immutableRequest) {
  if (renderStateMutex == nullptr || renderWorkerTaskHandle == nullptr)
    return false;
  RenderRequest request = immutableRequest;
  if (xSemaphoreTake(renderStateMutex, 0) != pdTRUE)
    return false;
  request.version = renderJobs.submit(request.version);
  latestRenderRequest = request;
  latestRenderRequestValid = true;
  if (renderJobs.state() == map_render_job::State::Ready &&
      !map_render_job::Version::sameFrame(renderJobs.ready(),
                                          request.version)) {
    renderJobs.rejectReadyAsStale();
    readyRenderResultValid = false;
  }
  gMapRenderLatestSequence.store(request.version.sequence,
                                 std::memory_order_release);
  const TaskHandle_t worker = renderWorkerTaskHandle;
#if FIRMWARE_DIAGNOSTICS
  renderer_diagnostics::noteJobs(rendererJobCounters(renderJobs.diagnostics()));
#endif
  xSemaphoreGive(renderStateMutex);
  if (worker != nullptr)
    xTaskNotifyGive(worker);
  MAPIO_LOG("MAPIO: render-submit seq=%lu route=%lu nav=%lu style=%lu "
            "map=%lu projection=%lu center=(%.1f,%.1f) rotation=%.3f\n",
            (unsigned long)request.version.sequence,
            (unsigned long)request.version.routeRevision,
            (unsigned long)request.version.navigationEpoch,
            (unsigned long)request.version.styleEpoch,
            (unsigned long)request.version.mapEpoch,
            (unsigned long)request.version.projectionEpoch, request.center.x,
            request.center.y, request.rotationRad);
  return true;
}

bool Maps::takeWorkerRequest(RenderRequest &request) {
  if (renderStateMutex == nullptr)
    return false;
  if (xSemaphoreTake(renderStateMutex, portMAX_DELAY) != pdTRUE)
    return false;
  bool available =
      !pendingVectorMapActivationValid &&
      !completedVectorMapActivationValid && latestRenderRequestValid &&
      latestRenderRequest.version.sequence > lastTakenRenderSequence &&
      renderJobs.beginLatest();
  if (available) {
    request = latestRenderRequest;
    available = request.version == renderJobs.active();
    if (available) {
      request.cancellationGeneration =
          gMapRenderCancellationGeneration.load(std::memory_order_acquire);
      lastTakenRenderSequence = request.version.sequence;
    } else {
      renderJobs.cancelActive();
    }
  }
#if FIRMWARE_DIAGNOSTICS
  renderer_diagnostics::noteJobs(rendererJobCounters(renderJobs.diagnostics()));
#endif
  xSemaphoreGive(renderStateMutex);
  return available;
}

bool Maps::renderRequestStillCurrent(const RenderRequest &request) const {
  const bool guidanceScreenActive = isMapGuidanceScreenActive();
  const ScreenMapRenderSettings &style = map_profile_protocol::select(
      mapRenderSettings.mapStyle, mapRenderSettings.mapNavigationStyle,
      guidanceScreenActive);
  return request.version.navigationEpoch == navigationEpoch &&
         request.version.styleEpoch == styleEpoch &&
         request.version.mapEpoch == mapEpoch &&
         request.version.projectionEpoch == projectionEpoch &&
         request.styleSignature == styleSignature(style) &&
         request.navigationSignature ==
             navigationSignatureForScreen(guidanceScreenActive) &&
         request.projectionSignature == projectionSignature(
             request.zoom, request.viewportWidth, request.viewportHeight,
             navigation_content_mode::usesMapGuidanceBirdsEye(
                 guidanceScreenActive,
                 mapRenderSettings.mapNavigationBirdsEyeEnabled),
             mapRenderSettings.mapNavigationBirdsEyePerspective);
}

bool Maps::renderResultStillCurrent(const RenderResult &result) const {
  RenderRequest request;
  request.version = result.version;
  request.styleSignature = result.styleSignature;
  request.navigationSignature = result.navigationSignature;
  request.projectionSignature = result.projectionSignature;
  request.zoom = result.viewport.zoom;
  request.viewportWidth = result.viewportWidth;
  request.viewportHeight = result.viewportHeight;
  request.birdsEye = result.projection.isBirdsEye();
  return renderRequestStillCurrent(request);
}

bool Maps::startRenderWorker() {
  if (renderWorkerTaskHandle != nullptr) {
    return !renderWorkerShutdown.load(std::memory_order_acquire);
  }
  if (renderStateMutex == nullptr)
    renderStateMutex = xSemaphoreCreateMutex();
  if (renderStateMutex == nullptr)
    return false;

  renderWorkerShutdown.store(false, std::memory_order_release);
  renderWorkerExited.store(false, std::memory_order_release);
  renderWorkerRestartAfterExit.store(false, std::memory_order_release);
  gMapRenderWorkerShutdown.store(false, std::memory_order_release);
  gMapRenderControlOperation.store(false, std::memory_order_release);
  gMapRenderLatestSequence.store(0, std::memory_order_release);
  gMapRenderActiveSequence.store(0, std::memory_order_release);
  gMapRenderCancellationGeneration.store(0, std::memory_order_release);
  gMapRenderActiveCancellationGeneration.store(0,
                                               std::memory_order_release);
  renderJobs.reset();
  latestRenderRequestValid = false;
  lastTakenRenderSequence = 0;
  readyRenderResultValid = false;
  renderFailurePending = false;
  // Rasterization needs a deliberately large stack, but Wi-Fi AP startup also
  // needs a sizeable contiguous internal allocation. Keeping this always-on
  // worker in internal DRAM can therefore make map transfer crash inside the
  // Wi-Fi driver before it has a chance to report an allocation failure. The
  // AMOLED boards have PSRAM and their SDK configuration explicitly permits
  // external task stacks, so reserve internal RAM for radio/driver work.
  BaseType_t created = xTaskCreatePinnedToCoreWithCaps(
      renderWorkerTaskThunk, "map_render", MAP_RENDER_WORKER_STACK_BYTES, this,
      1, &renderWorkerTaskHandle, 0, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (created != pdPASS) {
    renderWorkerTaskHandle = nullptr;
    renderWorkerExited.store(true, std::memory_order_release);
    ESP_LOGE(TAG, "Could not create map render worker");
    return false;
  }
  return true;
}

bool Maps::stopRenderWorker() {
  TaskHandle_t worker = renderWorkerTaskHandle;
  if (worker == nullptr) {
    renderWorkerRestartAfterExit.store(false, std::memory_order_release);
    renderWorkerExited.store(true, std::memory_order_release);
    return true;
  }

  renderWorkerShutdown.store(true, std::memory_order_release);
  gMapRenderWorkerShutdown.store(true, std::memory_order_release);
  gMapRenderLatestSequence.fetch_add(1, std::memory_order_acq_rel);
  xTaskNotifyGive(worker);

  // This is an exceptional control-plane path (screen destruction or map-root
  // mutation), never a normal LVGL tick. Do not free worker-owned surfaces if
  // a bounded storage operation has not returned yet.
  const uint32_t started = millis();
  while (!renderWorkerExited.load(std::memory_order_acquire) &&
         static_cast<uint32_t>(millis() - started) < 2500U) {
    vTaskDelay(pdMS_TO_TICKS(2));
  }
  if (!renderWorkerExited.load(std::memory_order_acquire)) {
    // The caller leaves worker-owned state untouched. Once the delayed IO
    // checkpoint returns, the UI pipeline restarts the old, still-valid map
    // root instead of silently leaving navigation on a frozen frame.
    renderWorkerRestartAfterExit.store(true, std::memory_order_release);
    ESP_LOGE(TAG, "Map render worker did not stop cleanly; state preserved");
    return false;
  }
  renderWorkerRestartAfterExit.store(false, std::memory_order_release);
  gMapRenderWorkerShutdown.store(false, std::memory_order_release);
  renderWorkerShutdown.store(false, std::memory_order_release);
  return true;
}

bool Maps::recoverRenderWorkerIfNeeded() {
  if (!renderWorkerRestartAfterExit.load(std::memory_order_acquire))
    return renderWorkerTaskHandle != nullptr;
  if (!renderWorkerExited.load(std::memory_order_acquire))
    return false;
  if (startRenderWorker())
    return true;
  renderWorkerRestartAfterExit.store(true, std::memory_order_release);
  return false;
}

void Maps::renderWorkerTaskThunk(void *argument) {
  auto *maps = static_cast<Maps *>(argument);
  if (maps != nullptr)
    maps->renderWorkerLoop();
  // Must match xTaskCreatePinnedToCoreWithCaps so the PSRAM stack and static
  // task control block are reclaimed correctly.
  vTaskDeleteWithCaps(nullptr);
}

void Maps::renderWorkerLoop() {
  gMapRenderWorkerTaskHandle = xTaskGetCurrentTaskHandle();
  MAPIO_LOG("MAPIO: render-worker started core=%d\n", xPortGetCoreID());
  while (!renderWorkerShutdown.load(std::memory_order_acquire)) {
    (void)ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(50));
    if (renderWorkerShutdown.load(std::memory_order_acquire))
      break;

    if (processPendingVectorMapActivation())
      continue;

    RenderRequest request;
    while (takeWorkerRequest(request)) {
      gMapRenderActiveSequence.store(request.version.sequence,
                                     std::memory_order_release);
      gMapRenderActiveCancellationGeneration.store(
          request.cancellationGeneration,
          std::memory_order_release);
      gMapRenderSliceCount.store(0, std::memory_order_relaxed);
      gMapRenderLongestSliceUs.store(0, std::memory_order_relaxed);
      gMapRenderLastCheckpointUs = micros();
      const uint32_t startMs = millis();
      RenderResult result;
      result.version = request.version;
      result.center = request.center;
      result.styleSignature = request.styleSignature;
      result.navigationSignature = request.navigationSignature;
      result.projectionSignature = request.projectionSignature;
      result.viewportWidth = request.viewportWidth;
      result.viewportHeight = request.viewportHeight;
      result.renderWidth = request.renderWidth;
      result.renderHeight = request.renderHeight;
      result.overscanPixels = request.overscanPixels;
      result.renderStridePixels = request.renderStridePixels;
      result.rotationRad = request.rotationRad;
      result.followPosition = request.context.followPosition;
      result.projection = makeRequestProjection(request);
      result.viewport.zoom = request.zoom;
      result.viewport.rasterOriginX = request.center.x;
      result.viewport.rasterOriginY = request.center.y;
      result.viewport.rasterCellOffsetX = 0;
      result.viewport.rasterCellOffsetY = 0;
      result.viewport.center = Point32(
          static_cast<int32_t>(std::round(request.center.x)),
          static_cast<int32_t>(std::round(request.center.y)));
      const auto worldBounds = result.projection.worldBounds(4.0);
      result.viewport.bbox.min = Point32(
          static_cast<int32_t>(std::floor(worldBounds.min.x)),
          static_cast<int32_t>(std::floor(worldBounds.min.y)));
      result.viewport.bbox.max = Point32(
          static_cast<int32_t>(std::ceil(worldBounds.max.x)),
          static_cast<int32_t>(std::ceil(worldBounds.max.y)));

      bool completed = false;
      {
        power_management::ScopedLock powerLock(
            power_management::LockDomain::Map);
        const uint32_t blocksStartMs = millis();
        const bool blocksLoaded =
            getMapBlocks(result.viewport.bbox, memCache);
        result.blocksMs = millis() - blocksStartMs;
        result.mapFound = isMapFound.load(std::memory_order_acquire);
        if (blocksLoaded && !shouldCancelMapRenderWork()) {
          const size_t requiredBytes = request.renderStridePixels *
                                       request.renderHeight * sizeof(uint16_t);
          if (bufMapTemp != nullptr && requiredBytes <= bufMapTempSize) {
            map_surface::Rgb565Surface target{
                static_cast<uint16_t *>(bufMapTemp), request.renderWidth,
                request.renderHeight, request.renderStridePixels};
            const uint32_t drawStartMs = millis();
            completed = readVectorMap(
                result.viewport, memCache, target, request.zoom,
                request.rotationRad, result.projection, request.context, true,
                false, &result.raster);
            result.drawMs = millis() - drawStartMs;
            if (completed) {
              if (result.mapFound) {
                logMapMemorySnapshot("canvas-draw");
              } else {
                logMapMemorySnapshot("canvas-no-map");
                logMapMemorySnapshot("canvas-draw-empty");
              }
            }
          } else {
            ESP_LOGE(TAG,
                     "Map render back buffer invariant failed required=%u "
                     "capacity=%u",
                     (unsigned)requiredBytes, (unsigned)bufMapTempSize);
          }
        }
      }
      result.durationMs = millis() - startMs;
      result.psramFree = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
      result.psramLargest =
          heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM);
#if FIRMWARE_DIAGNOSTICS
      if (completed) {
        renderer_diagnostics::RenderSample diagnosticsSample;
        diagnosticsSample.totalMs = result.durationMs;
        diagnosticsSample.blockLoadMs = result.blocksMs;
        diagnosticsSample.drawMs = result.drawMs;
        diagnosticsSample.buildingProjectionMs =
            result.raster.buildingProjectionMs;
        diagnosticsSample.buildingDrawMs = result.raster.buildingDrawMs;
        diagnosticsSample.buildings = {
            result.raster.candidateBuildings,
            result.raster.selectedBuildings,
            result.raster.extrudedBuildings,
            result.raster.flatBuildings,
            result.raster.deferredBuildings,
            result.raster.oversizedBuildings,
            result.raster.renderedBuildings,
            result.raster.extrudedP90DistancePx,
            result.raster.extrudedFarthestDistancePx,
            result.raster.buildingLimiterFlags,
            result.raster.allocationFallback,
        };
        renderer_diagnostics::noteRenderForWindow(
            request.context.rendererDiagnosticsWindowId,
            request.context.tuning.profile, diagnosticsSample);
      }
#endif

      if (renderStateMutex != nullptr &&
          xSemaphoreTake(renderStateMutex, portMAX_DELAY) == pdTRUE) {
        renderJobs.noteSlices(
            gMapRenderSliceCount.load(std::memory_order_relaxed),
            gMapRenderLongestSliceUs.load(std::memory_order_relaxed),
            MAP_RENDER_DECLARED_SLICE_US);
        const map_render_job::StopReason stopReason = renderJobs.checkpoint(
            renderWorkerShutdown.load(std::memory_order_acquire));
        const bool latest = stopReason == map_render_job::StopReason::None;
        if (completed && latest && renderJobs.completeActive()) {
          readyRenderResult = result;
          readyRenderResultValid = true;
          MAPIO_LOG(
              "MAPIO: render-ready seq=%lu durationMs=%lu blocksMs=%lu "
              "drawMs=%lu mapFound=%u selected=%lu extruded=%lu flat=%lu "
              "deferred=%lu allocationFallback=%u psramFree=%lu "
              "psramLargest=%lu\n",
              (unsigned long)result.version.sequence,
              (unsigned long)result.durationMs,
              (unsigned long)result.blocksMs,
              (unsigned long)result.drawMs, result.mapFound ? 1U : 0U,
              (unsigned long)result.raster.selectedBuildings,
              (unsigned long)result.raster.extrudedBuildings,
              (unsigned long)result.raster.flatBuildings,
              (unsigned long)result.raster.deferredBuildings,
              result.raster.allocationFallback ? 1U : 0U,
              (unsigned long)result.psramFree,
              (unsigned long)result.psramLargest);
        } else {
          renderJobs.cancelActive();
#if FIRMWARE_DIAGNOSTICS
          if (stopReason != map_render_job::StopReason::None)
            renderer_diagnostics::noteInterrupted();
#endif
          // Supersession and shutdown are normal scheduling events. Only an
          // actual render/invariant failure asks the UI to retry the last good
          // frame and records recovery diagnostics.
          if (!completed && latest) {
            renderFailurePending = true;
          }
          MAPIO_LOG(
              "MAPIO: render-cancel seq=%lu completed=%u reason=%u "
              "elapsedMs=%lu\n",
              (unsigned long)request.version.sequence,
              completed ? 1U : 0U, static_cast<unsigned>(stopReason),
              (unsigned long)(millis() - startMs));
        }
#if FIRMWARE_DIAGNOSTICS
        renderer_diagnostics::noteJobs(
            rendererJobCounters(renderJobs.diagnostics()));
#endif
        xSemaphoreGive(renderStateMutex);
      }

      if (renderWorkerShutdown.load(std::memory_order_acquire))
        break;
      taskYIELD();
      if (processPendingVectorMapActivation())
        break;
    }
  }

  if (renderStateMutex != nullptr &&
      xSemaphoreTake(renderStateMutex, portMAX_DELAY) == pdTRUE) {
    renderJobs.cancelActive();
    readyRenderResultValid = false;
    latestRenderRequestValid = false;
    renderWorkerTaskHandle = nullptr;
#if FIRMWARE_DIAGNOSTICS
    renderer_diagnostics::noteJobs(
        rendererJobCounters(renderJobs.diagnostics()));
#endif
    xSemaphoreGive(renderStateMutex);
  } else {
    renderWorkerTaskHandle = nullptr;
  }
  gMapRenderWorkerTaskHandle = nullptr;
  gMapRenderControlOperation.store(false, std::memory_order_release);
  renderWorkerExited.store(true, std::memory_order_release);
  MAPIO_LOG("MAPIO: render-worker stopped\n");
}

bool Maps::publishReadyFrame(uint32_t nowMs) {
  if (renderStateMutex == nullptr || canvasMap == nullptr ||
      canvasMapTemp == nullptr)
    return false;

  RenderResult result;
  map_render_job::Version publishedVersion;
  if (xSemaphoreTake(renderStateMutex, 0) != pdTRUE)
    return false;
  if (!readyRenderResultValid ||
      renderJobs.state() != map_render_job::State::Ready) {
    xSemaphoreGive(renderStateMutex);
    return false;
  }
  if (!renderResultStillCurrent(readyRenderResult)) {
    renderJobs.rejectReadyAsStale();
    readyRenderResultValid = false;
#if FIRMWARE_DIAGNOSTICS
    renderer_diagnostics::noteJobs(
        rendererJobCounters(renderJobs.diagnostics()));
#endif
    const TaskHandle_t worker = renderWorkerTaskHandle;
    xSemaphoreGive(renderStateMutex);
    if (worker != nullptr)
      xTaskNotifyGive(worker);
    MAPIO_LOG("MAPIO: render-stale rejected before publication\n");
    return false;
  }
  if (readyRenderResult.followPosition && hasPresentedPose) {
    const map_transform::WorldPoint current{presentedPose.position.x,
                                             presentedPose.position.y};
    const auto projected = readyRenderResult.projection.projectWorld(current);
    double desiredRotation = readyRenderResult.rotationRad;
    if (rotationMode == ROT_COURSE_UP && presentedPose.headingValid) {
      desiredRotation =
          -presentedPose.headingDegrees * 3.14159265358979323846 / 180.0;
    } else if (rotationMode == ROT_NORTH_UP) {
      desiredRotation = 0.0;
    }
    const double rotationDelta = map_presentation::signedHeadingDelta(
        readyRenderResult.rotationRad * 180.0 / 3.14159265358979323846,
        desiredRotation * 180.0 / 3.14159265358979323846) *
        3.14159265358979323846 / 180.0;
    const bool covered = projected.valid &&
        map_presentation::frameCoversViewport(
            readyRenderResult.renderWidth, readyRenderResult.renderHeight,
            readyRenderResult.viewportWidth, readyRenderResult.viewportHeight,
            {projected.x, projected.y},
            {readyRenderResult.projection.anchorX() -
                 readyRenderResult.overscanPixels,
             readyRenderResult.projection.anchorY() -
                 readyRenderResult.overscanPixels},
            rotationDelta, MAP_RENDER_SAFETY_PIXELS);
    if (!covered) {
      renderJobs.rejectReadyAsStale();
      readyRenderResultValid = false;
      isPosMoved = true;
      redrawMap = true;
#if FIRMWARE_DIAGNOSTICS
      renderer_diagnostics::noteCoverageRejected();
      renderer_diagnostics::noteJobs(
          rendererJobCounters(renderJobs.diagnostics()));
#endif
      const TaskHandle_t worker = renderWorkerTaskHandle;
      xSemaphoreGive(renderStateMutex);
      if (worker != nullptr)
        xTaskNotifyGive(worker);
      MAPIO_LOG("MAPIO: render-coverage rejected before publication\n");
      return false;
    }
  }
  const size_t requiredFrameBytes =
      static_cast<size_t>(readyRenderResult.renderStridePixels) *
      readyRenderResult.renderHeight * sizeof(uint16_t);
  if (readyRenderResult.renderWidth == 0 ||
      readyRenderResult.renderHeight == 0 ||
      readyRenderResult.renderStridePixels < readyRenderResult.renderWidth ||
      bufMapScreen == nullptr || bufMapTemp == nullptr ||
      requiredFrameBytes > bufMapScreenSize ||
      requiredFrameBytes > bufMapTempSize) {
    renderJobs.rejectReadyAsInvariant();
    readyRenderResultValid = false;
    renderFailurePending = true;
#if FIRMWARE_DIAGNOSTICS
    renderer_diagnostics::noteJobs(
        rendererJobCounters(renderJobs.diagnostics()));
#endif
    const TaskHandle_t worker = renderWorkerTaskHandle;
    ESP_LOGE(TAG,
             "Map render publication invariant failed required=%u front=%u "
             "back=%u dimensions=%ux%u stride=%u",
             (unsigned)requiredFrameBytes, (unsigned)bufMapScreenSize,
             (unsigned)bufMapTempSize,
             (unsigned)readyRenderResult.renderWidth,
             (unsigned)readyRenderResult.renderHeight,
             (unsigned)readyRenderResult.renderStridePixels);
    xSemaphoreGive(renderStateMutex);
    if (worker != nullptr)
      xTaskNotifyGive(worker);
    return false;
  }
  if (!renderJobs.takeReady(publishedVersion) ||
      publishedVersion != readyRenderResult.version) {
    readyRenderResultValid = false;
    xSemaphoreGive(renderStateMutex);
    return false;
  }
  result = readyRenderResult;
  readyRenderResultValid = false;
  std::swap(bufMapScreen, bufMapTemp);
  std::swap(bufMapScreenSize, bufMapTempSize);
  const map_render_job::Diagnostics jobDiagnostics = renderJobs.diagnostics();
#if FIRMWARE_DIAGNOSTICS
  renderer_diagnostics::noteJobs(rendererJobCounters(jobDiagnostics));
#endif
  xSemaphoreGive(renderStateMutex);

  const uint32_t swapStartedUs = micros();
  lv_canvas_set_buffer(canvasMap, bufMapScreen, result.renderWidth,
                       result.renderHeight, LV_COLOR_FORMAT_RGB565);
  lv_canvas_set_buffer(canvasMapTemp, bufMapTemp, result.renderWidth,
                       result.renderHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_add_flag(canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  // Raw worker rendering cannot touch LVGL. Re-apply the user-facing no-map
  // state on the UI owner after the complete frame is bound, instead of
  // silently replacing it with a blank background.
  if (!result.mapFound)
    showNoMap(canvasMap, storage.getSdLoaded());
  lv_img_set_angle(canvasMap, 0);
  lv_image_set_scale(canvasMap, LV_SCALE_NONE);
  lv_obj_clear_flag(canvasMap, LV_OBJ_FLAG_HIDDEN);
  visibleRenderResult = result;
  lastCompletedRenderDurationMs = std::max<uint32_t>(250U, result.durationMs);
  visibleProjection = result.projection;
  hasVisibleProjection = true;
  viewPort = result.viewport;
  publishedMapFound = result.mapFound;
  publishedMapFrame = true;
  framePublicationPending = true;

  totalBounds.lat_min = mercatorY2lat(result.viewport.bbox.min.y);
  totalBounds.lat_max = mercatorY2lat(result.viewport.bbox.max.y);
  totalBounds.lon_min = mercatorX2lon(result.viewport.bbox.min.x);
  totalBounds.lon_max = mercatorX2lon(result.viewport.bbox.max.x);
  if (isCoordInBounds(destLat, destLon, totalBounds)) {
    coords2map(destLat, destLon, totalBounds, &wptPosX, &wptPosY);
  } else {
    wptPosX = static_cast<uint16_t>(-1);
    wptPosY = static_cast<uint16_t>(-1);
  }

  finishDragSettlement();
  finishPinchSettlement();
  updatePresentedPose(nowMs);
  updatePresentedFrameTransform();
  renderLiveForeground();
  lv_obj_invalidate(canvasMap);
  const uint32_t swapDurationUs = micros() - swapStartedUs;
  MAPIO_LOG(
      "MAPIO: render-publish seq=%lu durationMs=%lu uiSwapUs=%lu "
      "mapFound=%u allocationFallback=%u cancelled=%lu stale=%lu "
      "invariant=%lu units=%lu longestUnitUs=%lu\n",
      (unsigned long)result.version.sequence,
      (unsigned long)result.durationMs, (unsigned long)swapDurationUs,
      result.mapFound ? 1U : 0U,
      result.raster.allocationFallback ? 1U : 0U,
      (unsigned long)jobDiagnostics.cancelled,
      (unsigned long)jobDiagnostics.stalePublications,
      (unsigned long)jobDiagnostics.invariantFailures,
      (unsigned long)jobDiagnostics.boundedSlices,
      (unsigned long)jobDiagnostics.longestSliceUs);

  if (renderWorkerTaskHandle != nullptr)
    xTaskNotifyGive(renderWorkerTaskHandle);
  return true;
}

void Maps::updatePresentedFrameTransform() {
  if (!publishedMapFrame || canvasMap == nullptr || !hasVisibleProjection)
    return;
  const map_transform::WorldPoint current =
      visibleRenderResult.followPosition && hasPresentedPose
          ? map_transform::WorldPoint{presentedPose.position.x,
                                      presentedPose.position.y}
          : visibleRenderResult.center;
  const auto projected = visibleProjection.projectWorld(current);
  if (!projected.valid)
    return;

  const int16_t pivotX = static_cast<int16_t>(
      map_transform::quantizePixel(projected.x));
  const int16_t pivotY = static_cast<int16_t>(
      map_transform::quantizePixel(projected.y));
  const uint16_t containerWidth = lv_obj_get_width(mapTile);
  const uint16_t containerHeight = lv_obj_get_height(mapTile);
  const int16_t viewportOriginX = gui_layout::centeredViewportOrigin(
      containerWidth, visibleRenderResult.viewportWidth);
  const int16_t viewportOriginY = gui_layout::centeredViewportOrigin(
      containerHeight, visibleRenderResult.viewportHeight);
  const int16_t screenAnchorX = static_cast<int16_t>(
      visibleRenderResult.projection.anchorX() -
      visibleRenderResult.overscanPixels);
  const int16_t screenAnchorY = static_cast<int16_t>(
      visibleRenderResult.projection.anchorY() -
      visibleRenderResult.overscanPixels);

  double desiredRotation = visibleRenderResult.rotationRad;
  if (rotationMode == ROT_COURSE_UP && hasPresentedPose &&
      presentedPose.headingValid) {
    desiredRotation =
        -presentedPose.headingDegrees * 3.14159265358979323846 / 180.0;
  } else if (rotationMode == ROT_NORTH_UP) {
    desiredRotation = 0.0;
  }
  const double rotationDelta = map_presentation::signedHeadingDelta(
      visibleRenderResult.rotationRad * 180.0 / 3.14159265358979323846,
      desiredRotation * 180.0 / 3.14159265358979323846) *
      3.14159265358979323846 / 180.0;
  // canvasMap remains LV_ALIGN_CENTER. Its style x/y are offsets from the
  // already-centered 658x658 overscan frame, not absolute parent coordinates.
  // Converting the desired parent-space pivot target into that aligned offset
  // prevents applying the 96 px overscan origin twice while the viewport-sized
  // route foreground and arrow use it once.
  const int32_t targetX = gui_layout::centerAlignedOffsetForPoint(
      containerWidth, visibleRenderResult.renderWidth, pivotX,
      viewportOriginX + screenAnchorX);
  const int32_t targetY = gui_layout::centerAlignedOffsetForPoint(
      containerHeight, visibleRenderResult.renderHeight, pivotY,
      viewportOriginY + screenAnchorY);
  const int16_t targetAngle = mapAngleTenths(rotationDelta);
  uint64_t presentationSignature = 1469598103934665603ULL;
  presentationSignature = fnvMix64(
      presentationSignature, visibleRenderResult.version.sequence);
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(projected.x));
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(projected.y));
  presentationSignature = fnvMix64(
      presentationSignature, static_cast<uint64_t>(containerWidth));
  presentationSignature = fnvMix64(
      presentationSignature, static_cast<uint64_t>(containerHeight));
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(rotationDelta));

  lv_point_t currentPivot{};
  lv_image_get_pivot(canvasMap, &currentPivot);
  const bool transformAlreadyApplied =
      currentPivot.x == pivotX && currentPivot.y == pivotY &&
      lv_obj_get_x_aligned(canvasMap) == targetX &&
      lv_obj_get_y_aligned(canvasMap) == targetY &&
      lv_img_get_angle(canvasMap) == targetAngle;
  if (presentationSignature == lastFramePresentationSignature &&
      transformAlreadyApplied) {
    return;
  }

  lv_image_set_pivot(canvasMap, pivotX, pivotY);
  lv_obj_set_pos(canvasMap, targetX, targetY);
  lv_img_set_angle(canvasMap, targetAngle);
  lv_obj_invalidate(canvasMap);

  const bool visibleCoversPose = map_presentation::frameCoversViewport(
      visibleRenderResult.renderWidth, visibleRenderResult.renderHeight,
      visibleRenderResult.viewportWidth, visibleRenderResult.viewportHeight,
      {projected.x, projected.y},
      {static_cast<double>(screenAnchorX),
       static_cast<double>(screenAnchorY)},
      rotationDelta, MAP_RENDER_SAFETY_PIXELS);

  RenderRequest latestRequestSnapshot;
  bool latestRequestSnapshotValid = false;
  if (renderStateMutex != nullptr &&
      xSemaphoreTake(renderStateMutex, 0) == pdTRUE) {
    latestRequestSnapshotValid = latestRenderRequestValid;
    if (latestRequestSnapshotValid)
      latestRequestSnapshot = latestRenderRequest;
    xSemaphoreGive(renderStateMutex);
  }

  bool latestCoversPose = false;
  if (latestRequestSnapshotValid &&
      renderRequestStillCurrent(latestRequestSnapshot)) {
    const auto latestProjection = makeRequestProjection(latestRequestSnapshot);
    const auto latestPoint = latestProjection.projectWorld(current);
    if (latestPoint.valid) {
      const double latestRotationDelta =
          map_presentation::signedHeadingDelta(
              latestRequestSnapshot.rotationRad * 180.0 /
                  3.14159265358979323846,
              desiredRotation * 180.0 / 3.14159265358979323846) *
          3.14159265358979323846 / 180.0;
      latestCoversPose = map_presentation::frameCoversViewport(
          latestRequestSnapshot.renderWidth,
          latestRequestSnapshot.renderHeight,
          latestRequestSnapshot.viewportWidth,
          latestRequestSnapshot.viewportHeight,
          {latestPoint.x, latestPoint.y},
          {latestProjection.anchorX() -
               latestRequestSnapshot.overscanPixels,
           latestProjection.anchorY() -
               latestRequestSnapshot.overscanPixels},
          latestRotationDelta, MAP_RENDER_SAFETY_PIXELS);
    }
  }
  if (!visibleCoversPose && !latestCoversPose) {
    isPosMoved = true;
    redrawMap = true;
  }
  lastFramePresentationSignature = presentationSignature;
}

void Maps::renderLiveForeground() {
  if (canvasForeground == nullptr) {
    lastForegroundPresentationSignature = 0;
    return;
  }
  const auto hideForeground = [this]() {
    lastForegroundPresentationSignature = 0;
    if (!lv_obj_has_flag(canvasForeground, LV_OBJ_FLAG_HIDDEN))
      lv_obj_add_flag(canvasForeground, LV_OBJ_FLAG_HIDDEN);
  };
  if (bufMapForeground == nullptr) {
    hideForeground();
    return;
  }
  const RouteSnapshot route = routeOverlay.snapshot();
  if (!publishedMapFrame || !hasVisibleProjection || !route.hasRoute() ||
      !isRouteOverlayVisible(mapRenderSettings) || !hasPresentedPose) {
    hideForeground();
    return;
  }
  const uint16_t width = mapScrWidth;
  const uint16_t height = mapSet.mapFullScreen ? mapScrFull : mapScrHeight;
  const size_t required = rgb565A8BufferSize(width, height);
  if (width == 0 || height == 0 || required > bufMapForegroundSize) {
    hideForeground();
    return;
  }

  const map_transform::WorldPoint presented{presentedPose.position.x,
                                             presentedPose.position.y};
  const map_transform::WorldPoint presentationPivotWorld =
      visibleRenderResult.followPosition ? presented : visibleRenderResult.center;
  const auto projectedPivot =
      visibleProjection.projectWorld(presentationPivotWorld);
  if (!projectedPivot.valid) {
    hideForeground();
    return;
  }

  double desiredRotation = visibleRenderResult.rotationRad;
  if (rotationMode == ROT_COURSE_UP && presentedPose.headingValid) {
    desiredRotation =
        -presentedPose.headingDegrees * 3.14159265358979323846 / 180.0;
  } else if (rotationMode == ROT_NORTH_UP) {
    desiredRotation = 0.0;
  }
  const double rotationDelta = map_presentation::signedHeadingDelta(
      visibleRenderResult.rotationRad * 180.0 / 3.14159265358979323846,
      desiredRotation * 180.0 / 3.14159265358979323846) *
      3.14159265358979323846 / 180.0;
  const uint8_t routeLineWidth = static_cast<uint8_t>(std::min<int>(
      48, std::max<int>(1, currentMapStyleSettings().routeLineWidth)));
  uint64_t presentationSignature = 1469598103934665603ULL;
  presentationSignature =
      fnvMix64(presentationSignature, route.revision);
  presentationSignature = fnvMix64(
      presentationSignature, visibleRenderResult.version.sequence);
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(presented.x));
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(presented.y));
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(projectedPivot.x));
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(projectedPivot.y));
  presentationSignature =
      fnvMix64(presentationSignature, doubleBits(rotationDelta));
  presentationSignature = fnvMix64(presentationSignature, width);
  presentationSignature = fnvMix64(presentationSignature, height);
  presentationSignature =
      fnvMix64(presentationSignature, routeLineWidth);
  if (presentationSignature == lastForegroundPresentationSignature &&
      !lv_obj_has_flag(canvasForeground, LV_OBJ_FLAG_HIDDEN)) {
    return;
  }

  bindMapForegroundCanvas(canvasForeground, width, height);
  lv_obj_center(canvasForeground);
  lv_img_set_angle(canvasForeground, 0);
  lv_image_set_scale(canvasForeground, LV_SCALE_NONE);

  lv_draw_buf_t *drawBuffer = lv_canvas_get_draw_buf(canvasForeground);
  if (drawBuffer == nullptr || drawBuffer->data == nullptr) {
    hideForeground();
    return;
  }
  const size_t colorStridePixels =
      static_cast<size_t>(drawBuffer->header.stride / sizeof(uint16_t));
  auto *alpha = static_cast<uint8_t *>(drawBuffer->data) +
                static_cast<size_t>(drawBuffer->header.stride) * height;
  map_surface::Rgb565A8Surface surface{
      reinterpret_cast<uint16_t *>(drawBuffer->data), alpha, width, height,
      colorStridePixels, colorStridePixels};
  surface.clearAlpha();

  // This is the exact transform used by updatePresentedFrameTransform(): the
  // immutable base projection supplies source pixels, the presented rider is
  // the pivot, and the viewport anchor is the target. Route head, route line,
  // arrow, and translated/rotated map therefore share one PresentedPose.
  RoutePresentationTransform presentation;
  presentation.inputPivotX = projectedPivot.x;
  presentation.inputPivotY = projectedPivot.y;
  presentation.outputPivotX =
      visibleProjection.anchorX() - visibleRenderResult.overscanPixels;
  presentation.outputPivotY =
      visibleProjection.anchorY() - visibleRenderResult.overscanPixels;
  presentation.rotationRad = rotationDelta;
  RouteOverlay::drawSnapshot(route, surface, visibleProjection, routeLineWidth,
                             &presented, &presentation);

  lv_obj_clear_flag(canvasForeground, LV_OBJ_FLAG_HIDDEN);
  lv_obj_invalidate(canvasForeground);
  lastForegroundPresentationSignature = presentationSignature;
  if (canvasArrow != nullptr)
    lv_obj_move_foreground(canvasArrow);
}

bool Maps::presentationGestureOwnsTransforms() const {
  return dragPreviewController.active() ||
         dragPreviewController.settlementPending() ||
         pinchPresentation.active || pinchPresentation.settlementPending;
}

bool Maps::serviceRenderPipeline(uint32_t nowMs) {
  (void)recoverRenderWorkerIfNeeded();
  if (canvasMap == nullptr)
    return false;
  invalidateRenderSemantics(nowMs);
  updatePresentedPose(nowMs);
  const bool gestureActive = dragPreviewController.active() ||
                             pinchPresentation.active;
  const bool settlementPending =
      dragPreviewController.settlementPending() ||
      pinchPresentation.settlementPending;
  // An active gesture owns the image pivot/position/scale and its marker. Keep
  // a ready worker frame hidden until release. During settlement, publication
  // is the event that ends ownership; until a replacement is ready, preserve
  // the exact preview endpoint instead of snapping back to follow mode.
  const bool published = gestureActive ? false : publishReadyFrame(nowMs);
  if (gestureActive || (settlementPending && !published))
    return false;
  updatePresentedFrameTransform();
  renderLiveForeground();
  return published;
}

bool Maps::hasPendingRenderForCurrentScreen() const {
  if (renderStateMutex == nullptr)
    return false;
  if (xSemaphoreTake(renderStateMutex, 0) != pdTRUE) {
    // The worker holds this mutex only around short state transitions. Treat a
    // transient miss as pending so a BOOT press cannot supersede a render-ahead
    // frame at the instant it becomes ready.
    return true;
  }

  const map_render_job::State state = renderJobs.state();
  const bool queued = latestRenderRequestValid &&
                      (state == map_render_job::State::Rendering ||
                       state == map_render_job::State::Ready ||
                       renderJobs.hasRequestNewerThan(lastTakenRenderSequence));
  const bool current =
      queued && renderRequestStillCurrent(latestRenderRequest);
  xSemaphoreGive(renderStateMutex);
  return current;
}

bool Maps::takeFramePublication() {
  const bool pending = framePublicationPending;
  framePublicationPending = false;
  return pending;
}

bool Maps::takeRenderFailure() {
  if (renderStateMutex == nullptr)
    return false;
  if (xSemaphoreTake(renderStateMutex, 0) != pdTRUE)
    return false;
  const bool pending = renderFailurePending;
  renderFailurePending = false;
  xSemaphoreGive(renderStateMutex);
  return pending;
}

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
  String normalized(folder.c_str());
  if (!normalized.endsWith("/"))
    normalized += "/";
  if (normalized == vectorMapFolder)
    return true;

  const bool restartWorker = renderWorkerTaskHandle != nullptr;
  if (restartWorker && !stopRenderWorker()) {
    ESP_LOGE(TAG, "Vector map root switch deferred: render worker is busy");
    return false;
  }

  const bool switched = switchVectorMapFolderOnStorageOwner(folder);
  if (switched)
    finalizeVectorMapFolderSwitchOnUi();
  if (restartWorker && !startRenderWorker()) {
    ESP_LOGE(TAG, "Vector map root switched but render worker restart failed");
    return false;
  }
  if (switched)
    ESP_LOGI(TAG, "Vector map root switched to %s", vectorMapFolder.c_str());
  return switched;
}

bool Maps::switchVectorMapFolderOnStorageOwner(const std::string &folder) {
  String normalized(folder.c_str());
  if (!normalized.endsWith("/"))
    normalized += "/";
  if (normalized == vectorMapFolder)
    return true;

  struct stat storageMetadata = {};
  if (::stat(normalized.c_str(), &storageMetadata) != 0 ||
      !S_ISDIR(storageMetadata.st_mode)) {
    ESP_LOGE(TAG, "Vector map root is unavailable: %s", normalized.c_str());
    return false;
  }

  map_font_asset::Asset candidateFont;
  const std::string fontPath =
      std::string(normalized.c_str()) + "assets/street-labels.fma";
  struct stat fontMetadata = {};
  if (::stat(fontPath.c_str(), &fontMetadata) == 0 &&
      (!S_ISREG(fontMetadata.st_mode) || !candidateFont.open(fontPath))) {
    ESP_LOGE(TAG, "Street-label font asset is invalid: %s", fontPath.c_str());
    return false;
  }

  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  for (MapBlock *block : memCache.blocks)
    delete block;
  memCache.blocks.clear();
  cachedBlockCount.store(0, std::memory_order_release);
  labelFontAsset = std::move(candidateFont);
  streetLabelFontHealthy.store(labelFontAsset.healthy(),
                               std::memory_order_release);
  labelLayoutCache.clear();
  streetLabelRuntimeFailure.store(map_font_asset::RuntimeError::None,
                                  std::memory_order_release);
  buildingFailureRetryCooldown.clear();
  vectorMapFolder = normalized;
  isMapFound = false;
  return true;
}

void Maps::finalizeVectorMapFolderSwitchOnUi() {
  ++mapEpoch;
  invalidateRollingRasterWindow();
  publishedMapFound = false;
  publishedMapFrame = false;
  isPosMoved = true;
  redrawMap = true;
  oldMapTile = {};
  currentMapTile = {};
}

bool Maps::takeStreetLabelRuntimeFailure(std::string &code) {
  const map_font_asset::RuntimeError error = streetLabelRuntimeFailure.exchange(
      map_font_asset::RuntimeError::None, std::memory_order_acq_rel);
  if (error == map_font_asset::RuntimeError::None)
    return false;
  code = map_font_asset::runtimeErrorCode(error);
  return true;
}

bool Maps::probeVectorMapFolder(const std::string &folder) {
  const bool restartWorker = renderWorkerTaskHandle != nullptr;
  if (restartWorker && !stopRenderWorker()) {
    ESP_LOGE(TAG, "Vector map probe deferred: render worker is busy");
    return false;
  }

  const bool loaded = probeVectorMapFolderOnStorageOwner(folder);

  if (restartWorker && !startRenderWorker()) {
    ESP_LOGE(TAG, "Vector map probe completed but worker restart failed");
    return false;
  }
  return loaded;
}

bool Maps::probeVectorMapFolderOnStorageOwner(const std::string &folder) {
  std::string normalized = folder;
  while (normalized.size() > 1 && normalized.back() == '/')
    normalized.pop_back();
  struct stat storageMetadata = {};
  if (::stat(normalized.c_str(), &storageMetadata) != 0 ||
      !S_ISDIR(storageMetadata.st_mode))
    return false;

  bool loaded = false;
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  size_t visited = 0;
  std::string blockBase;
  if (!findMapBlock(normalized, blockBase, visited, 0)) {
    ESP_LOGE(TAG, "No map block found under %s", normalized.c_str());
    return false;
  }

  const bool previousMapFound = isMapFound.load();
  isMapFound = false;
  MapBlock *block = readMapBlock(String(blockBase.c_str()));
  loaded = block != nullptr && isMapFound.load();
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

bool Maps::requestVectorMapFolderActivation(const std::string &folder) {
  if (folder.empty())
    return false;
  if (renderWorkerRestartAfterExit.load(std::memory_order_acquire) &&
      !recoverRenderWorkerIfNeeded())
    return false;
  if (renderWorkerTaskHandle == nullptr && !startRenderWorker())
    return false;
  if (renderWorkerShutdown.load(std::memory_order_acquire))
    return false;
  if (renderStateMutex == nullptr ||
      xSemaphoreTake(renderStateMutex, pdMS_TO_TICKS(5)) != pdTRUE)
    return false;
  if (pendingVectorMapActivationValid || completedVectorMapActivationValid) {
    xSemaphoreGive(renderStateMutex);
    return false;
  }

  pendingVectorMapActivation.sequence = ++vectorMapActivationSequence;
  pendingVectorMapActivation.folder = folder;
  pendingVectorMapActivationValid = true;
  gMapRenderCancellationGeneration.fetch_add(1, std::memory_order_acq_rel);
  renderJobs.requestCancellation();
  if (renderJobs.state() == map_render_job::State::Ready) {
    renderJobs.rejectReadyAsStale();
    readyRenderResultValid = false;
  }
  const TaskHandle_t worker = renderWorkerTaskHandle;
  xSemaphoreGive(renderStateMutex);
  if (worker != nullptr)
    xTaskNotifyGive(worker);
  return true;
}

bool Maps::takeVectorMapActivationRequest(
    VectorMapActivationRequest &request) {
  if (renderStateMutex == nullptr ||
      xSemaphoreTake(renderStateMutex, portMAX_DELAY) != pdTRUE)
    return false;
  const bool available = pendingVectorMapActivationValid &&
                         !completedVectorMapActivationValid;
  if (available) {
    request = pendingVectorMapActivation;
    pendingVectorMapActivation = {};
    pendingVectorMapActivationValid = false;
  }
  xSemaphoreGive(renderStateMutex);
  return available;
}

bool Maps::processPendingVectorMapActivation() {
  VectorMapActivationRequest request;
  if (!takeVectorMapActivationRequest(request))
    return false;

  // Control-plane storage work runs on the same sole owner as block rendering,
  // but starts a fresh cooperative token after the render it superseded has
  // quiesced. No SD traversal or block parsing runs in the LVGL loop.
  gMapRenderActiveCancellationGeneration.store(
      gMapRenderCancellationGeneration.load(std::memory_order_acquire),
      std::memory_order_release);
  gMapRenderControlOperation.store(true, std::memory_order_release);
  const bool loaded = probeVectorMapFolderOnStorageOwner(request.folder) &&
                      switchVectorMapFolderOnStorageOwner(request.folder);
  gMapRenderControlOperation.store(false, std::memory_order_release);

  if (renderStateMutex != nullptr &&
      xSemaphoreTake(renderStateMutex, portMAX_DELAY) == pdTRUE) {
    completedVectorMapActivation =
        {request.sequence, request.folder, loaded};
    completedVectorMapActivationValid = true;
    latestRenderRequestValid = false;
    xSemaphoreGive(renderStateMutex);
  }
  MAPIO_LOG("MAPIO: activation-ready sequence=%lu loaded=%u root=%s\n",
            (unsigned long)request.sequence, loaded ? 1U : 0U,
            request.folder.c_str());
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  return true;
}

bool Maps::takeVectorMapFolderActivationResult(
    VectorMapActivationResult &result) {
  if (renderStateMutex == nullptr ||
      xSemaphoreTake(renderStateMutex, 0) != pdTRUE)
    return false;
  if (!completedVectorMapActivationValid) {
    xSemaphoreGive(renderStateMutex);
    return false;
  }
  result.folder = completedVectorMapActivation.folder;
  result.loaded = completedVectorMapActivation.loaded;
  completedVectorMapActivation = {};
  completedVectorMapActivationValid = false;
  xSemaphoreGive(renderStateMutex);

  if (result.loaded)
    finalizeVectorMapFolderSwitchOnUi();
  else {
    // Enqueuing the control job cancels any render that was using the old
    // storage snapshot.  A failed probe leaves that old root selected, so
    // explicitly request a replacement frame instead of waiting for a later
    // movement/heading threshold to happen to revive the renderer.
    isPosMoved = true;
    redrawMap = true;
  }
  if (renderWorkerTaskHandle != nullptr)
    xTaskNotifyGive(renderWorkerTaskHandle);
  return true;
}

/**
 * @brief Delete map screen and release PSRAM
 *
 */
void Maps::deleteMapScrSprites() {
  cancelDragPreview();
  cancelPinchPreview();
  pinchZoomOutBackdrop = {};
  invalidateRollingRasterWindow();

  // The worker owns only raw back-buffer/cache state and may outlive this LVGL
  // screen. Cancel the semantic request without blocking the UI task; stale
  // completion is rejected before publication when the screen is recreated.
  ++projectionEpoch;
  if (renderStateMutex != nullptr &&
      xSemaphoreTake(renderStateMutex, pdMS_TO_TICKS(5)) == pdTRUE) {
    gMapRenderCancellationGeneration.fetch_add(1, std::memory_order_acq_rel);
    renderJobs.requestCancellation();
    const map_render_job::Version invalidated = renderJobs.invalidate();
    gMapRenderLatestSequence.store(invalidated.sequence,
                                   std::memory_order_release);
    latestRenderRequestValid = false;
    readyRenderResultValid = false;
    xSemaphoreGive(renderStateMutex);
  } else {
    // The worker also checks this atomic token between bounded work units. If
    // the mutex is momentarily busy, publication still rejects the obsolete
    // projection epoch before the frame can become visible.
    gMapRenderCancellationGeneration.fetch_add(1, std::memory_order_acq_rel);
    gMapRenderLatestSequence.fetch_add(1, std::memory_order_acq_rel);
  }

  hasVisibleProjection = false;
  publishedMapFrame = false;
  publishedMapFound = false;
  framePublicationPending = false;
  lastFramePresentationSignature = 0;
  lastForegroundPresentationSignature = 0;
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

  const uint16_t viewportWidth = Maps::mapScrWidth;
  const uint16_t viewportHeight =
      mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
  const uint16_t maximumRenderWidth = static_cast<uint16_t>(
      Maps::mapScrWidth + MAP_RENDER_OVERSCAN_PIXELS * 2U);
  const uint16_t maximumRenderHeight = static_cast<uint16_t>(
      Maps::mapScrFull + MAP_RENDER_OVERSCAN_PIXELS * 2U);
  const uint16_t initialRenderHeight = static_cast<uint16_t>(
      viewportHeight + MAP_RENDER_OVERSCAN_PIXELS * 2U);
  const uint32_t frameStride = lv_draw_buf_width_to_stride(
      maximumRenderWidth, LV_COLOR_FORMAT_RGB565);
  const size_t frameBytes =
      static_cast<size_t>(frameStride) * maximumRenderHeight;
  const size_t foregroundBytes =
      rgb565A8BufferSize(Maps::mapScrWidth, Maps::mapScrFull);
  const size_t persistentSurfaceBytes = frameBytes * 2U + foregroundBytes;

  // Recreating LVGL objects is safe while the worker writes the hidden raw
  // back surface: the addresses remain stable and the object stays hidden.
  // Quiesce only when a front/back allocation must actually move. This keeps
  // an ordinary screen transition out of the render job's SD/geometry latency.
  const bool frameStorageMustMove =
      bufMapScreen == nullptr || bufMapScreenSize < frameBytes ||
      bufMapTemp == nullptr || bufMapTempSize < frameBytes;
  const bool workerCanOwnFrameStorage =
      bufMapScreen != nullptr && bufMapTemp != nullptr;
  if (frameStorageMustMove && workerCanOwnFrameStorage &&
      renderWorkerTaskHandle != nullptr &&
      !stopRenderWorker()) {
    ESP_LOGE(TAG, "Map screen creation deferred: render worker owns storage");
    return;
  }
  if (canvasMap != nullptr || canvasMapTemp != nullptr ||
      canvasForeground != nullptr || canvasArrow != nullptr) {
    deleteMapScrSprites();
  }

  if (!ensureMapScreenBuffer(frameBytes) || !ensureMapTempBuffer(frameBytes) ||
      !ensureMapForegroundBuffer(Maps::mapScrWidth, Maps::mapScrFull)) {
    ESP_LOGE(TAG,
             "Map render surfaces unavailable frame=%u foreground=%u total=%u",
             (unsigned)frameBytes, (unsigned)foregroundBytes,
             (unsigned)persistentSurfaceBytes);
    return;
  }
  memset(bufMapForeground, 0, foregroundBytes);
  invalidateRollingRasterWindow();
  invalidatePinchZoomOutBackdrop();
  publishedMapFrame = false;
  publishedMapFound = false;
  framePublicationPending = false;
  hasVisibleProjection = false;
  lastFramePresentationSignature = 0;
  lastForegroundPresentationSignature = 0;
  ++projectionEpoch;

  Maps::canvasMap = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_flag(Maps::canvasMap, LV_OBJ_FLAG_HIDDEN);
  lv_canvas_set_buffer(Maps::canvasMap, bufMapScreen, maximumRenderWidth,
                       initialRenderHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMap);

  // This object is always hidden. Its raw storage is exclusively written by
  // the render worker; only the LVGL owner rebinds it after an atomic swap.
  Maps::canvasMapTemp = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasMapTemp, LV_OBJ_FLAG_HIDDEN);
  lv_canvas_set_buffer(Maps::canvasMapTemp, bufMapTemp, maximumRenderWidth,
                       initialRenderHeight, LV_COLOR_FORMAT_RGB565);
  lv_obj_center(Maps::canvasMapTemp);

  Maps::canvasForeground = lv_canvas_create(mapTile);
  lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
  bindMapForegroundCanvas(Maps::canvasForeground, viewportWidth,
                          viewportHeight);
  lv_obj_center(Maps::canvasForeground);

  Maps::canvasArrow = lv_obj_create(mapTile);
  lv_obj_remove_style_all(Maps::canvasArrow);
  lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_event_cb(Maps::canvasArrow, drawCurrentPositionMarker,
                      LV_EVENT_DRAW_MAIN, nullptr);
  updateCurrentPositionMarker(Maps::canvasArrow, 0.0, true);

  if (!startRenderWorker()) {
    ESP_LOGE(TAG, "Map render worker unavailable");
    deleteMapScrSprites();
    return;
  }

  isPosMoved = true;
  redrawMap = true;
  ESP_LOGI(TAG,
           "Map render surfaces front=%u back=%u foreground=%u total=%u "
           "psramFree=%u psramLargest=%u",
           (unsigned)frameBytes, (unsigned)frameBytes,
           (unsigned)foregroundBytes, (unsigned)persistentSurfaceBytes,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_SPIRAM));
  ESP_LOGI(TAG, "createMapScrSprites done");
}

bool Maps::shouldUseRollingRasterWindow(uint8_t requestedZoom) const {
  (void)requestedZoom;
  // The previous rolling raster synchronously loaded/rendered cells from the
  // LVGL task and shared the worker back buffer. Render-ahead overscan now
  // provides motion margin without violating ownership.
  return false;
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

  const bool previousMapFound =
      Maps::isMapFound.load(std::memory_order_acquire);
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

  if (shouldCancelMapRenderWork()) {
    restoreVisibleState();
    return false;
  }

  if (mapFoundOut != nullptr)
    *mapFoundOut = Maps::isMapFound.load(std::memory_order_acquire);
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
  if (style.labelDensity != 0 &&
      streetLabelFontHealthy.load(std::memory_order_acquire)) {
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
    cachedBlockCount.store(0, std::memory_order_release);
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
  (void)baseZoom;
  return false;
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
}

bool Maps::preparePinchZoomOutBackdrop(uint8_t baseZoom) {
  (void)baseZoom;
  // A second synchronous vector render into the worker-owned back buffer is
  // forbidden. Pinch preview scales the last complete front frame; release
  // submits a normal latest-wins render at the target zoom.
  return false;
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

  if (Maps::canvasForeground != nullptr)
    lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
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
  lastFramePresentationSignature = 0;
  lastForegroundPresentationSignature = 0;
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
  if (Maps::canvasForeground != nullptr)
    lv_obj_add_flag(Maps::canvasForeground, LV_OBJ_FLAG_HIDDEN);
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
    const double markerCenterX = pinchPresentation.markerBaseX + 24.0;
    const double markerCenterY = pinchPresentation.markerBaseY + 24.0;
    const int16_t transformedX = static_cast<int16_t>(std::round(
        pivotX + ((markerCenterX - pivotX) * ratio) + translationX - 24.0));
    const int16_t transformedY = static_cast<int16_t>(std::round(
        pivotY + ((markerCenterY - pivotY) * ratio) + translationY - 24.0));
    lv_obj_set_pos(Maps::canvasArrow, transformedX, transformedY);
  }
  lv_obj_invalidate(Maps::canvasMap);
  if (Maps::canvasArrow != nullptr)
    lv_obj_invalidate(Maps::canvasArrow);
}

void Maps::resetPinchPresentationVisuals() {
  lastFramePresentationSignature = 0;
  lastForegroundPresentationSignature = 0;
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
  if (!Maps::canvasArrow)
    return;

  updateCurrentPositionMarker(Maps::canvasArrow, 0.0, true);
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

void Maps::updatePositionOverlay() {
  const uint32_t displayStartMs = MAPIO_TIME_MS();
  // Drag/pinch preview code owns the marker transform together with the base
  // image. A normal 30 ms presentation tick must not overwrite that preview
  // or its settlement endpoint while a replacement frame is pending.
  if (presentationGestureOwnsTransforms())
    return;
  // Update Arrow Position
  if (Maps::canvasArrow) {
    if (!publishedMapFound || !isCurrentPositionVisible(mapRenderSettings)) {
      lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      return;
    }
    const bool navigationActive =
        routeOverlay.hasRoute() || hasCurrentNavigationData();
    if (navigationActive &&
        (!hasPresentedPose || !presentedPose.headingValid)) {
      // A navigation glyph has directional meaning. Until the new session has
      // a measured course, route bearing, or remembered in-session course,
      // hiding it is the only honest presentation; zero degrees would recreate
      // the false-north bug that the explicit heading contract removes.
      lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      return;
    }

    uint16_t h = mapSet.mapFullScreen ? Maps::mapScrFull : Maps::mapScrHeight;
    const uint16_t containerWidth = lv_obj_get_width(mapTile);
    const uint16_t containerHeight = lv_obj_get_height(mapTile);
    const int16_t mapOriginX =
        gui_layout::centeredViewportOrigin(containerWidth, Maps::mapScrWidth);
    const int16_t mapOriginY =
        gui_layout::centeredViewportOrigin(containerHeight, h);
    const bool useSharedProjection = hasVisibleProjection;
    const int16_t anchorX = useSharedProjection
                                ? static_cast<int16_t>(
                                      map_transform::quantizePixel(
                                          visibleProjection.anchorX()) -
                                      visibleRenderResult.overscanPixels)
                                : mapAnchorXForWidth(Maps::mapScrWidth);
    const int16_t anchorY = useSharedProjection
                                ? static_cast<int16_t>(
                                      map_transform::quantizePixel(
                                          visibleProjection.anchorY()) -
                                      visibleRenderResult.overscanPixels)
                                : mapAnchorYForHeight(h);
    double displayedMapRotation = visibleRenderResult.rotationRad;
    if (rotationMode == ROT_COURSE_UP && hasPresentedPose &&
        presentedPose.headingValid) {
      displayedMapRotation =
          -presentedPose.headingDegrees * 3.14159265358979323846 / 180.0;
    } else if (rotationMode == ROT_NORTH_UP) {
      displayedMapRotation = 0.0;
    }
    const double markerRotation =
        hasPresentedPose && presentedPose.headingValid
            ? map_presentation::markerRotationDegrees(
                  presentedPose.headingDegrees, displayedMapRotation)
            : 0.0;
    updateCurrentPositionMarker(Maps::canvasArrow, markerRotation);
    const int16_t markerVisualHalf = currentMarkerSize() / 2;
    int16_t x, y;

    if (Maps::followGps) {
      // The marker is a sibling of the centered map canvas, so translate the
      // canvas-local anchor into map-tile coordinates before applying the
      // marker's center offset.
      x = mapOriginX + anchorX - markerVisualHalf;
      y = mapOriginY + anchorY - markerVisualHalf;
      lv_obj_clear_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
      lv_obj_set_pos(Maps::canvasArrow, x, y);
    } else {
      // Calculate position relative to viewport center
      // Convert GPS lat/lon to Mercator coordinates
      int32_t gpsX = lon2x(gps.gpsData.longitude);
      int32_t gpsY = lat2y(gps.gpsData.latitude);

      if (useSharedProjection) {
        const auto markerPoint = visibleProjection.projectWorld(
            {static_cast<double>(gpsX), static_cast<double>(gpsY)});
        const map_transform::WorldPoint pivotWorld =
            visibleRenderResult.followPosition && hasPresentedPose
                ? map_transform::WorldPoint{presentedPose.position.x,
                                            presentedPose.position.y}
                : visibleRenderResult.center;
        const auto projectedPivot = visibleProjection.projectWorld(pivotWorld);
        if (!markerPoint.valid || !projectedPivot.valid) {
          lv_obj_add_flag(Maps::canvasArrow, LV_OBJ_FLAG_HIDDEN);
          return;
        }

        double desiredRotation = visibleRenderResult.rotationRad;
        if (rotationMode == ROT_COURSE_UP && hasPresentedPose &&
            presentedPose.headingValid) {
          desiredRotation = -presentedPose.headingDegrees *
                            3.14159265358979323846 / 180.0;
        } else if (rotationMode == ROT_NORTH_UP) {
          desiredRotation = 0.0;
        }
        const double rotationDelta = map_presentation::signedHeadingDelta(
            visibleRenderResult.rotationRad * 180.0 /
                3.14159265358979323846,
            desiredRotation * 180.0 / 3.14159265358979323846) *
            3.14159265358979323846 / 180.0;
        const auto presentedPoint = map_presentation::presentFramePoint(
            {markerPoint.x, markerPoint.y},
            {projectedPivot.x, projectedPivot.y},
            {visibleProjection.anchorX() -
                 visibleRenderResult.overscanPixels,
             visibleProjection.anchorY() -
                 visibleRenderResult.overscanPixels},
            rotationDelta);
        x = mapOriginX + map_transform::quantizePixel(presentedPoint.x) -
            markerVisualHalf;
        y = mapOriginY + map_transform::quantizePixel(presentedPoint.y) -
            markerVisualHalf;
      } else {
        const auto markerDelta = map_transform::worldToScreen(
            {static_cast<double>(gpsX - Maps::viewPort.center.x),
             static_cast<double>(gpsY - Maps::viewPort.center.y)},
            zoom, visibleMapRotation());
        x = mapOriginX + round(markerDelta.x) + anchorX - markerVisualHalf;
        y = mapOriginY + round(markerDelta.y) + anchorY - markerVisualHalf;
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
  MAPIO_LOG("MAPIO: display invalidateMs=%lu hasCanvas=%d hasArrow=%d\n",
            (unsigned long)(MAPIO_TIME_MS() - displayStartMs),
            Maps::canvasMap != nullptr, Maps::canvasArrow != nullptr);
}

/**
 * @brief Generate Vector Map
 *
 * @param zoom -> Zoom Level
 */
bool Maps::generateVectorMap(uint8_t requestedZoom) {
  (void)recoverRenderWorkerIfNeeded();
  if (canvasMap == nullptr || canvasMapTemp == nullptr ||
      renderWorkerTaskHandle == nullptr) {
    return false;
  }

  mapTileSize = vectorMapTileSize;
  zoomLevel = map_transform::clampRuntimeZoom(requestedZoom);
  RenderRequest request;
  if (!buildRenderRequest(zoomLevel, millis(), request)) {
    // Course-up deliberately holds the last good frame until either a valid
    // measured course or route-segment bearing exists. This is a deferred
    // state, not an allocation/render failure and must never become north-up.
    // Return false so the UI scheduler does not mark a request as submitted or
    // clear the dirty state when no immutable job was actually queued.
    return false;
  }
  return submitRenderRequest(request);
}

bool Maps::prepareVectorMapForScreen(uint8_t requestedZoom,
                                     bool guidanceScreenActive) {
  (void)recoverRenderWorkerIfNeeded();
  if (canvasMap == nullptr || canvasMapTemp == nullptr ||
      renderWorkerTaskHandle == nullptr) {
    return false;
  }

  mapTileSize = vectorMapTileSize;
  zoomLevel = map_transform::clampRuntimeZoom(requestedZoom);
  RenderRequest request;
  if (!buildRenderRequestForScreen(zoomLevel, millis(), true,
                                   guidanceScreenActive, request)) {
    return false;
  }
  return submitRenderRequest(request);
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
