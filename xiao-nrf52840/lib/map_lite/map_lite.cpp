#include "map_lite.hpp"

#include "display_round.hpp"
#include "round_display_pins.hpp"

#include <SPI.h>

namespace xiao_round {
namespace {

constexpr uint8_t SD_SPI_MHZ = 12;
constexpr const char *MAP_PREFIXES[] = {"/VECTMAP", "/maps", ""};
constexpr uint32_t GPS_BLOCK_PROBE_MIN_INTERVAL_MS = 5000;
constexpr uint32_t MAP_LITE_RENDER_MIN_INTERVAL_MS = 5000;
constexpr uint8_t DEFAULT_SD_LIST_ENTRIES = 24;
constexpr uint8_t MAX_SD_LIST_ENTRIES = 64;

uint16_t readU16LE(const uint8_t *data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8);
}

bool readExact(SdFile &file, void *buffer, size_t len) {
  return buffer != nullptr && file.read(buffer, len) == static_cast<int>(len);
}

bool readU8(SdFile &file, uint8_t &value) { return readExact(file, &value, 1); }

bool readU16(SdFile &file, uint16_t &value) {
  uint8_t bytes[2] = {};
  if (!readExact(file, bytes, sizeof(bytes))) {
    return false;
  }
  value = readU16LE(bytes);
  return true;
}

bool readI16(SdFile &file, int16_t &value) {
  uint16_t raw = 0;
  if (!readU16(file, raw)) {
    return false;
  }
  value = static_cast<int16_t>(raw);
  return true;
}

bool skipBytes(SdFile &file, uint32_t byteCount) {
  if (byteCount == 0) {
    return true;
  }
  const int available = file.available();
  if (available < 0 || byteCount > static_cast<uint32_t>(available)) {
    return false;
  }
  return file.seekCur(static_cast<int32_t>(byteCount));
}

} // namespace

bool MapLite::begin() {
  pinMode(pins::lcdCs, OUTPUT);
  pinMode(pins::sdCs, OUTPUT);
  digitalWrite(pins::lcdCs, HIGH);
  digitalWrite(pins::sdCs, HIGH);

  SPI.setPins(pins::spiMiso, pins::spiSck, pins::spiMosi);
  SPI.begin();

  sdReady = sd.begin(pins::sdCs, SD_SCK_MHZ(SD_SPI_MHZ));
  currentStatus.sdReady = sdReady;
  Serial.print("MapLite: SD ");
  Serial.println(sdReady ? "ready" : "unavailable");
  return sdReady;
}

bool MapLite::updateForGps(int32_t latMicrodegrees, int32_t lonMicrodegrees,
                           uint32_t nowMs) {
  if (!sdReady) {
    return false;
  }

  int32_t mapMetersX = 0;
  int32_t mapMetersY = 0;
  if (!map_lite_core::gpsToMapMeters(latMicrodegrees, lonMicrodegrees,
                                     mapMetersX, mapMetersY)) {
    return false;
  }

  const int32_t blockX = map_lite_core::blockCoordForMapMeters(mapMetersX);
  const int32_t blockY = map_lite_core::blockCoordForMapMeters(mapMetersY);
  if (hasGpsProbeBlock && blockX == lastGpsBlockX && blockY == lastGpsBlockY) {
    return false;
  }
  if (lastGpsProbeMs != 0 &&
      nowMs - lastGpsProbeMs < GPS_BLOCK_PROBE_MIN_INTERVAL_MS) {
    return false;
  }

  lastGpsProbeMs = nowMs;
  lastGpsBlockX = blockX;
  lastGpsBlockY = blockY;
  hasGpsProbeBlock = true;

  Serial.print("MapLite: GPS block probe lat=");
  Serial.print(latMicrodegrees);
  Serial.print(" lon=");
  Serial.print(lonMicrodegrees);
  Serial.print(" map_m=");
  Serial.print(mapMetersX);
  Serial.print(",");
  Serial.print(mapMetersY);
  Serial.print(" block=");
  Serial.print(blockX);
  Serial.print(",");
  Serial.println(blockY);

  probeBlockInternal(mapMetersX, mapMetersY, true);
  return true;
}

MapBlockProbeResult MapLite::probeBlock(int32_t mapMetersX,
                                        int32_t mapMetersY) {
  return probeBlockInternal(mapMetersX, mapMetersY, false);
}

MapLiteStatus MapLite::status() const { return currentStatus; }

bool MapLite::printDirectory(const char *path, uint8_t maxEntries) {
  const char *target = (path == nullptr || *path == '\0') ? "/" : path;
  const uint8_t entryLimit =
      maxEntries == 0 ? DEFAULT_SD_LIST_ENTRIES
                      : maxEntries > MAX_SD_LIST_ENTRIES ? MAX_SD_LIST_ENTRIES
                                                         : maxEntries;
  if (!sdReady) {
    Serial.print("MapLite: SD list unavailable path=");
    Serial.println(target);
    return false;
  }

  SdFile dir;
  if (!dir.open(target, O_RDONLY) || !dir.isDir()) {
    Serial.print("MapLite: SD list failed path=");
    Serial.println(target);
    dir.close();
    return false;
  }

  uint8_t entryCount = 0;
  bool truncated = false;
  SdFile entry;
  while (entryCount < entryLimit && entry.openNext(&dir, O_RDONLY)) {
    char name[48] = "";
    const size_t nameLen = entry.getName(name, sizeof(name));
    Serial.print("MapLite: sd entry name=");
    Serial.print(nameLen > 0 ? name : "<unnamed>");
    Serial.print(" dir=");
    Serial.print(entry.isDir());
    Serial.print(" size=");
    Serial.println(static_cast<uint32_t>(entry.fileSize()));
    entry.close();
    entryCount++;
  }
  if (entryCount >= entryLimit && entry.openNext(&dir, O_RDONLY)) {
    truncated = true;
    entry.close();
  }
  const bool readError = dir.getError();
  dir.close();

  Serial.print("MapLite: SD list path=");
  Serial.print(target);
  Serial.print(" entries=");
  Serial.print(entryCount);
  Serial.print(" truncated=");
  Serial.print(truncated);
  Serial.print(" error=");
  Serial.println(readError);
  return !readError;
}

bool MapLite::renderLastProbePreview(DisplayRound &display, uint32_t nowMs) {
  return renderLastProbePreview(display, nowMs, MapRenderViewport{});
}

bool MapLite::renderLastProbePreview(DisplayRound &display, uint32_t nowMs,
                                     const MapRenderViewport &viewport) {
  if (!currentStatus.hasProbe || !currentStatus.lastResult.found ||
      currentStatus.lastResult.path[0] == '\0' ||
      currentStatus.lastResult.decision != MapLiteDecision::Candidate) {
    return false;
  }
  if (currentStatus.lastRenderedProbeCount == currentStatus.probeCount &&
      currentStatus.lastRenderAtMs != 0 &&
      nowMs - currentStatus.lastRenderAtMs < MAP_LITE_RENDER_MIN_INTERVAL_MS &&
      !viewport.centered) {
    return false;
  }

  const uint32_t renderStartMs = millis();
  uint16_t featureCount = 0;
  uint16_t segmentCount = 0;
  uint16_t skippedSegmentCount = 0;
  bool budgetExceeded = false;
  bool valid = false;

  SdFile file;
  if (sdReady && file.open(currentStatus.lastResult.path, O_RDONLY)) {
    MapBlockProbeResult header = {};
    header.fileSizeBytes = file.fileSize();
    header.headerValid = readHeader(file, header);
    if (header.headerValid && skipPolygonRecords(file, header)) {
      valid = renderPolylineRecords(file, display, header, featureCount,
                                    segmentCount, skippedSegmentCount,
                                    budgetExceeded,
                                    viewport.centered ? &viewport : nullptr);
    }
    file.close();
  }

  const uint32_t renderMs = millis() - renderStartMs;
  recordRenderStatus(renderStartMs, renderMs, featureCount, segmentCount,
                     skippedSegmentCount, valid, budgetExceeded);

  Serial.print("MapLite: render preview valid=");
  Serial.print(valid);
  Serial.print(" features=");
  Serial.print(featureCount);
  Serial.print(" segments=");
  Serial.print(segmentCount);
  Serial.print(" skipped=");
  Serial.print(skippedSegmentCount);
  Serial.print(" budget_exceeded=");
  Serial.print(budgetExceeded);
  Serial.print(" render_ms=");
  Serial.println(renderMs);
  return valid;
}

MapBlockProbeResult MapLite::probeBlockInternal(int32_t mapMetersX,
                                                int32_t mapMetersY,
                                                bool fromGps) {
  MapBlockProbeResult result;
  result.sdReady = sdReady;
  const int32_t blockX = map_lite_core::blockCoordForMapMeters(mapMetersX);
  const int32_t blockY = map_lite_core::blockCoordForMapMeters(mapMetersY);

  if (!sdReady) {
    map_lite_core::formatBlockPath(result.path, sizeof(result.path),
                                   MAP_PREFIXES[0], mapMetersX, mapMetersY);
    recordProbeStatus(result, mapMetersX, mapMetersY, blockX, blockY, fromGps);
    return result;
  }

  SdFile file;
  const uint32_t openStartMs = millis();
  for (const char *prefix : MAP_PREFIXES) {
    map_lite_core::formatBlockPath(result.path, sizeof(result.path), prefix,
                                   mapMetersX, mapMetersY);
    if (file.open(result.path, O_RDONLY)) {
      result.found = true;
      break;
    }
  }
  result.openMs = millis() - openStartMs;
  if (!result.found) {
    Serial.print("MapLite: missing block, last path=");
    Serial.println(result.path);
    recordProbeStatus(result, mapMetersX, mapMetersY, blockX, blockY, fromGps);
    return result;
  }

  result.fileSizeBytes = file.fileSize();
  result.headerValid = readHeader(file, result);
  if (result.headerValid) {
    result.scanValid = scanFeatures(file, result);
    map_lite_core::ProbeStats stats;
    stats.headerValid = result.headerValid;
    stats.scanValid = result.scanValid;
    stats.scanMs = result.scanMs;
    stats.candidatePolygonCount = result.candidatePolygonCount;
    stats.candidatePolylineCount = result.candidatePolylineCount;
    stats.candidatePointCount = result.candidatePointCount;
    result.decision = map_lite_core::decide(stats);
  } else {
    result.decision = MapLiteDecision::Invalid;
  }
  file.close();

  Serial.print("MapLite: probe path=");
  Serial.print(result.path);
  Serial.print(" size=");
  Serial.print(result.fileSizeBytes);
  Serial.print(" open_ms=");
  Serial.print(result.openMs);
  Serial.print(" header=");
  Serial.print(result.headerValid);
  Serial.print(" version=");
  Serial.print(result.version);
  Serial.print(" polygons=");
  Serial.print(result.polygonCount);
  Serial.print(" polylines=");
  Serial.print(result.polylineCount);
  Serial.print(" candidate_polygons=");
  Serial.print(result.candidatePolygonCount);
  Serial.print(" candidate_polylines=");
  Serial.print(result.candidatePolylineCount);
  Serial.print(" candidate_points=");
  Serial.print(result.candidatePointCount);
  Serial.print(" max_feature_points=");
  Serial.print(result.maxFeaturePoints);
  Serial.print(" scan_ms=");
  Serial.print(result.scanMs);
  Serial.print(" decision=");
  Serial.println(decisionName(result.decision));
  recordProbeStatus(result, mapMetersX, mapMetersY, blockX, blockY, fromGps);
  return result;
}

void MapLite::recordProbeStatus(const MapBlockProbeResult &result,
                                int32_t mapMetersX, int32_t mapMetersY,
                                int32_t blockX, int32_t blockY,
                                bool fromGps) {
  currentStatus.sdReady = sdReady;
  currentStatus.hasProbe = true;
  currentStatus.lastProbeFromGps = fromGps;
  currentStatus.probeCount++;
  currentStatus.lastProbeMs = millis();
  currentStatus.lastMapMetersX = mapMetersX;
  currentStatus.lastMapMetersY = mapMetersY;
  currentStatus.lastBlockX = blockX;
  currentStatus.lastBlockY = blockY;
  currentStatus.lastResult = result;
  currentStatus.lastRenderMs = 0;
  currentStatus.lastRenderedProbeCount = 0;
  currentStatus.lastRenderedFeatureCount = 0;
  currentStatus.lastRenderedSegmentCount = 0;
  currentStatus.lastSkippedSegmentCount = 0;
  currentStatus.lastRenderAttempted = false;
  currentStatus.lastRenderValid = false;
  currentStatus.lastRenderBudgetExceeded = false;
}

void MapLite::recordRenderStatus(uint32_t startedAtMs, uint32_t renderMs,
                                 uint16_t featureCount, uint16_t segmentCount,
                                 uint16_t skippedSegmentCount, bool valid,
                                 bool budgetExceeded) {
  currentStatus.renderCount++;
  currentStatus.lastRenderAtMs = startedAtMs;
  currentStatus.lastRenderMs = renderMs;
  currentStatus.lastRenderedProbeCount = currentStatus.probeCount;
  currentStatus.lastRenderedFeatureCount = featureCount;
  currentStatus.lastRenderedSegmentCount = segmentCount;
  currentStatus.lastSkippedSegmentCount = skippedSegmentCount;
  currentStatus.lastRenderAttempted = true;
  currentStatus.lastRenderValid = valid;
  currentStatus.lastRenderBudgetExceeded = budgetExceeded;
}

bool MapLite::skipPolygonRecords(SdFile &file,
                                 const MapBlockProbeResult &result) {
  const bool hasTypeId = result.version >= 2;
  for (uint16_t i = 0; i < result.polygonCount; i++) {
    uint16_t color = 0;
    uint8_t maxZoom = 0;
    uint8_t typeId = 0;
    uint16_t pointCount = 0;
    if (!readU16(file, color) || !readU8(file, maxZoom) ||
        (hasTypeId && !readU8(file, typeId)) || !skipBytes(file, 8) ||
        !readU16(file, pointCount)) {
      return false;
    }
    (void)color;
    (void)maxZoom;
    (void)typeId;
    if (!skipBytes(file, static_cast<uint32_t>(pointCount) * 4UL)) {
      return false;
    }
  }
  return true;
}

bool centeredPointToScreen(const MapRenderViewport &viewport,
                           int32_t blockOriginX, int32_t blockOriginY,
                           int16_t localX, int16_t localY, int16_t &screenX,
                           int16_t &screenY, double &rotatedX,
                           double &rotatedY) {
  double dx = static_cast<double>(blockOriginX + localX -
                                  viewport.centerMapMetersX);
  double dy = static_cast<double>(blockOriginY + localY -
                                  viewport.centerMapMetersY);
  if (viewport.courseUp) {
    const double radians =
        static_cast<double>(viewport.headingDegrees) * 0.017453292519943295;
    const double sinHeading = sin(radians);
    const double cosHeading = cos(radians);
    const double courseX = (dx * cosHeading) - (dy * sinHeading);
    const double courseY = (dx * sinHeading) + (dy * cosHeading);
    dx = courseX;
    dy = courseY;
  }

  rotatedX = dx;
  rotatedY = dy;
  const double center = (DisplayRound::width - 1) / 2.0;
  const double scale = center / viewport.radiusMeters;
  auto clampScreen = [](int32_t value) -> int16_t {
    if (value < 0) {
      return 0;
    }
    if (value >= DisplayRound::width) {
      return DisplayRound::width - 1;
    }
    return static_cast<int16_t>(value);
  };
  screenX = clampScreen(static_cast<int32_t>(center + (dx * scale) + 0.5));
  screenY = clampScreen(static_cast<int32_t>(center - (dy * scale) + 0.5));
  return fabs(dx) <= viewport.radiusMeters || fabs(dy) <= viewport.radiusMeters;
}

bool MapLite::renderPolylineRecords(SdFile &file, DisplayRound &display,
                                    const MapBlockProbeResult &result,
                                    uint16_t &featureCount,
                                    uint16_t &segmentCount,
                                    uint16_t &skippedSegmentCount,
                                    bool &budgetExceeded,
                                    const MapRenderViewport *viewport) {
  uint16_t polylineCount = 0;
  if (!readU16(file, polylineCount)) {
    return false;
  }

  const bool hasTypeId = result.version >= 2;
  for (uint16_t i = 0; i < polylineCount; i++) {
    uint16_t color = 0;
    uint8_t width = 0;
    uint8_t maxZoom = 0;
    uint8_t typeId = 0;
    uint16_t pointCount = 0;
    if (!readU16(file, color) || !readU8(file, width) ||
        !readU8(file, maxZoom) || (hasTypeId && !readU8(file, typeId)) ||
        !skipBytes(file, 8) || !readU16(file, pointCount)) {
      return false;
    }
    (void)width;
    (void)maxZoom;

    const bool renderCandidate =
        map_lite_core::isCandidatePolyline(result.version, typeId);
    if (!renderCandidate || pointCount < 2) {
      if (!skipBytes(file, static_cast<uint32_t>(pointCount) * 4UL)) {
        return false;
      }
      continue;
    }

    int16_t previousX = 0;
    int16_t previousY = 0;
    if (!readI16(file, previousX) || !readI16(file, previousY)) {
      return false;
    }
    bool featureDrewSegment = false;
    const int32_t blockOriginX =
        map_lite_core::blockCoordForMapMeters(currentStatus.lastMapMetersX) *
        map_lite_core::MAPBLOCK_SIZE_METERS;
    const int32_t blockOriginY =
        map_lite_core::blockCoordForMapMeters(currentStatus.lastMapMetersY) *
        map_lite_core::MAPBLOCK_SIZE_METERS;
    for (uint16_t pointIndex = 1; pointIndex < pointCount; pointIndex++) {
      int16_t currentX = 0;
      int16_t currentY = 0;
      if (!readI16(file, currentX) || !readI16(file, currentY)) {
        return false;
      }
      if (featureCount < map_lite_core::RENDER_FEATURE_BUDGET &&
          segmentCount < map_lite_core::RENDER_SEGMENT_BUDGET) {
        int16_t previousScreenX = 0;
        int16_t previousScreenY = 0;
        int16_t currentScreenX = 0;
        int16_t currentScreenY = 0;
        bool shouldDraw = true;
        if (viewport != nullptr) {
          double previousRotatedX = 0.0;
          double previousRotatedY = 0.0;
          double currentRotatedX = 0.0;
          double currentRotatedY = 0.0;
          centeredPointToScreen(*viewport, blockOriginX, blockOriginY,
                                previousX, previousY, previousScreenX,
                                previousScreenY, previousRotatedX,
                                previousRotatedY);
          centeredPointToScreen(*viewport, blockOriginX, blockOriginY,
                                currentX, currentY, currentScreenX,
                                currentScreenY, currentRotatedX,
                                currentRotatedY);
          shouldDraw =
              !((fabs(previousRotatedX) > viewport->radiusMeters &&
                 fabs(currentRotatedX) > viewport->radiusMeters &&
                 ((previousRotatedX < 0.0) == (currentRotatedX < 0.0))) ||
                (fabs(previousRotatedY) > viewport->radiusMeters &&
                 fabs(currentRotatedY) > viewport->radiusMeters &&
                 ((previousRotatedY < 0.0) == (currentRotatedY < 0.0))));
        } else {
          previousScreenX = map_lite_core::localMapCoordToScreen(previousX, false);
          previousScreenY = map_lite_core::localMapCoordToScreen(previousY, true);
          currentScreenX = map_lite_core::localMapCoordToScreen(currentX, false);
          currentScreenY = map_lite_core::localMapCoordToScreen(currentY, true);
        }
        if (shouldDraw) {
          display.drawLine(previousScreenX, previousScreenY, currentScreenX,
                           currentScreenY, color);
          segmentCount++;
          featureDrewSegment = true;
        }
      } else {
        skippedSegmentCount++;
        budgetExceeded = true;
      }
      previousX = currentX;
      previousY = currentY;
    }
    if (featureDrewSegment) {
      featureCount++;
    }
  }

  return true;
}

bool MapLite::readHeader(SdFile &file, MapBlockProbeResult &result) {
  if (result.fileSizeBytes < map_lite_core::FMB_HEADER_SIZE) {
    return false;
  }

  uint8_t header[map_lite_core::FMB_HEADER_SIZE] = {};
  file.rewind();
  if (file.read(header, sizeof(header)) != sizeof(header)) {
    return false;
  }
  if (header[0] != 'F' || header[1] != 'M' || header[2] != 'B') {
    return false;
  }

  result.version = header[3];
  result.polygonCount = readU16LE(header + 4);
  return result.version == 1 || result.version == 2;
}

bool MapLite::scanFeatures(SdFile &file, MapBlockProbeResult &result) {
  if (result.fileSizeBytes < map_lite_core::FMB_HEADER_SIZE) {
    return false;
  }
  if (!file.seekSet(map_lite_core::FMB_HEADER_SIZE)) {
    return false;
  }

  const uint32_t scanStartMs = millis();
  const bool hasTypeId = result.version >= 2;
  for (uint16_t i = 0; i < result.polygonCount; i++) {
    uint16_t color = 0;
    uint8_t maxZoom = 0;
    uint8_t typeId = 0;
    uint16_t pointCount = 0;
    if (!readU16(file, color) || !readU8(file, maxZoom) ||
        (hasTypeId && !readU8(file, typeId)) || !skipBytes(file, 8) ||
        !readU16(file, pointCount)) {
      return false;
    }
    (void)color;
    (void)maxZoom;
    result.polygonPointCount += pointCount;
    if (pointCount > result.maxFeaturePoints) {
      result.maxFeaturePoints = pointCount;
    }
    if (map_lite_core::isCandidatePolygon(result.version, typeId)) {
      result.candidatePolygonCount++;
      result.candidatePointCount += pointCount;
    }
    if (!skipBytes(file, static_cast<uint32_t>(pointCount) * 4UL)) {
      return false;
    }
  }

  if (!readU16(file, result.polylineCount)) {
    return false;
  }

  for (uint16_t i = 0; i < result.polylineCount; i++) {
    uint16_t color = 0;
    uint8_t width = 0;
    uint8_t maxZoom = 0;
    uint8_t typeId = 0;
    uint16_t pointCount = 0;
    if (!readU16(file, color) || !readU8(file, width) ||
        !readU8(file, maxZoom) || (hasTypeId && !readU8(file, typeId)) ||
        !skipBytes(file, 8) || !readU16(file, pointCount)) {
      return false;
    }
    (void)color;
    (void)width;
    (void)maxZoom;
    result.polylinePointCount += pointCount;
    if (pointCount > result.maxFeaturePoints) {
      result.maxFeaturePoints = pointCount;
    }
    if (map_lite_core::isCandidatePolyline(result.version, typeId)) {
      result.candidatePolylineCount++;
      result.candidatePointCount += pointCount;
    }
    if (!skipBytes(file, static_cast<uint32_t>(pointCount) * 4UL)) {
      return false;
    }
  }

  result.scanMs = millis() - scanStartMs;
  return file.curPosition() <= result.fileSizeBytes;
}

const char *MapLite::decisionName(MapLiteDecision decision) {
  return map_lite_core::decisionName(decision);
}

} // namespace xiao_round
