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
#include "lvgl.h"
#include "mapVars.h"
#include <Arduino.h>

// Forward declarations
struct MapSettings;

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
    std::vector<Polyline, PsramAllocator<Polyline>> polylines;
    std::vector<Polygon, PsramAllocator<Polygon>> polygons;

    // Spatial grid for polygon culling: grid[cellIndex] = list of polygon
    // indices
    using PolygonGridCell = std::vector<uint16_t, PsramAllocator<uint16_t>>;
    std::vector<PolygonGridCell, PsramAllocator<PolygonGridCell>> polygonGrid;
  };
  struct ViewPort // Vector map viewport structure
  {
    void setCenter(Point32 pcenter);
    Point32 center;
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
  Point32 point = viewPort.center; // Vector map GPS position point
  double lat2y(double lat);
  double lon2x(double lon);
  double mercatorX2lon(double x);
  double mercatorY2lat(double y);
  int16_t toScreenCoord(const int32_t pxy, const int32_t screenCenterxy);
  uint32_t idx;
  int16_t parseInt16(char *file);
  void parseStrUntil(char *file, char terminator, char *str);
  void parseCoords(char *file,
                   std::vector<Point16, PsramAllocator<Point16>> &points);
  BBox parseBbox(String str);
  MapBlock *readMapBlock(String fileName);
  MapBlock *readMapBlockBinary(char *buffer, size_t fileSize);
  void
  buildPolygonGrid(MapBlock *mblock); // Build spatial grid for polygon culling
  void fillPolygon(const Polygon &p, lv_obj_t *canvas);
  void drawLine(lv_obj_t *canvas, int16_t x1, int16_t y1, int16_t x2,
                int16_t y2, uint16_t color);
  void getMapBlocks(BBox &bbox, MemCache &memCache);
  void readVectorMap(ViewPort &viewPort, MemCache &memCache, lv_obj_t *canvas,
                     uint8_t zoom, double rotation);
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
  void showNoMap(lv_obj_t *canvas);
  void drawMapWidgets(const MapSettings &mapSettings);

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
  void deleteMapScrSprites();
  void createMapScrSprites();
  void generateRenderMap(uint8_t zoom);
  void generateVectorMap(uint8_t zoom);
  void displayMap();
  void setWaypoint(double wptLat, double wptLon);
  void updateMap();
  void panMap(int8_t dx, int8_t dy);
  void centerOnGps(double lat, double lon);
  void scrollMap(int16_t dx, int16_t dy);
  void preloadTiles(int8_t dirX, int8_t dirY);

  // Map rotation
  enum RotationMode { ROT_NORTH_UP = 0, ROT_COURSE_UP = 1 };
  RotationMode rotationMode = ROT_NORTH_UP;
  double rotationRad = 0; // Current rotation in radians
  void toggleRotationMode();
  void updateArrowColor();
  bool debugIsMapFound() const { return isMapFound; }
  size_t debugCachedBlockCount() const { return memCache.blocks.size(); }
};
