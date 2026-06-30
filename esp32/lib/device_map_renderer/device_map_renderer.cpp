#include "device_map_renderer.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <esp_heap_caps.h>

DeviceMapRenderer deviceMapRenderer;

extern "C" void handle_display_toggle_event(lv_event_t *event);

namespace {
constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr double EARTH_RADIUS = 6378137.0;

void drawLine(lv_obj_t *canvas, int16_t x1, int16_t y1, int16_t x2, int16_t y2,
              lv_color_t color, uint8_t width) {
  lv_draw_line_dsc_t line;
  lv_draw_line_dsc_init(&line);
  line.color = color;
  line.width = width;
  line.round_start = true;
  line.round_end = true;
  line.opa = LV_OPA_COVER;
  lv_point_t points[] = {{x1, y1}, {x2, y2}};
  lv_canvas_draw_line(canvas, points, 2, &line);
}
} // namespace

void DeviceMapRenderer::init(lv_obj_t *parent, uint16_t width, uint16_t height) {
  canvasWidth = width;
  canvasHeight = height;
  canvas = lv_canvas_create(parent);
  lv_obj_set_size(canvas, width, height);
  lv_obj_align(canvas, LV_ALIGN_CENTER, 0, 0);
  lv_obj_clear_flag(canvas, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(canvas, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_event_cb(canvas, handle_display_toggle_event, LV_EVENT_CLICKED, NULL);
  lv_obj_add_flag(canvas, LV_OBJ_FLAG_HIDDEN);

  canvasBuffer = static_cast<lv_color_t *>(heap_caps_malloc(
      width * height * sizeof(lv_color_t), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (canvasBuffer == nullptr) {
    Serial.println("Map renderer: failed to allocate canvas buffer");
    return;
  }

  lv_canvas_set_buffer(canvas, canvasBuffer, width, height, LV_IMG_CF_TRUE_COLOR);
  lv_canvas_fill_bg(canvas, lv_color_hex(0x111111), LV_OPA_COVER);
}

void DeviceMapRenderer::setVisible(bool visible) {
  mapVisible = visible;
  if (canvas == nullptr) {
    return;
  }

  if (visible) {
    lv_obj_clear_flag(canvas, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(canvas);
    requestRedraw();
  } else {
    lv_obj_add_flag(canvas, LV_OBJ_FLAG_HIDDEN);
  }
}

void DeviceMapRenderer::toggleVisible() { setVisible(!mapVisible); }

void DeviceMapRenderer::setRouteGeometry(const uint8_t *data, size_t len) {
  if (data == nullptr || len < 8) {
    clearRoute();
    return;
  }

  GeoPoint parsed[MAX_ROUTE_POINTS];
  int32_t lat = 0;
  int32_t lon = 0;
  memcpy(&lat, data, sizeof(lat));
  memcpy(&lon, data + 4, sizeof(lon));
  parsed[0] = {lat, lon};
  size_t parsedCount = 1;

  size_t offset = 8;
  while (offset + 4 <= len && parsedCount < MAX_ROUTE_POINTS) {
    int16_t deltaLat = 0;
    int16_t deltaLon = 0;
    memcpy(&deltaLat, data + offset, sizeof(deltaLat));
    memcpy(&deltaLon, data + offset + 2, sizeof(deltaLon));
    lat += deltaLat;
    lon += deltaLon;
    parsed[parsedCount++] = {lat, lon};
    offset += 4;
  }

  portENTER_CRITICAL(&stateMux);
  memcpy(routePoints, parsed, parsedCount * sizeof(GeoPoint));
  routePointCount = parsedCount;
  portEXIT_CRITICAL(&stateMux);

  Serial.printf("Map renderer: route geometry loaded (%u points)\n",
                static_cast<unsigned>(parsedCount));
  requestRedraw();
}

void DeviceMapRenderer::clearRoute() {
  portENTER_CRITICAL(&stateMux);
  routePointCount = 0;
  portEXIT_CRITICAL(&stateMux);
  requestRedraw();
}

void DeviceMapRenderer::setGpsPosition(int32_t latMicro, int32_t lonMicro,
                                       uint16_t headingDeg) {
  portENTER_CRITICAL(&stateMux);
  gpsPoint = {latMicro, lonMicro};
  hasGpsPoint = true;
  gpsHeadingDeg = headingDeg;
  portEXIT_CRITICAL(&stateMux);
  requestRedraw();
}

void DeviceMapRenderer::setSetting(uint8_t settingId, int32_t value) {
  portENTER_CRITICAL(&stateMux);
  switch (settingId) {
  case 1:
    settings.minPolygonSize = static_cast<uint8_t>(constrain(value, 0, 50));
    break;
  case 2:
    settings.detailLevel = static_cast<uint8_t>(constrain(value, 0, 2));
    break;
  case 3:
    settings.routeLineWidth = static_cast<uint8_t>(constrain(value, 2, 8));
    break;
  case 4:
    settings.displayRotation = static_cast<uint8_t>(constrain(value, 0, 3));
    break;
  case 6:
    settings.mapRotationMode = static_cast<uint8_t>(constrain(value, 0, 1));
    break;
  case 7:
    settings.zoomLevel = static_cast<uint8_t>(constrain(value, 0, 5));
    break;
  case 8:
    settings.visibilityMask = static_cast<uint32_t>(value);
    break;
  default:
    break;
  }
  portEXIT_CRITICAL(&stateMux);
  requestRedraw();
}

void DeviceMapRenderer::setStatusDetail(const char *detail) {
  portENTER_CRITICAL(&stateMux);
  if (detail == nullptr || detail[0] == '\0') {
    statusDetail[0] = '\0';
  } else {
    strncpy(statusDetail, detail, sizeof(statusDetail) - 1);
    statusDetail[sizeof(statusDetail) - 1] = '\0';
  }
  portEXIT_CRITICAL(&stateMux);
  requestRedraw();
}

void DeviceMapRenderer::requestRedraw() { redrawRequested = true; }

void DeviceMapRenderer::update() {
  if (!mapVisible || !redrawRequested || canvas == nullptr || canvasBuffer == nullptr) {
    return;
  }

  redrawRequested = false;
  draw();
}

void DeviceMapRenderer::draw() {
  GeoPoint center;
  bool hasCenter = false;
  DeviceMapSettings localSettings;
  char localStatusDetail[sizeof(statusDetail)] = "";

  portENTER_CRITICAL(&stateMux);
  localSettings = settings;
  strncpy(localStatusDetail, statusDetail, sizeof(localStatusDetail) - 1);
  localStatusDetail[sizeof(localStatusDetail) - 1] = '\0';
  if (hasGpsPoint) {
    center = gpsPoint;
    hasCenter = true;
  } else if (routePointCount > 0) {
    center = routePoints[0];
    hasCenter = true;
  }
  portEXIT_CRITICAL(&stateMux);

  lv_canvas_fill_bg(canvas, lv_color_hex(0xF4F1E8), LV_OPA_COVER);

  if (!hasCenter) {
    char message[160];
    if (localStatusDetail[0] != '\0') {
      snprintf(message, sizeof(message), "Waiting for route/GPS data\n%s",
               localStatusDetail);
    } else {
      snprintf(message, sizeof(message), "Waiting for route/GPS data");
    }
    drawStatusMessage(message);
    return;
  }

  int32_t centerX = lonToMercatorX(center.lonMicro);
  int32_t centerY = latToMercatorY(center.latMicro);
  double mpp = metersPerPixel();

  if (!sdAvailable) {
    drawStatusMessage("SD map not mounted\nroute/GPS overlay active");
  } else if (!drawMapBlocks(centerX, centerY, mpp)) {
    drawStatusMessage("No matching map blocks\nroute/GPS overlay active");
  }

  drawRouteOverlay(centerX, centerY, mpp);
  drawGpsMarker(centerX, centerY, mpp);
  lv_obj_invalidate(canvas);
}

void DeviceMapRenderer::drawStatusMessage(const char *message) {
  lv_draw_label_dsc_t label;
  lv_draw_label_dsc_init(&label);
  label.color = lv_color_hex(0x555555);
  label.align = LV_TEXT_ALIGN_CENTER;
  lv_area_t area = {20, static_cast<lv_coord_t>(canvasHeight / 2 - 28),
                    static_cast<lv_coord_t>(canvasWidth - 20),
                    static_cast<lv_coord_t>(canvasHeight / 2 + 40)};
  lv_canvas_draw_text(canvas, area.x1, area.y1, area.x2 - area.x1,
                      &label, message);
}

bool DeviceMapRenderer::drawMapBlocks(int32_t centerX, int32_t centerY,
                                      double mpp) {
  bool drewAnyBlock = false;
  int32_t halfSpanX = static_cast<int32_t>((canvasWidth * mpp) / 2.0) + MAPBLOCK_SIZE;
  int32_t halfSpanY = static_cast<int32_t>((canvasHeight * mpp) / 2.0) + MAPBLOCK_SIZE;
  int32_t minBlockX = (centerX - halfSpanX) & ~MAPBLOCK_MASK;
  int32_t maxBlockX = (centerX + halfSpanX) & ~MAPBLOCK_MASK;
  int32_t minBlockY = (centerY - halfSpanY) & ~MAPBLOCK_MASK;
  int32_t maxBlockY = (centerY + halfSpanY) & ~MAPBLOCK_MASK;

  for (int32_t blockY = minBlockY; blockY <= maxBlockY; blockY += MAPBLOCK_SIZE) {
    for (int32_t blockX = minBlockX; blockX <= maxBlockX; blockX += MAPBLOCK_SIZE) {
      char path[96];
      if (findBlockPath(blockX, blockY, path, sizeof(path))) {
        drawBinaryMapBlock(path, blockX, blockY, centerX, centerY, mpp);
        drewAnyBlock = true;
      }
    }
  }
  if (!drewAnyBlock) {
    Serial.printf("Map renderer: no .fmb blocks near mercator center x=%ld y=%ld\n",
                  (long)centerX, (long)centerY);
  }
  return drewAnyBlock;
}

void DeviceMapRenderer::drawBinaryMapBlock(const char *path, int32_t blockMinX,
                                           int32_t blockMinY, int32_t centerX,
                                           int32_t centerY, double mpp) {
  File file = SD.open(path, FILE_READ);
  if (!file) {
    return;
  }

  char magic[4];
  if (file.readBytes(magic, 4) != 4 || magic[0] != 'F' || magic[1] != 'M' ||
      magic[2] != 'B') {
    file.close();
    return;
  }

  uint16_t polygonCount = 0;
  if (!readUInt16(file, polygonCount)) {
    file.close();
    return;
  }

  for (uint16_t i = 0; i < polygonCount; i++) {
    uint16_t color = 0;
    uint8_t maxZoom = 0;
    uint8_t typeId = 0;
    int16_t bbox[4];
    uint16_t pointCount = 0;
    if (!readUInt16(file, color) || !readUInt8(file, maxZoom) ||
        !readUInt8(file, typeId)) {
      break;
    }
    for (int j = 0; j < 4; j++) {
      if (!readInt16(file, bbox[j])) {
        file.close();
        return;
      }
    }
    if (!readUInt16(file, pointCount)) {
      break;
    }

    if (!featureVisible(typeId) || pointCount < 3 || pointCount > 80) {
      skipBinaryFeature(file, pointCount);
      continue;
    }

    lv_point_t points[80];
    for (uint16_t p = 0; p < pointCount; p++) {
      int16_t x = 0;
      int16_t y = 0;
      if (!readInt16(file, x) || !readInt16(file, y)) {
        file.close();
        return;
      }
      points[p].x = screenX(blockMinX + x, centerX, mpp);
      points[p].y = screenY(blockMinY + y, centerY, mpp);
    }

    lv_draw_rect_dsc_t draw;
    lv_draw_rect_dsc_init(&draw);
    draw.bg_color = lv_color_make((color >> 11) << 3,
                                  ((color >> 5) & 0x3F) << 2,
                                  (color & 0x1F) << 3);
    draw.bg_opa = LV_OPA_COVER;
    lv_canvas_draw_polygon(canvas, points, pointCount, &draw);
  }

  uint16_t polylineCount = 0;
  if (!readUInt16(file, polylineCount)) {
    file.close();
    return;
  }

  for (uint16_t i = 0; i < polylineCount; i++) {
    uint16_t color = 0;
    uint8_t width = 1;
    uint8_t maxZoom = 0;
    uint8_t typeId = 0;
    int16_t bbox[4];
    uint16_t pointCount = 0;
    if (!readUInt16(file, color) || !readUInt8(file, width) ||
        !readUInt8(file, maxZoom) || !readUInt8(file, typeId)) {
      break;
    }
    for (int j = 0; j < 4; j++) {
      if (!readInt16(file, bbox[j])) {
        file.close();
        return;
      }
    }
    if (!readUInt16(file, pointCount)) {
      break;
    }

    if (!featureVisible(typeId) || pointCount < 2) {
      skipBinaryFeature(file, pointCount);
      continue;
    }

    int16_t prevX = 0;
    int16_t prevY = 0;
    for (uint16_t p = 0; p < pointCount; p++) {
      int16_t x = 0;
      int16_t y = 0;
      if (!readInt16(file, x) || !readInt16(file, y)) {
        file.close();
        return;
      }
      int16_t sx = screenX(blockMinX + x, centerX, mpp);
      int16_t sy = screenY(blockMinY + y, centerY, mpp);
      if (p > 0) {
        drawLine(canvas, prevX, prevY, sx, sy, lv_color_make((color >> 11) << 3,
                 ((color >> 5) & 0x3F) << 2, (color & 0x1F) << 3),
                 std::max<uint8_t>(1, width));
      }
      prevX = sx;
      prevY = sy;
    }
  }

  file.close();
}

void DeviceMapRenderer::skipBinaryFeature(File &file, uint16_t pointCount) {
  file.seek(file.position() + static_cast<uint32_t>(pointCount) * 4);
}

void DeviceMapRenderer::drawRouteOverlay(int32_t centerX, int32_t centerY,
                                         double mpp) {
  GeoPoint localRoute[MAX_ROUTE_POINTS];
  size_t localCount = 0;
  uint8_t width = 4;
  portENTER_CRITICAL(&stateMux);
  localCount = routePointCount;
  if (localCount > 0) {
    memcpy(localRoute, routePoints, localCount * sizeof(GeoPoint));
  }
  width = settings.routeLineWidth;
  portEXIT_CRITICAL(&stateMux);

  if (localCount < 2) {
    return;
  }

  for (size_t i = 0; i + 1 < localCount; i++) {
    drawLine(canvas, screenX(lonToMercatorX(localRoute[i].lonMicro), centerX, mpp),
             screenY(latToMercatorY(localRoute[i].latMicro), centerY, mpp),
             screenX(lonToMercatorX(localRoute[i + 1].lonMicro), centerX, mpp),
             screenY(latToMercatorY(localRoute[i + 1].latMicro), centerY, mpp),
             lv_color_hex(0x0A84FF), width);
  }
}

void DeviceMapRenderer::drawGpsMarker(int32_t centerX, int32_t centerY,
                                      double mpp) {
  GeoPoint localGps;
  bool hasGps = false;
  portENTER_CRITICAL(&stateMux);
  localGps = gpsPoint;
  hasGps = hasGpsPoint;
  portEXIT_CRITICAL(&stateMux);

  if (!hasGps) {
    return;
  }

  int16_t x = screenX(lonToMercatorX(localGps.lonMicro), centerX, mpp);
  int16_t y = screenY(latToMercatorY(localGps.latMicro), centerY, mpp);

  lv_draw_rect_dsc_t halo;
  lv_draw_rect_dsc_init(&halo);
  halo.radius = LV_RADIUS_CIRCLE;
  halo.bg_color = lv_color_hex(0xFFFFFF);
  halo.bg_opa = LV_OPA_COVER;
  lv_area_t haloArea = {static_cast<lv_coord_t>(x - 12), static_cast<lv_coord_t>(y - 12),
                        static_cast<lv_coord_t>(x + 12), static_cast<lv_coord_t>(y + 12)};
  lv_canvas_draw_rect(canvas, haloArea.x1, haloArea.y1, 24, 24, &halo);

  lv_draw_rect_dsc_t dot;
  lv_draw_rect_dsc_init(&dot);
  dot.radius = LV_RADIUS_CIRCLE;
  dot.bg_color = lv_color_hex(0x007AFF);
  dot.bg_opa = LV_OPA_COVER;
  lv_canvas_draw_rect(canvas, x - 8, y - 8, 16, 16, &dot);
}

bool DeviceMapRenderer::readInt16(File &file, int16_t &value) {
  return file.read(reinterpret_cast<uint8_t *>(&value), sizeof(value)) == sizeof(value);
}

bool DeviceMapRenderer::readUInt16(File &file, uint16_t &value) {
  return file.read(reinterpret_cast<uint8_t *>(&value), sizeof(value)) == sizeof(value);
}

bool DeviceMapRenderer::readUInt8(File &file, uint8_t &value) {
  return file.read(&value, sizeof(value)) == sizeof(value);
}

bool DeviceMapRenderer::featureVisible(uint8_t typeId) const {
  if (typeId >= 100 && typeId < 150) {
    return (settings.visibilityMask & (1 << 0)) != 0;
  }
  if (typeId >= 150 && typeId < 200) {
    return (settings.visibilityMask & (1 << 1)) != 0;
  }
  if (typeId >= 50 && typeId < 100) {
    return (settings.visibilityMask & (1 << 2)) != 0;
  }
  return true;
}

bool DeviceMapRenderer::findBlockPath(int32_t blockMinX, int32_t blockMinY,
                                      char *path, size_t pathSize) const {
  int32_t blockX = (blockMinX >> MAPBLOCK_SIZE_BITS) & MAPFOLDER_MASK;
  int32_t blockY = (blockMinY >> MAPBLOCK_SIZE_BITS) & MAPFOLDER_MASK;
  int32_t folderX = blockMinX >> (MAPFOLDER_SIZE_BITS + MAPBLOCK_SIZE_BITS);
  int32_t folderY = blockMinY >> (MAPFOLDER_SIZE_BITS + MAPBLOCK_SIZE_BITS);
  char folder[16];
  snprintf(folder, sizeof(folder), "%+04d%+04d", static_cast<int>(folderX),
           static_cast<int>(folderY));

  const char *roots[] = {"/VECTMAP", "/maps", ""};
  for (const char *root : roots) {
    snprintf(path, pathSize, "%s/%s/%ld_%ld.fmb", root, folder,
             static_cast<long>(blockX), static_cast<long>(blockY));
    if (SD.exists(path)) {
      return true;
    }
  }
  return false;
}

double DeviceMapRenderer::metersPerPixel() const {
  uint8_t zoom = settings.zoomLevel;
  if (zoom == 0) {
    return 0.5;
  }
  if (zoom == 1) {
    return 0.75;
  }
  if (zoom == 2) {
    return 1.0;
  }
  return static_cast<double>(zoom - 1);
}

int16_t DeviceMapRenderer::screenX(int32_t mercatorX, int32_t centerX,
                                   double mpp) const {
  return static_cast<int16_t>(round((mercatorX - centerX) / mpp + canvasWidth / 2.0));
}

int16_t DeviceMapRenderer::screenY(int32_t mercatorY, int32_t centerY,
                                   double mpp) const {
  return static_cast<int16_t>(round(-(mercatorY - centerY) / mpp + canvasHeight / 2.0));
}

int32_t DeviceMapRenderer::lonToMercatorX(int32_t lonMicro) {
  double lon = lonMicro / 1000000.0;
  return static_cast<int32_t>(round((lon * kPi / 180.0) * EARTH_RADIUS));
}

int32_t DeviceMapRenderer::latToMercatorY(int32_t latMicro) {
  double lat = std::max(-85.0, std::min(85.0, latMicro / 1000000.0));
  double rad = lat * kPi / 180.0;
  return static_cast<int32_t>(round(log(tan(rad / 2.0 + kPi / 4.0)) * EARTH_RADIUS));
}

uint16_t DeviceMapRenderer::clampRgb565(uint16_t color) { return color; }
