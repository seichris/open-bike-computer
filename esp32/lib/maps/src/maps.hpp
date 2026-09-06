#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <map>
#include <math.h>
#include <string>
#include <vector>

// #include "../../compass/compass.hpp" // Circular dependency if not careful,
// but likely needed for getHeading
#include "../../ble_navigation/ble_navigation.hpp"
#include "../../settings/settings.hpp"
#include "../../storage/storage.hpp"
#include "../../renderer_diagnostics/renderer_diagnostics_policy.hpp"
#include "../../renderer_tuning/renderer_tuning.hpp"
// #include "../../tft/tft.hpp" // Removed or minimal include if possible?
#include "../../utils/src/gpsMath.hpp"
#include "mapTransform.hpp"
#include "map_projection.hpp"
#include "mapPresentation.hpp"
#include "mapCamera.hpp"
#include "mapPoseInputPolicy.hpp"
#include "mapProbeDiagnostics.hpp"
#include "mapRenderJob.hpp"
#include "mapSurface.hpp"
#include "../../utils/src/mapDragPreview.hpp"
#include "../../utils/src/mapRasterWindow.hpp"
#include "lvgl.h"
#include "mapFontAsset.hpp"
#include "mapBuildingRenderer.hpp"
#include "mapLabelBlock.hpp"
#include "mapBuildingBlock.hpp"
#include "mapLabelLayout.hpp"
#include "mapVars.h"
#include <Arduino.h>

// Forward declarations
struct MapSettings;

class Maps {
public:
  struct MapAvailabilityTransition {
    bool available = false;
    uint32_t renderDurationMs = 0;
    uint32_t blockLoadMs = 0;
  };

private:
  // Render Map
  struct MapTile // Tile Map structure
  {
    char file[255];
    uint32_t tilex;
    uint32_t tiley;
    uint8_t zoom;
    double lat;
    double lon;
  };
  uint16_t lon2posx(float f_lon, uint8_t zoom, uint16_t tileSize);
  uint16_t lat2posy(float f_lat, uint8_t zoom, uint16_t tileSize);
  uint32_t lon2tilex(double f_lon, uint8_t zoom);
  uint32_t lat2tiley(double f_lat, uint8_t zoom);
  double tilex2lon(uint32_t tileX, uint8_t zoom);
  double tiley2lat(uint32_t tileY, uint8_t zoom);

  // Vector Map
  static const int32_t MAPBLOCK_MASK =
      (1 << MAPBLOCK_SIZE_BITS) - 1; // ...00000000111111111111
  static const int32_t MAPFOLDER_MASK =
      (1 << MAPFOLDER_SIZE_BITS) - 1; // ...00001111
  struct Coord // Point in geographic (lat,lon) coordinates
  {
    Point32 getPoint32();
    double lat = 0;
    double lng = 0;
  };
  struct Polyline // Polyline struct
  {
    std::vector<Point16, PsramAllocator<Point16>> points;
    BBox bbox;
    uint16_t color;
    uint8_t width;
    uint8_t maxZoom;
    uint8_t typeId; // Feature type: 0=unknown, 1-49=roads, 50-99=paths,
                    // 100+=buildings/nature
  };
  struct Polygon // Polygon struct
  {
    std::vector<Point16, PsramAllocator<Point16>> points;
    BBox bbox;
    uint16_t color;
    uint8_t maxZoom;
    uint8_t typeId; // Feature type: 0=unknown, 100+=buildings, 150+=nature
  };
  // Spatial grid constants for polygon culling optimization
  static const int GRID_BITS = 4;              // 16x16 grid
  static const int GRID_SIZE = 1 << GRID_BITS; // 16 cells per axis
  static const int CELL_SHIFT =
      MAPBLOCK_SIZE_BITS - GRID_BITS; // Shift to get cell index

  struct MapBlock // Map square area of aprox 4096 meters side. Correspond to
                  // one single map file.
  {
    Point32 offset;
    double mercatorScale = 1.0;
    bool inView = false;
    uint8_t formatVersion = 1;
    std::vector<Polyline, PsramAllocator<Polyline>> polylines;
    std::vector<Polygon, PsramAllocator<Polygon>> polygons;
    map_label_block::Block labelData;
    map_building_block::Block buildingData;

    // Spatial grid for polygon culling: grid[cellIndex] = list of polygon
    // indices
    using PolygonGridCell = std::vector<uint16_t, PsramAllocator<uint16_t>>;
    std::vector<PolygonGridCell, PsramAllocator<PolygonGridCell>> polygonGrid;
  };
  struct ViewPort // Vector map viewport structure
  {
    void setCenter(Point32 pcenter);
    void setCenterForCanvas(Point32 pcenter, uint16_t canvasWidth,
                            uint16_t canvasHeight, double rotation);
    void setCenterForCanvas(double centerX, double centerY,
                            uint16_t canvasWidth, uint16_t canvasHeight,
                            double rotation);
    Point32 center;
    double rasterOriginX = 0.0;
    double rasterOriginY = 0.0;
    int32_t rasterCellOffsetX = 0;
    int32_t rasterCellOffsetY = 0;
    BBox bbox;
    uint8_t zoom;
  };
  ViewPort viewPort; // Vector map viewport
  struct MemBlocks   // MemBlocks stored in memory
  {
    std::map<String, u_int16_t> blocks_map; // block offset -> block index
    std::array<MapBlock *, MAPBLOCKS_MAX> blocks;
  };
  MemBlocks memBlocks; // Vector file map memory blocks
  struct MemCache      // MapBlocks memory store
  {
    std::vector<MapBlock *> blocks;
  };

  struct RenderContext {
    ScreenMapRenderSettings style{};
    renderer_tuning::Definition tuning = renderer_tuning::kCurrent;
    uint32_t rendererDiagnosticsWindowId = 0;
    map_transform::WorldPoint measuredGpsWorld{};
    map_transform::WorldPoint presentedWorld{};
    // Screen mode and route/session availability are distinct. The guidance
    // screen may be bird's-eye before a route starts and must still render its
    // configured 3D buildings.
    bool guidanceScreenActive = false;
    bool navigationSessionActive = false;
    bool followPosition = true;
    bool showCurrentPosition = true;
    bool buildings3DEnabled = false;
    uint8_t markerScale = 1;
    uint8_t birdsEyePerspective = 0;
    uint16_t labelViewportWidth = 0;
    uint16_t labelViewportHeight = 0;
    uint16_t labelGutter = 0;
    uint8_t effectiveRotationMode = 0;
  };

  static constexpr uint16_t MAP_RENDER_OVERSCAN_PIXELS = 96;
  static constexpr uint16_t MAP_RENDER_SAFETY_PIXELS = 16;
#if defined(WAVESHARE_AMOLED_175)
  static constexpr bool MAP_RENDER_ROUND_VIEWPORT = true;
  static constexpr uint16_t MAP_RENDER_MINIMUM_OVERSCAN_PIXELS = 64;
#else
  static constexpr bool MAP_RENDER_ROUND_VIEWPORT = false;
  static constexpr uint16_t MAP_RENDER_MINIMUM_OVERSCAN_PIXELS =
      MAP_RENDER_OVERSCAN_PIXELS;
#endif
  static constexpr uint32_t MAP_RENDER_WORKER_STACK_BYTES = 24576;
  static constexpr uint32_t MAP_RENDER_DECLARED_SLICE_US = 50000;

  struct RasterDiagnostics {
    uint32_t candidateBuildings = 0;
    uint32_t selectedBuildings = 0;
    uint32_t extrudedBuildings = 0;
    uint32_t flatBuildings = 0;
    uint32_t deferredBuildings = 0;
    uint32_t oversizedBuildings = 0;
    uint32_t renderedBuildings = 0;
    uint32_t extrudedP90DistancePx = 0;
    uint32_t extrudedFarthestDistancePx = 0;
    uint32_t buildingProjectionMs = 0;
    uint32_t buildingDrawMs = 0;
    uint8_t buildingLimiterFlags = 0;
    bool allocationFallback = false;
  };

  struct RenderRequest {
    map_render_job::Version version{};
    uint32_t requestedAtMs = 0;
    map_transform::WorldPoint center{};
    RenderContext context{};
    uint64_t styleSignature = 0;
    uint64_t navigationSignature = 0;
    uint64_t projectionSignature = 0;
    uint8_t zoom = map_transform::kMinimumRuntimeZoom;
    uint16_t viewportWidth = 0;
    uint16_t viewportHeight = 0;
    uint16_t renderWidth = 0;
    uint16_t renderHeight = 0;
    uint16_t overscanPixels = 0;
    size_t renderStridePixels = 0;
    double rotationRad = 0.0;
    uint32_t cancellationGeneration = 0;
    bool birdsEye = false;
  };

  struct RenderResult {
    map_render_job::Version version{};
    uint32_t requestedAtMs = 0;
    uint32_t sceneGeneration = 0;
    bool sceneReused = false;
    uint8_t effectiveRotationMode = 0;
    uint8_t labelDensity = 0;
    uint8_t labelOrientation = 0;
    map_projection::Projection projection{};
    ViewPort viewport{};
    map_transform::WorldPoint center{};
    uint64_t styleSignature = 0;
    uint64_t navigationSignature = 0;
    uint64_t projectionSignature = 0;
    uint16_t viewportWidth = 0;
    uint16_t viewportHeight = 0;
    uint16_t renderWidth = 0;
    uint16_t renderHeight = 0;
    uint16_t overscanPixels = 0;
    size_t renderStridePixels = 0;
    uint32_t durationMs = 0;
    uint32_t blocksMs = 0;
    uint32_t drawMs = 0;
    uint32_t psramFree = 0;
    uint32_t psramLargest = 0;
    double rotationRad = 0.0;
    bool mapFound = false;
    bool followPosition = true;
    RasterDiagnostics raster{};
  };

  MemCache memCache;               // Worker-owned memory cache
  map_camera::PreparedScene preparedScene;
  std::atomic<size_t> cachedBlockCount{0};
  String vectorMapFolder = "/sdcard/VECTMAP/";
  map_font_asset::Asset labelFontAsset;
  std::atomic<bool> streetLabelFontHealthy{false};
  std::atomic<map_font_asset::RuntimeError> streetLabelRuntimeFailure{
      map_font_asset::RuntimeError::None};
  map_building_renderer::FailureRetryCooldown buildingFailureRetryCooldown;
  struct LabelLayoutCacheKey {
    int32_t centerX = 0;
    int32_t centerY = 0;
    int16_t rotationBucket = 0;
    uint16_t screenWidth = 0;
    uint16_t screenHeight = 0;
    uint32_t fontFingerprint = 0;
    uint32_t visibilityMask = 0;
    uint64_t blockSignature = 0;
    uint8_t zoom = 0;
    uint8_t density = 0;
    uint8_t languageMode = 0;
    uint8_t textSize = 0;
    uint8_t orientation = 0;
    int16_t markerX = 0;
    int16_t markerY = 0;
    uint8_t markerScale = 0;
    bool markerVisible = false;
    bool guidance = false;
    uint64_t cameraSignature = 0;

    bool operator==(const LabelLayoutCacheKey &other) const;
  };
  struct LabelLayoutCache {
    bool valid = false;
    LabelLayoutCacheKey key;
    MapLabelLayoutVector<map_label_layout::Placement> placements;
    map_label_layout::Diagnostics diagnostics;

    void clear() {
      valid = false;
      placements.clear();
      diagnostics = {};
    }
  } labelLayoutCache;
  Point32 point = viewPort.center; // Vector map GPS position point
  double lat2y(double lat);
  double lon2x(double lon);
  double mercatorX2lon(double x);
  double mercatorY2lat(double y);
  int16_t toScreenCoord(const int32_t pxy, const int32_t screenCenterxy);
  uint32_t idx;
  int16_t parseInt16(char *file);
  void parseStrUntil(char *file, char terminator, char *str);
  bool parseCoords(char *file,
                   std::vector<Point16, PsramAllocator<Point16>> &points);
  BBox parseBbox(String str);
  MapBlock *readMapBlock(String fileName);
  MapBlock *readMapBlockBinary(char *buffer, size_t fileSize);
  bool buildPolygonGrid(
      MapBlock *mblock); // Build spatial grid for polygon culling
  bool fillPolygon(const Polygon &p,
                   map_surface::Rgb565Surface surface);
  bool fillPolygon(
      const Polygon &p, map_surface::Rgb565Surface surface,
      std::vector<int16_t, PsramAllocator<int16_t>> &scanlineNodes);
  bool fillPolygon(const Polygon &p, lv_obj_t *canvas);
  void drawLine(map_surface::Rgb565Surface surface, int16_t x1, int16_t y1,
                int16_t x2, int16_t y2, uint16_t color, uint8_t width);
  void drawLine(lv_obj_t *canvas, int16_t x1, int16_t y1, int16_t x2,
                int16_t y2, uint16_t color, uint8_t width);
  bool getMapBlocks(BBox &bbox, MemCache &memCache);
  bool readVectorMap(ViewPort &viewPort, MemCache &memCache,
                     map_surface::Rgb565Surface surface, uint8_t zoom,
                     double rotation,
                     const map_projection::Projection &projection,
                     const RenderContext &context, bool drawLabels = true,
                     bool suppressBuildings = false,
                     RasterDiagnostics *diagnostics = nullptr);
  bool readVectorMap(ViewPort &viewPort, MemCache &memCache, lv_obj_t *canvas,
                     uint8_t zoom, double rotation,
                     const map_projection::Projection &projection,
                     bool drawLabels = true, bool suppressBuildings = false);
  bool renderRollingRasterCell(double rasterOriginX, double rasterOriginY,
                               int32_t cellOffsetX, int32_t cellOffsetY,
                               uint8_t zoom, double rotation,
                               uint8_t scratchIndex,
                               size_t scratchBaseOffset,
                               bool preserveVisibleState,
                               bool *mapFoundOut = nullptr);
  bool buildRollingRasterWindow(uint8_t zoom, uint16_t viewportWidth,
                                uint16_t viewportHeight, uint64_t signature);
  bool shiftRollingRasterWindow(int8_t directionX, int8_t directionY);
  bool settleRollingRasterWindow();
  map_transform::PixelOffset rollingRasterCenterOffset(Point32 center) const;
  bool preserveVisibleFrameForRollingBuild(uint16_t viewportWidth,
                                           uint16_t viewportHeight,
                                           size_t &scratchBaseOffset);
  void restoreVisibleFrameAfterRollingBuildFailure(uint16_t viewportWidth,
                                                   uint16_t viewportHeight);
  void copyScratchCellToGrid(uint8_t scratchIndex, uint8_t column,
                             uint8_t row, size_t scratchBaseOffset = 0);
  bool shiftGridPixelsHorizontal(int8_t direction);
  bool shiftGridPixelsVertical(int8_t direction);
  void bindRollingRasterCanvas();
  void positionRollingRasterCanvas(Point32 center);
  void updateVisibleVectorViewport();
  void invalidateRollingRasterWindow();
  bool renderRollingForeground();
  void hideRollingForeground();
  void restoreRollingForeground();
  bool rollingRasterCompatible(uint8_t zoom, uint16_t viewportWidth,
                               uint16_t viewportHeight,
                               uint64_t signature) const;
  bool shouldUseRollingRasterWindow(uint8_t zoom) const;
  uint64_t rollingRasterSignature() const;
  double visibleMapRotation() const;
  bool drawStreetLabels(ViewPort &viewPort, MemCache &memCache,
                        map_surface::LabelSurface surface, uint8_t zoom,
                        double rotation, const RenderContext &context,
                        const map_projection::Projection *projection = nullptr);
  bool drawStreetLabels(ViewPort &viewPort, MemCache &memCache,
                        lv_obj_t *canvas, uint8_t zoom, double rotation,
                        const ScreenMapRenderSettings &style);
  RenderContext captureRenderContext(uint32_t nowMs = 0);
  RenderContext captureRenderContextForScreen(uint32_t nowMs,
                                              bool mapVisible,
                                              bool guidanceScreenActive);
  static void renderWorkerTaskThunk(void *argument);
  void renderWorkerLoop();
  struct VectorMapActivationRequest {
    uint32_t sequence = 0;
    std::string folder;
  };
  struct VectorMapActivationCompletion {
    uint32_t sequence = 0;
    std::string folder;
    bool loaded = false;
    map_probe_diagnostics::Result probe;
  };
  bool takeVectorMapActivationRequest(VectorMapActivationRequest &request);
  bool processPendingVectorMapActivation();
  map_probe_diagnostics::Result
  probeVectorMapFolderOnStorageOwner(const std::string &folder);
  bool switchVectorMapFolderOnStorageOwner(const std::string &folder);
  void finalizeVectorMapFolderSwitchOnUi();
  bool startRenderWorker();
  bool stopRenderWorker();
  bool recoverRenderWorkerIfNeeded();
  bool buildRenderRequest(uint8_t zoom, uint32_t nowMs,
                          RenderRequest &request);
  bool buildRenderRequestForScreen(uint8_t zoom, uint32_t nowMs,
                                   bool mapVisible,
                                   bool guidanceScreenActive,
                                   RenderRequest &request);
  bool submitRenderRequest(const RenderRequest &request);
  void cancelActiveRenderWork();
  bool takeWorkerRequest(RenderRequest &request);
  bool publishReadyFrame(uint32_t nowMs);
  bool renderRequestStillCurrent(const RenderRequest &request) const;
  bool renderResultStillCurrent(const RenderResult &result) const;
  void updatePresentedPose(uint32_t nowMs);
  void updatePresentedPoseForScreen(uint32_t nowMs, bool mapVisible);
  void updatePresentedFrameTransform();
  void renderLiveForeground();
  void serviceStableCamera(uint32_t nowMs);
  bool prepareMapScene(const RenderRequest &request, RenderResult &result);
  void invalidateRenderSemantics(uint32_t nowMs);
  void invalidateRenderSemanticsForScreen(uint32_t nowMs, uint8_t zoom,
                                          bool mapVisible,
                                          bool guidanceScreenActive);
  bool presentationGestureOwnsTransforms() const;
  uint64_t styleSignature(const ScreenMapRenderSettings &style) const;
  uint64_t navigationSignatureForScreen(bool guidanceScreenActive) const;
  uint64_t projectionSignature(uint8_t zoom, uint16_t viewportWidth,
                               uint16_t viewportHeight, bool birdsEye,
                               uint8_t perspective) const;
  map_projection::Projection makeRequestProjection(
      const RenderRequest &request) const;
  void getPosition(double lat, double lon);

  mutable SemaphoreHandle_t renderStateMutex = nullptr;
  TaskHandle_t renderWorkerTaskHandle = nullptr;
  map_render_job::LatestWins renderJobs;
  RenderRequest latestRenderRequest{};
  RenderResult readyRenderResult{};
  bool latestRenderRequestValid = false;
  uint32_t lastTakenRenderSequence = 0;
  bool readyRenderResultValid = false;
  bool framePublicationPending = false;
  bool renderFailurePending = false;
  VectorMapActivationRequest pendingVectorMapActivation{};
  VectorMapActivationCompletion completedVectorMapActivation{};
  bool pendingVectorMapActivationValid = false;
  bool completedVectorMapActivationValid = false;
  uint32_t vectorMapActivationSequence = 0;
  bool publishedMapFrame = false;
  bool publishedMapFound = false;
  bool mapAvailabilityKnown = false;
  bool mapAvailabilityAvailable = false;
  bool mapAvailabilityTransitionPending = false;
  MapAvailabilityTransition mapAvailabilityTransition{};
  uint32_t lastCompletedRenderDurationMs = 1000;
  uint32_t navigationEpoch = 1;
  uint32_t styleEpoch = 1;
  uint32_t mapEpoch = 1;
  uint32_t projectionEpoch = 1;
  uint64_t lastStyleSignature = 0;
  uint64_t lastNavigationSignature = 0;
  uint64_t lastProjectionSignature = 0;
  renderer_tuning::Profile rendererTuningProfile_ =
      renderer_tuning::Profile::Current;
  uint64_t lastHeadingSessionSignature = 0;
  uint32_t headingSessionEpoch = 1;
  map_pose_input_policy::Tracker poseInputTracker;
  map_presentation::Presenter posePresenter;
  map_presentation::HeadingResolver headingResolver;
  map_presentation::PresentedPose presentedPose{};
  bool hasPresentedPose = false;
  uint32_t predictionExhaustionCount = 0;
  uint32_t lastPredictionExhaustedMs = 0;
  uint64_t lastFramePresentationSignature = 0;
  uint64_t lastForegroundPresentationSignature = 0;
  RenderResult visibleRenderResult{};
  map_camera::Lag cameraLag;
  uint32_t lastCameraRequestMs = 0;
  bool stableCameraHidden = false;
  lv_obj_t *cameraStatusLabel = nullptr;
  renderer_diagnostics::CameraSample cameraEvidence{};
  std::atomic<bool> renderWorkerShutdown{false};
  std::atomic<bool> renderWorkerExited{true};
  std::atomic<bool> renderWorkerRestartAfterExit{false};

  // Common
  static const uint16_t tileHeight = 466;        // Tile 9x9 Height Size
  static const uint16_t tileWidth = 466;         // Tile 9x9 Width Size
  static const uint16_t renderMapTileSize = 256; // Render map tile size
  static const uint16_t scrollThreshold =
      renderMapTileSize / 2; // Smooth scroll threshold
  static const uint16_t vectorMapTileSize =
      tileHeight / 2;        // Vector map tile size
  uint16_t mapTileSize;      // Actual map tile size (render or vector map)
  uint16_t wptPosX, wptPosY; // Waypoint position on screen map
  lv_obj_t *canvasArrow;     // Canvas for Navigation Arrow in map
  lv_obj_t *canvasForeground; // Viewport labels/route above rolling map cells
  lv_obj_t *canvasMapTemp;   // Full map canvas (not showed)
  lv_obj_t *canvasMap;       // Screen map canvas (showed)
  double prevLat, prevLon;   // Previous Latitude and Longitude
  double destLat, destLon;   // Waypoint destination latitude and longitude
  uint8_t zoomLevel;         // Zoom level for map display
  std::atomic<bool> isMapFound{false}; // Worker-owned map-block load state
  struct tileBounds          // Map boundaries structure
  {
    double lat_min;
    double lat_max;
    double lon_min;
    double lon_max;
  };
  tileBounds totalBounds; // Map boundaries
  struct ScreenCoord      // Screen postion from GPS coordinates
  {
    uint16_t posX;
    uint16_t posY;
  };
  ScreenCoord navArrowPosition; // Navigation Arrow position on screen
  tileBounds getTileBounds(uint32_t tileX, uint32_t tileY, uint8_t zoom);
  bool isCoordInBounds(double lat, double lon, tileBounds bound);
  ScreenCoord coord2ScreenPos(double lon, double lat, uint8_t zoomLevel,
                              uint16_t tileSize);
  void coords2map(double lat, double lon, tileBounds bound, uint16_t *pixelX,
                  uint16_t *pixelY);
  void showNoMap(lv_obj_t *canvas, bool sdPresent);
  void drawMapWidgets(const MapSettings &mapSettings);
  void resetPinchPresentationVisuals();

  struct PinchZoomOutBackdrop {
    bool prepared = false;
    uint8_t baseZoom = map_transform::kMinimumRuntimeZoom;
    uint8_t renderZoom = map_transform::kMaximumRuntimeZoom;
    Point32 center = {0, 0};
    double rotation = 0.0;
    uint16_t canvasHeight = 0;
  } pinchZoomOutBackdrop;

  struct PinchPresentation {
    bool active = false;
    bool settlementPending = false;
    bool capturedFollowGps = true;
    uint8_t baseZoom = map_transform::kMinimumRuntimeZoom;
    Point32 baseCenter = {0, 0};
    double baseRotation = 0.0;
    int16_t initialMidpointX = 0;
    int16_t initialMidpointY = 0;
    int16_t canvasBaseX = 0;
    int16_t canvasBaseY = 0;
    int16_t pivotLocalX = 0;
    int16_t pivotLocalY = 0;
    int16_t backdropBaseX = 0;
    int16_t backdropBaseY = 0;
    int16_t backdropPivotLocalX = 0;
    int16_t backdropPivotLocalY = 0;
    int16_t anchorScreenX = 0;
    int16_t anchorScreenY = 0;
    int16_t markerBaseX = 0;
    int16_t markerBaseY = 0;
    bool hasZoomOutBackdrop = false;
    uint8_t zoomOutBackdropZoom = map_transform::kMaximumRuntimeZoom;
    double finalPreviewRatio = 1.0;
    int16_t finalMidpointX = 0;
    int16_t finalMidpointY = 0;
  } pinchPresentation;

  struct RollingRasterWindow {
    bool valid = false;
    uint8_t zoom = map_transform::kMaximumRuntimeZoom;
    uint8_t gridRadius = map_raster_window::kGridRadius;
    uint8_t gridSpan = map_raster_window::kGridSpan;
    uint16_t tileWidth = map_raster_window::kCellExtentPx;
    uint16_t tileHeight = map_raster_window::kCellExtentPx;
    uint16_t viewportWidth = 0;
    uint16_t viewportHeight = 0;
    double rotation = 0.0;
    double phaseOriginX = 0.0;
    double phaseOriginY = 0.0;
    int32_t originPhaseOffsetX = 0;
    int32_t originPhaseOffsetY = 0;
    uint64_t signature = 0;
  } rollingRasterWindow;
  bool rollingForegroundReady = false;

  map_drag_preview::Controller dragPreviewController;
  map_projection::Projection visibleProjection;
  bool hasVisibleProjection = false;
  bool deferredVectorRedraw = false;
  struct DragPresentation {
    uint8_t baseZoom = map_transform::kMinimumRuntimeZoom;
    int16_t canvasBaseX = 0;
    int16_t canvasBaseY = 0;
    int16_t markerBaseX = 0;
    int16_t markerBaseY = 0;
    bool hasBackdrop = false;
    uint8_t backdropZoom = map_transform::kMaximumRuntimeZoom;
    bool usesRollingRaster = false;
    bool waitsForRollingRaster = false;
    Point32 baseCenter = {};
    double baseRotation = 0.0;
    int32_t baseRasterOffsetX = 0;
    int32_t baseRasterOffsetY = 0;
    map_drag_preview::Offset presentedOffset = {};
  } dragPresentation;

  void applyDragPreviewOffset(map_drag_preview::Offset offset);
  void syncDragPreviewCenterToPresentedOffset();
  void rebaseRollingDragAtVisibleEndpoint();
  void resetDragPresentationVisuals();

public:
  struct VectorMapActivationResult {
    std::string folder;
    bool loaded = false;
    map_probe_diagnostics::Result probe;
  };
  uint16_t mapScrHeight;  // Screen map size height
  uint16_t mapScrWidth;   // Screen map size width
  uint16_t mapScrFull;    // Screen map size in full screen
  bool redrawMap = true;  // Flag to indicate need redraw Map
  bool isPosMoved = true; // Flag when current position changes (vector map)
  bool followGps = true;  // Flag to indicate if map follow GPS signal
  MapTile oldMapTile;     // Old Map tile coordinates and zoom
  MapTile currentMapTile; // Current Map tile coordinates and zoom
  MapTile roundMapTile;   // Boundaries Map tiles
  int8_t tileX = 0;       // Map tile x counter
  int8_t tileY = 0;       // Map tile y counter
  int16_t offsetX = 0;    // Accumulative X scroll map offset
  int16_t offsetY = 0;    // Accumulative Y scroll map offset
  bool scrollUpdated =
      false; // Flag to indicate when map was scrolled and needs to update
  int8_t lastTileX = 0;
  int8_t lastTileY = 0;

  Maps();
  MapTile getMapTile(double lon, double lat, uint8_t zoomLevel, int8_t offsetX,
                     int8_t offsetY);
  void initMap(uint16_t mapHeight, uint16_t mapWidth, uint16_t mapFull);
  bool setVectorMapFolder(const std::string &folder);
  bool probeVectorMapFolder(const std::string &folder);
  map_probe_diagnostics::Result
  probeVectorMapFolderDetailed(const std::string &folder);
  bool requestVectorMapFolderActivation(const std::string &folder);
  bool takeVectorMapFolderActivationResult(VectorMapActivationResult &result);
  void deleteMapScrSprites();
  void createMapScrSprites();
  renderer_diagnostics::CameraSample captureCameraMetadata() const;
  void generateRenderMap(uint8_t zoom);
  bool generateVectorMap(uint8_t zoom);
  bool prepareVectorMapForScreen(uint8_t zoom, bool guidanceScreenActive);
  bool serviceRenderPipeline(uint32_t nowMs);
  bool hasPendingRenderForCurrentScreen() const;
  bool takeFramePublication();
  bool takeRenderFailure();
  bool takeMapAvailabilityTransition(MapAvailabilityTransition &transition);
  bool hasPublishedMapFrame() const { return publishedMapFrame; }
  bool hasMapCanvas() const { return canvasMap != nullptr; }
  void displayMap();
  void updatePositionOverlay();
  void setWaypoint(double wptLat, double wptLon);
  void updateMap();
  void panMap(int8_t dx, int8_t dy);
  void centerOnGps(double lat, double lon);
  void scrollMap(int16_t dx, int16_t dy);
  void preloadTiles(int8_t dirX, int8_t dirY);
  bool preparePinchZoomOutBackdrop(uint8_t baseZoom);
  bool hasPinchZoomOutBackdrop(uint8_t baseZoom) const;
  void invalidatePinchZoomOutBackdrop();
  bool beginDragPreview(uint8_t baseZoom);
  void updateDragPreview(int16_t sessionDx, int16_t sessionDy);
  void commitDragPreview(int16_t sessionDx, int16_t sessionDy,
                         uint32_t nowMs);
  void handoffDragPreviewToPinch();
  void cancelDragPreview();
  void finishDragSettlement();
  bool dragPreviewBlocksMapRender(uint32_t nowMs) const {
    // A prepared standalone-Map raster should start replenishing its edge on
    // the first update after release. The generic delay is useful for legacy
    // viewport rerenders, but here it only lets a rapid second drag consume
    // the remaining prepared margin before recycling begins.
    const uint32_t settlementDelay =
        dragPresentation.usesRollingRaster
            ? 0
            : map_drag_preview::kSettlementDelayMs;
    return dragPreviewController.blocksRender(nowMs, settlementDelay);
  }
  bool isDragPreviewActive() const { return dragPreviewController.active(); }
  bool isDragSettlementPending() const {
    return dragPreviewController.settlementPending();
  }
  bool beginPinchPreview(int16_t midpointX, int16_t midpointY,
                         uint8_t baseZoom);
  void updatePinchPreview(double previewRatio, int16_t midpointX,
                          int16_t midpointY);
  void cancelPinchPreview();
  void commitPinchZoom(uint8_t targetZoom, double finalPreviewRatio,
                       int16_t finalMidpointX, int16_t finalMidpointY);
  void finishPinchSettlement();
  bool isPinchPreviewActive() const { return pinchPresentation.active; }
  bool isPinchSettlementPending() const {
    return pinchPresentation.settlementPending;
  }
  bool takeDeferredVectorRedraw() {
    const bool pending = deferredVectorRedraw;
    deferredVectorRedraw = false;
    return pending;
  }

  // Map rotation
  enum RotationMode { ROT_NORTH_UP = 0, ROT_COURSE_UP = 1 };
  RotationMode rotationMode = ROT_NORTH_UP;
  double rotationRad = 0; // Current rotation in radians
  void toggleRotationMode();
  void updateArrowColor();
  bool debugIsMapFound() const { return publishedMapFound; }
  uint32_t debugPredictionAgeMs() const {
    return hasPresentedPose ? presentedPose.predictionAgeMs : 0U;
  }
  bool debugPredictionGraceActive() const {
    return hasPresentedPose && presentedPose.predictionGraceActive;
  }
  bool debugPredictionExhausted() const {
    return hasPresentedPose && presentedPose.predictionExhausted;
  }
  uint32_t debugPredictionExhaustionCount() const {
    return predictionExhaustionCount;
  }
  uint32_t debugLastPredictionExhaustedMs() const {
    return lastPredictionExhaustedMs;
  }
  size_t debugCachedBlockCount() const {
    return cachedBlockCount.load(std::memory_order_acquire);
  }
  bool debugStreetLabelFontHealthy() const {
    return streetLabelFontHealthy.load(std::memory_order_acquire);
  }
  bool setRendererTuningProfile(renderer_tuning::Profile profile,
                                uint32_t nowMs);
  renderer_tuning::Profile rendererTuningProfile() const {
    return rendererTuningProfile_;
  }
  bool takeStreetLabelRuntimeFailure(std::string &code);
};
