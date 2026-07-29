#pragma once

#include <array>
#include <cstdint>
#include <map>
#include <math.h>
#include <string>
#include <vector>

// #include "../../compass/compass.hpp" // Circular dependency if not careful,
// but likely needed for getHeading
#include "../../settings/settings.hpp"
#include "../../storage/storage.hpp"
// #include "../../tft/tft.hpp" // Removed or minimal include if possible?
#include "../../utils/src/gpsMath.hpp"
#include "mapTransform.hpp"
#include "../../utils/src/mapDragPreview.hpp"
#include "../../utils/src/mapRasterWindow.hpp"
#include "lvgl.h"
#include "mapFontAsset.hpp"
#include "mapLabelBlock.hpp"
#include "mapLabelLayout.hpp"
#include "mapVars.h"
#include <Arduino.h>

// Forward declarations
struct MapSettings;
struct ScreenMapRenderSettings;

class Maps {
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
    bool inView = false;
    uint8_t formatVersion = 1;
    std::vector<Polyline, PsramAllocator<Polyline>> polylines;
    std::vector<Polygon, PsramAllocator<Polygon>> polygons;
    map_label_block::Block labelData;

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
  MemCache memCache;               // Memory Cache
  String vectorMapFolder = "/sdcard/VECTMAP/";
  map_font_asset::Asset labelFontAsset;
  bool streetLabelRuntimeFailurePending = false;
  std::string streetLabelRuntimeFailureCode;
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
    uint8_t markerScale = 0;
    bool guidance = false;

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
  bool fillPolygon(const Polygon &p, lv_obj_t *canvas);
  void drawLine(lv_obj_t *canvas, int16_t x1, int16_t y1, int16_t x2,
                int16_t y2, uint16_t color, uint8_t width);
  bool getMapBlocks(BBox &bbox, MemCache &memCache);
  bool readVectorMap(ViewPort &viewPort, MemCache &memCache, lv_obj_t *canvas,
                     uint8_t zoom, double rotation);
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
  bool rollingRasterCompatible(uint8_t zoom, uint16_t viewportWidth,
                               uint16_t viewportHeight,
                               uint64_t signature) const;
  bool shouldUseRollingRasterWindow(uint8_t zoom) const;
  uint64_t rollingRasterSignature() const;
  double visibleMapRotation() const;
  bool drawStreetLabels(ViewPort &viewPort, MemCache &memCache,
                        lv_obj_t *canvas, uint8_t zoom, double rotation,
                        const ScreenMapRenderSettings &style);
  void getPosition(double lat, double lon);

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
  lv_obj_t *canvasMapTemp;   // Full map canvas (not showed)
  lv_obj_t *canvasMap;       // Screen map canvas (showed)
  double prevLat, prevLon;   // Previous Latitude and Longitude
  double destLat, destLon;   // Waypoint destination latitude and longitude
  uint8_t zoomLevel;         // Zoom level for map display
  bool isMapFound = false;   // Flag to indicate when map is found on SD
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

  map_drag_preview::Controller dragPreviewController;
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
  void deleteMapScrSprites();
  void createMapScrSprites();
  void generateRenderMap(uint8_t zoom);
  bool generateVectorMap(uint8_t zoom);
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
  bool debugIsMapFound() const { return isMapFound; }
  size_t debugCachedBlockCount() const { return memCache.blocks.size(); }
  bool debugStreetLabelFontHealthy() const { return labelFontAsset.healthy(); }
  bool takeStreetLabelRuntimeFailure(std::string &code);
};
