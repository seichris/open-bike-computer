#pragma once

#include <Arduino.h>
#include <SdFat.h>

#include "map_lite_core.hpp"

namespace xiao_round {

class DisplayRound;

using MapLiteDecision = map_lite_core::Decision;

struct MapBlockProbeResult {
  bool sdReady = false;
  bool found = false;
  bool headerValid = false;
  bool scanValid = false;
  char path[72] = "";
  uint32_t fileSizeBytes = 0;
  uint32_t openMs = 0;
  uint32_t scanMs = 0;
  uint8_t version = 0;
  uint16_t polygonCount = 0;
  uint16_t polylineCount = 0;
  uint32_t polygonPointCount = 0;
  uint32_t polylinePointCount = 0;
  uint16_t candidatePolygonCount = 0;
  uint16_t candidatePolylineCount = 0;
  uint32_t candidatePointCount = 0;
  uint16_t maxFeaturePoints = 0;
  MapLiteDecision decision = MapLiteDecision::Unknown;
};

struct MapLiteStatus {
  bool sdReady = false;
  bool hasProbe = false;
  bool lastProbeFromGps = false;
  uint32_t probeCount = 0;
  uint32_t lastProbeMs = 0;
  int32_t lastMapMetersX = 0;
  int32_t lastMapMetersY = 0;
  int32_t lastBlockX = 0;
  int32_t lastBlockY = 0;
  uint32_t renderCount = 0;
  uint32_t lastRenderAtMs = 0;
  uint32_t lastRenderMs = 0;
  uint32_t lastRenderedProbeCount = 0;
  uint16_t lastRenderedFeatureCount = 0;
  uint16_t lastRenderedSegmentCount = 0;
  uint16_t lastSkippedSegmentCount = 0;
  bool lastRenderAttempted = false;
  bool lastRenderValid = false;
  bool lastRenderBudgetExceeded = false;
  MapBlockProbeResult lastResult;
};

struct MapRenderViewport {
  bool centered = false;
  int32_t centerMapMetersX = 0;
  int32_t centerMapMetersY = 0;
  uint16_t headingDegrees = 0;
  bool courseUp = false;
  double radiusMeters = 500.0;
};

class MapLite {
public:
  bool begin();
  MapBlockProbeResult probeBlock(int32_t mapMetersX, int32_t mapMetersY);
  bool updateForGps(int32_t latMicrodegrees, int32_t lonMicrodegrees,
                    uint32_t nowMs);
  bool renderLastProbePreview(DisplayRound &display, uint32_t nowMs);
  bool renderLastProbePreview(DisplayRound &display, uint32_t nowMs,
                              const MapRenderViewport &viewport);
  bool printDirectory(const char *path = "/", uint8_t maxEntries = 24);
  bool isReady() const { return sdReady; }
  MapLiteStatus status() const;
  static const char *decisionName(MapLiteDecision decision);

private:
  MapBlockProbeResult probeBlockInternal(int32_t mapMetersX,
                                         int32_t mapMetersY, bool fromGps);
  void recordProbeStatus(const MapBlockProbeResult &result,
                         int32_t mapMetersX, int32_t mapMetersY,
                         int32_t blockX, int32_t blockY, bool fromGps);
  void recordRenderStatus(uint32_t startedAtMs, uint32_t renderMs,
                          uint16_t featureCount, uint16_t segmentCount,
                          uint16_t skippedSegmentCount, bool valid,
                          bool budgetExceeded);
  bool skipPolygonRecords(SdFile &file, const MapBlockProbeResult &result);
  bool renderPolylineRecords(SdFile &file, DisplayRound &display,
                             const MapBlockProbeResult &result,
                             uint16_t &featureCount, uint16_t &segmentCount,
                             uint16_t &skippedSegmentCount,
                             bool &budgetExceeded,
                             const MapRenderViewport *viewport);
  bool readHeader(SdFile &file, MapBlockProbeResult &result);
  bool scanFeatures(SdFile &file, MapBlockProbeResult &result);

  SdFat sd;
  MapLiteStatus currentStatus;
  uint32_t lastGpsProbeMs = 0;
  int32_t lastGpsBlockX = 0;
  int32_t lastGpsBlockY = 0;
  bool sdReady = false;
  bool hasGpsProbeBlock = false;
};

} // namespace xiao_round
