/**
 * @file mainScr.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL - Main Screen
 * @version 0.2.2
 * @date 2025-05
 */

#include "mainScr.hpp"
#include "../../ble_navigation/ble_navigation.hpp" // Access mapRenderSettings
#include "guiLayout.hpp"
// #include "../../compass/compass.hpp"

bool isMainScreen = false; // Flag to indicate main screen is selected
bool isScrolled = true;    // Flag to indicate when tileview was scrolled
bool isReady = false;      // Flag to indicate when tileview scroll was finished
bool isScrollingMap = false;  // Flag to indicate if map is scrolling
bool canScrollMap = true;     // SIMPLIFIED: Always allow map scrolling
uint8_t activeTile = 0;       // Current active tile
uint8_t gpxAction = WPT_NONE; // Current Waypoint Action
int heading = 0;              // Heading value (Compass or GPS)
extern uint32_t DOUBLE_TOUCH_EVENT;

#ifndef DISABLE_COMPASS
extern Compass compass;
#endif
extern Gps gps;
extern wayPoint loadWpt;

uint8_t toolBarOffset = gui_layout::MAP_TOOLBAR_OFFSET;
uint8_t toolBarSpace = gui_layout::MAP_TOOLBAR_SPACE;

static void positionMapToolbarButtons(uint16_t mapHeight) {
  if (!btnFullScreen || !btnZoomOut || !btnZoomIn) {
    return;
  }

  const uint8_t inset = gui_layout::MAP_TOOLBAR_INSET;
  lv_obj_set_pos(btnFullScreen, inset, mapHeight - toolBarOffset);
  lv_obj_set_pos(btnZoomOut, inset, mapHeight - (toolBarOffset + toolBarSpace));
  lv_obj_set_pos(btnZoomIn, inset,
                 mapHeight - (toolBarOffset + (2 * toolBarSpace)));
}

lv_obj_t *tilesScreen;
lv_obj_t *compassTile;
lv_obj_t *navTile;
lv_obj_t *mapTile;
lv_obj_t *satTrackTile;
lv_obj_t *btnFullScreen;
lv_obj_t *btnZoomIn;
lv_obj_t *btnZoomOut;

Maps mapView;

static int16_t mapInteractionAnchorX() {
  return gui_layout::mapAnchorX(mapView.mapScrWidth);
}

static int16_t mapInteractionAnchorY() {
  const uint16_t mapHeight =
      mapSet.mapFullScreen ? mapView.mapScrFull : mapView.mapScrHeight;
  return gui_layout::mapAnchorY(mapHeight);
}

/**
 * @brief Trigger map redraw (called by BLE when route geometry is received)
 */
void triggerMapRedraw() {
  mapView.isPosMoved = true;
  mapView.redrawMap = true;
}

/**
 * @brief Update compass screen event
 *
 * @param event
 */
void updateCompassScr(lv_event_t *event) {
  lv_obj_t *obj = (lv_obj_t *)lv_event_get_current_target(event);
  if (obj == compassHeading) {
    lv_label_set_text_fmt(compassHeading, "%5d\xC2\xB0", heading);
    lv_img_set_angle(compassImg, -(heading * 10));
  }
  if (obj == latitude)
    lv_label_set_text_fmt(latitude, "%s",
                          latFormatString(gps.gpsData.latitude));
  if (obj == longitude)
    lv_label_set_text_fmt(longitude, "%s",
                          lonFormatString(gps.gpsData.longitude));
  if (obj == altitude)
    lv_label_set_text_fmt(obj, "%4d m.", gps.gpsData.altitude);
  if (obj == speedLabel)
    lv_label_set_text_fmt(obj, "%3d Km/h", gps.gpsData.speed);
  if (obj == sunriseLabel) {
    lv_label_set_text_static(obj, gps.gpsData.sunriseHour);
    lv_label_set_text_static(sunsetLabel, gps.gpsData.sunsetHour);
  }
}

/**
 * @brief Get the active tile
 *
 * @param event
 */
void getActTile(lv_event_t *event) {
  if (isReady) {
    isScrolled = true;
    mapView.redrawMap = true;

    if (activeTile == MAP) {
      mapView.createMapScrSprites();
      if (mapSet.mapFullScreen) {
        lv_obj_add_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(menuBtn, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(notifyBarHour, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(notifyBarIcons, LV_OBJ_FLAG_HIDDEN);
      } else {
        lv_obj_clear_flag(notifyBarHour, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(notifyBarIcons, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(menuBtn, LV_OBJ_FLAG_HIDDEN);

        if (isBarOpen)
          lv_obj_clear_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);
        else
          lv_obj_add_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);
      }
    } else if (activeTile != MAP) {
      lv_obj_clear_flag(menuBtn, LV_OBJ_FLAG_HIDDEN);

      if (isBarOpen)
        lv_obj_clear_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);
    }
  } else
    isReady = true;

  lv_obj_t *actTile = lv_tileview_get_tile_act(tilesScreen);
  lv_coord_t tileX = lv_obj_get_x(actTile) / TFT_WIDTH;
  activeTile = tileX;
}

/**
 * @brief Tile start scrolling event
 *
 * @param event
 */
void scrollTile(lv_event_t *event) {
  isScrolled = false;
  isReady = false;
  mapView.redrawMap = false;

  if (mapSet.mapFullScreen) {
    lv_obj_clear_flag(notifyBarHour, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(notifyBarIcons, LV_OBJ_FLAG_HIDDEN);
  }

  mapView.deleteMapScrSprites();
}

/**
 * @brief Update Main Screen
 *
 */
void updateMainScreen(lv_timer_t *t) {
  // Handle BLE-triggered map updates OUTSIDE of isScrolled check
  // This ensures continuous updates even when user hasn't dragged
  if (isMainScreen && activeTile == MAP &&
      (mapView.isPosMoved || mapView.redrawMap)) {

    // Check if settings changed externally (via BLE) and sync map state
    // If setting says CourseUp but map is NorthUp, switch it
    if (mapRenderSettings.mapRotationMode == 1 &&
        mapView.rotationMode != Maps::ROT_COURSE_UP) {
      mapView.rotationMode = Maps::ROT_COURSE_UP;
      mapView.updateArrowColor();
      mapView.isPosMoved = true; // Force redraw
      log_i("Creating Map: Syncing rotation to Course Up (from settings)");
    } else if (mapRenderSettings.mapRotationMode == 0 &&
               mapView.rotationMode != Maps::ROT_NORTH_UP) {
      mapView.rotationMode = Maps::ROT_NORTH_UP;
      mapView.rotationRad = 0;
      mapView.updateArrowColor();
      mapView.isPosMoved = true; // Force redraw
      log_i("Creating Map: Syncing rotation to North Up (from settings)");
    }

    log_i("BLE map update: isPosMoved=%d redrawMap=%d followGps=%d",
          mapView.isPosMoved, mapView.redrawMap, mapView.followGps);

    // Re-center on GPS if in follow mode
    if (mapView.followGps) {
      mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
    }

    // Trigger map regeneration and display
    lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
  }

  if (isScrolled && isMainScreen) {
    switch (activeTile) {
    case COMPASS:
#ifdef ENABLE_COMPASS
      if (!waitScreenRefresh)
        heading = compass.getHeading();
      if (compass.isUpdated())
        lv_obj_send_event(compassHeading, LV_EVENT_VALUE_CHANGED, NULL);
#endif
#ifndef ENABLE_COMPASS
      heading = gps.gpsData.heading;
      lv_obj_send_event(compassHeading, LV_EVENT_VALUE_CHANGED, NULL);
#endif
      if (gps.hasLocationChange()) {
        lv_obj_send_event(latitude, LV_EVENT_VALUE_CHANGED, NULL);
        lv_obj_send_event(longitude, LV_EVENT_VALUE_CHANGED, NULL);
      }
      if (gps.isAltitudeChanged())
        lv_obj_send_event(altitude, LV_EVENT_VALUE_CHANGED, NULL);
      if (gps.isSpeedChanged())
        lv_obj_send_event(speedLabel, LV_EVENT_VALUE_CHANGED, NULL);
      break;

    case MAP: {
      // SIMULATE GPS MOVEMENT - TEST MODE
      // Removed legacy simulation code - controlled via BLE now

#ifdef ENABLE_COMPASS
      heading = compass.getHeading();
#endif
      // Track last heading for Course-Up auto-rotation
      static uint16_t lastHeading = 0;
      uint16_t currentHeading = gps.gpsData.heading;

      // In Course-Up mode, redraw map when heading changes significantly (> 5
      // degrees)
      if (mapView.rotationMode == Maps::ROT_COURSE_UP) {
        int headingDiff = abs((int)currentHeading - (int)lastHeading);
        // Handle wrap-around (e.g., 355 to 5 = 10 degrees, not 350)
        if (headingDiff > 180)
          headingDiff = 360 - headingDiff;

        if (headingDiff > 5) {
          log_i("Course-Up: Heading changed from %d to %d (diff=%d), "
                "triggering redraw",
                lastHeading, currentHeading, headingDiff);
          mapView.isPosMoved = true; // Force map regeneration with new rotation
          lastHeading = currentHeading;
        }
      } else {
        lastHeading = currentHeading; // Track heading even in North-Up for
                                      // smooth transition
      }

      // Handle BLE simulated GPS: triggerMapRedraw() sets isPosMoved/redrawMap
      // ALWAYS regenerate map when these flags are set, regardless of followGps
      // This ensures continuous updates for GPS position and route overlay
      if (mapView.isPosMoved || mapView.redrawMap) {
        log_i(
            "MAP case: Flags detected! isPosMoved=%d redrawMap=%d followGps=%d",
            mapView.isPosMoved, mapView.redrawMap, mapView.followGps);
        // Only re-center on GPS if in follow mode
        if (mapView.followGps) {
          mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
        }
        mapView.redrawMap = true;
      }

      // Also handle hardware GPS location changes (when in follow mode)
      if (gps.hasLocationChange() && mapView.followGps) {
        mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
        mapView.redrawMap = true;
      }

      lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
      break;
    }

    case NAV:
      lv_obj_send_event(navTile, LV_EVENT_VALUE_CHANGED, NULL);
      break;

    case SATTRACK:
      lv_obj_send_event(satTrackTile, LV_EVENT_VALUE_CHANGED, NULL);
      break;

    default:
      break;
    }
  }
}

/**
 * @brief Map Gesture Event
 *
 * @param event
 */
void gestureEvent(lv_event_t *event) {
  lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());

  if (showMapToolBar) {
    // if (activeTile == MAP && isMainScreen)
    // {
    //   switch (dir)
    //   {
    //     case LV_DIR_LEFT:
    //       // mapView.panMap(1,0);
    //       mapView.scrollMap(30,0);
    //       break;
    //     case LV_DIR_RIGHT:
    //       // mapView.panMap(-1,0);
    //       mapView.scrollMap(-30,0);
    //       break;
    //     case LV_DIR_TOP:
    //       //mapView.panMap(0,1);
    //       mapView.scrollMap(0,30);
    //       break;
    //     case LV_DIR_BOTTOM:
    //       // mapView.panMap(0,-1);
    //       mapView.scrollMap(0,-30);
    //       break;
    //   }
    // }
  }
}

/**
 * @brief Update map event
 *
 * @param event
 */
void updateMap(lv_event_t *event) {
  // Only regenerate map if position changed to avoid blocking the main loop
  if (mapView.isPosMoved) {
    if (mapSet.vectorMap)
      mapView.generateVectorMap(zoom);
    else
      mapView.generateRenderMap(zoom);
    // Clear flag AFTER generation complete (not inside generateVectorMap)
    // This ensures BLE updates during generation will queue another cycle
    mapView.isPosMoved = false;
  }

  if (mapView.redrawMap) {
    mapView.displayMap();
    mapView.redrawMap = false; // Clear after display
  }
}

/**
 * @brief Update Satellite Tracking
 *
 * @param event
 */
void updateSatTrack(lv_event_t *event) {
  if (gps.isDOPChanged()) {
    lv_label_set_text_fmt(pdopLabel, "PDOP: %.1f", gps.gpsData.pdop);
    lv_label_set_text_fmt(hdopLabel, "HDOP: %.1f", gps.gpsData.hdop);
    lv_label_set_text_fmt(vdopLabel, "VDOP: %.1f", gps.gpsData.vdop);
  }

  if (gps.isAltitudeChanged())
    lv_label_set_text_fmt(altLabel, "ALT: %4dm.", gps.gpsData.altitude);

  drawSatSNR();
  drawSatSky();
}

/**
 * @brief Map Tool Bar Event
 *
 * @param event
 */
void mapToolBarEvent(lv_event_t *event) {
  lv_event_code_t code = lv_event_get_code(event);

  showMapToolBar = !showMapToolBar;
  canScrollMap = !canScrollMap;

  if (!mapSet.mapFullScreen) {
    positionMapToolbarButtons(mapView.mapScrHeight);
  } else {
    positionMapToolbarButtons(
        mapView.mapScrFull - gui_layout::MAP_TOOLBAR_FULLSCREEN_BOTTOM_MARGIN);
  }

  if (!showMapToolBar) {
    lv_obj_clear_flag(btnFullScreen, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(btnZoomOut, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(btnZoomIn, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(tilesScreen, LV_OBJ_FLAG_SCROLLABLE);
    mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
  } else {
    lv_obj_add_flag(btnFullScreen, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(btnZoomOut, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_flag(btnZoomIn, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(tilesScreen, LV_OBJ_FLAG_SCROLLABLE);
  }
}

/**
 * @brief Scrool Map Event
 *
 * @param event
 */
void scrollMapEvent(lv_event_t *event) {
  if (canScrollMap) {
    lv_event_code_t code = lv_event_get_code(event);
    lv_indev_t *indev = lv_event_get_indev(event);
    static int last_x = 0, last_y = 0;
    static bool isDragging = false;
    static uint32_t pressStartTime = 0;
    static bool longPressTriggered = false;
    static int pressStartX = 0, pressStartY = 0;
    static int32_t pendingDx = 0, pendingDy = 0;
    static uint32_t lastDragRedrawTime = 0;
    lv_point_t p;

    auto flushDragMovement = [](bool force) {
      if (pendingDx == 0 && pendingDy == 0)
        return;

      const uint32_t now = millis();
      const uint32_t DRAG_REDRAW_INTERVAL_MS = 220;
      const int32_t DRAG_REDRAW_MIN_DELTA = 36;
      const int32_t totalDelta = abs(pendingDx) + abs(pendingDy);

      if (!force && lastDragRedrawTime != 0 &&
          now - lastDragRedrawTime < DRAG_REDRAW_INTERVAL_MS &&
          totalDelta < DRAG_REDRAW_MIN_DELTA) {
        return;
      }

      int16_t dx = pendingDx;
      int16_t dy = pendingDy;
      pendingDx = 0;
      pendingDy = 0;
      lastDragRedrawTime = now;

      log_i("DRAG FLUSH: dx=%d dy=%d force=%d", dx, dy, force);
      mapView.scrollMap(dx, dy);
      mapView.redrawMap = true;
      lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
    };

    switch (code) {
    case LV_EVENT_PRESSED: {
      lv_indev_get_point(indev, &p);

      // Filter out phantom touches at corner (touch driver error value)
      if (p.x >= 460 && p.y >= 460) {
        log_w("PHANTOM TOUCH IGNORED: x=%d y=%d (corner)", p.x, p.y);
        break;
      }

      last_x = p.x;
      last_y = p.y;
      pressStartX = p.x;
      pressStartY = p.y;
      pressStartTime = millis();
      isDragging = true;
      longPressTriggered = false;
      pendingDx = 0;
      pendingDy = 0;
      lastDragRedrawTime = 0;
      isScrollingMap = true;
      log_i("PRESSED: x=%d y=%d", p.x, p.y);
      break;
    }

    case LV_EVENT_PRESSING: {
      if (!isDragging)
        break; // Guard: only process if we're in a drag session

      lv_indev_get_point(indev, &p);

      int dx = p.x - last_x;
      int dy = p.y - last_y;

      // SANITY FILTER: Reject sudden large jumps (touch driver glitch)
      // A human can't move more than ~100px between samples
      // INCREASED to 400 because low FPS (150ms redraw) allows finger to move
      // further
      const int MAX_JUMP = 400;
      if (abs(dx) > MAX_JUMP || abs(dy) > MAX_JUMP) {
        log_w("GLITCH REJECTED: p(%d,%d) last(%d,%d) jump: dx=%d dy=%d", p.x,
              p.y, last_x, last_y, dx, dy);
        break; // Don't update last_x/y - treat this as invalid data
      }

      const int SCROLL_THRESHOLD = 5;

      // Check for long press (1 second hold without significant movement)
      if (!longPressTriggered && pressStartTime > 0) {
        int totalMoveX = abs(p.x - pressStartX);
        int totalMoveY = abs(p.y - pressStartY);

        if (totalMoveX < 20 && totalMoveY < 20) {
          // Finger hasn't moved much - check for long press
          if (millis() - pressStartTime > 1800) {
            // Long press detected! Re-enable GPS following
            log_i("LONG PRESS DETECTED: Re-enabling GPS following");
            mapView.followGps = true;
            mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
            mapView.redrawMap = true;
            longPressTriggered = true;
            // Don't process as a scroll
            break;
          }
        } else {
          // Finger moved - this is a scroll, not a long press
          pressStartTime = 0;
        }
      }

      if (abs(dx) > SCROLL_THRESHOLD || abs(dy) > SCROLL_THRESHOLD) {
        log_i("PRESSING: p(%d,%d) last(%d,%d) -> dx=%d dy=%d", p.x, p.y, last_x,
              last_y, dx, dy);
        pendingDx += gui_layout::mapDragDelta(dx);
        pendingDy += gui_layout::mapDragDelta(dy);
        last_x = p.x;
        last_y = p.y;
        pressStartTime = 0;
        flushDragMovement(false);
      }
      break;
    }

    case LV_EVENT_RELEASED:
    case LV_EVENT_PRESS_LOST: {
      lv_indev_get_point(indev, &p);

      if (isDragging) {
        int dx = p.x - last_x;
        int dy = p.y - last_y;
        const int MAX_JUMP = 400;
        const int SCROLL_THRESHOLD = 5;
        if (abs(dx) <= MAX_JUMP && abs(dy) <= MAX_JUMP &&
            (abs(dx) > SCROLL_THRESHOLD || abs(dy) > SCROLL_THRESHOLD)) {
          pendingDx += gui_layout::mapDragDelta(dx);
          pendingDy += gui_layout::mapDragDelta(dy);
        }
        flushDragMovement(true);
      }

      // Detect short-tap on GPS indicator dot to toggle rotation mode
      // Short tap = released within 300ms with minimal movement
      if (!longPressTriggered && pressStartTime > 0 &&
          millis() - pressStartTime < 300) {
        int totalMove = abs(p.x - pressStartX) + abs(p.y - pressStartY);
        if (totalMove < 30) {
          // GPS indicator is at the board-specific map anchor when followGps
          // is true.
          // When followGps is false, it could be anywhere - use center area
          // anyway since user expects to tap the center indicator
          int centerX = mapInteractionAnchorX();
          int centerY = mapInteractionAnchorY();
          int distX = abs(p.x - centerX);
          int distY = abs(p.y - centerY);
          log_i("SHORT TAP CHECK: pos(%d,%d) center(%d,%d) dist(%d,%d)", p.x,
                p.y, centerX, centerY, distX, distY);
          // Increased hit area to 120px radius (user request to double it)
          if (distX < 120 && distY < 120) {
            log_i("SHORT TAP ON GPS DOT: Toggling rotation mode");
            mapView.toggleRotationMode();

            // Sync back to mapRenderSettings so it persists if we save or app
            // queries it (though app push is one-way usually)
            mapRenderSettings.mapRotationMode =
                (mapView.rotationMode == Maps::ROT_COURSE_UP) ? 1 : 0;
            log_i("Synced rotation mode to settings: %d",
                  mapRenderSettings.mapRotationMode);
          }
        }
      }

      isDragging = false;
      isScrollingMap = false;
      pressStartTime = 0;
      log_i("RELEASED/LOST: drag ended%s",
            longPressTriggered ? " (long press)" : "");
      break;
    }
    }
  }
}

/**
 * @brief Full Screen Event Toolbar
 *
 * @param event
 */
void fullScreenEvent(lv_event_t *event) {
  mapSet.mapFullScreen = !mapSet.mapFullScreen;

  if (!mapSet.mapFullScreen) {
    positionMapToolbarButtons(mapView.mapScrHeight);

    if (isBarOpen)
      lv_obj_clear_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);
    else
      lv_obj_add_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);

    lv_obj_clear_flag(menuBtn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(notifyBarHour, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(notifyBarIcons, LV_OBJ_FLAG_HIDDEN);
  } else {
    positionMapToolbarButtons(
        mapView.mapScrFull - gui_layout::MAP_TOOLBAR_FULLSCREEN_BOTTOM_MARGIN);
    lv_obj_add_flag(buttonBar, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(menuBtn, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(notifyBarHour, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(notifyBarIcons, LV_OBJ_FLAG_HIDDEN);
  }

  mapView.deleteMapScrSprites();
  mapView.createMapScrSprites();

  mapView.redrawMap = true;

  lv_obj_invalidate(tilesScreen);
  lv_obj_send_event(mapTile, LV_EVENT_REFRESH, NULL);
}

/**
 * @brief Zoom In Event Toolbar
 *
 * @param event
 */
void zoomInEvent(lv_event_t *event) {
  if (!mapSet.vectorMap) {
    if (zoom >= minZoom && zoom < maxZoom)
      zoom++;
  } else {
    zoom--;
    mapView.isPosMoved = true;
    if (zoom < 1) {
      zoom = 1;
      mapView.isPosMoved = false;
    }
  }

  lv_obj_send_event(mapTile, LV_EVENT_REFRESH, NULL);
}

/**
 * @brief Zoom Out Event Toolbar
 *
 * @param event
 */
void zoomOutEvent(lv_event_t *event) {
  if (!mapSet.vectorMap) {
    if (zoom <= maxZoom && zoom > minZoom)
      zoom--;
  } else {
    zoom++;
    mapView.isPosMoved = true;
    if (zoom > MAX_ZOOM) {
      zoom = MAX_ZOOM;
      mapView.isPosMoved = false;
    }
  }

  lv_obj_send_event(mapTile, LV_EVENT_REFRESH, NULL);
}

/**
 * @brief Navigation update event
 *
 * @param event
 */
void updateNavEvent(lv_event_t *event) {
  int wptDistance = (int)calcDist(gps.gpsData.latitude, gps.gpsData.longitude,
                                  loadWpt.lat, loadWpt.lon);
  lv_label_set_text_fmt(distNav, "%d m.", wptDistance);

  if (wptDistance == 0) {
    LV_IMG_DECLARE(navfinish);
    lv_img_set_src(arrowNav, &navfinish);
    lv_img_set_angle(arrowNav, 0);
  } else {
#ifdef ENABLE_COMPASS
    double wptCourse = calcCourse(gps.gpsData.latitude, gps.gpsData.longitude,
                                  loadWpt.lat, loadWpt.lon) -
                       compass.getHeading();
#endif
#ifndef ENABLE_COMPASS
    double wptCourse = calcCourse(gps.gpsData.latitude, gps.gpsData.longitude,
                                  loadWpt.lat, loadWpt.lon) -
                       gps.gpsData.heading;
#endif
    lv_img_set_angle(arrowNav, (wptCourse * 10));
  }
}

/**
 * @brief Create Main Screen - SIMPLIFIED: Map Only
 *
 */
void createMainScr() {
  mainScreen = lv_obj_create(NULL);

  // SIMPLIFIED: No tileview, just map directly on screen
  // Create a simple container for the map that takes the full screen
  mapTile = lv_obj_create(mainScreen);
  lv_obj_remove_style_all(mapTile);
  lv_obj_set_size(mapTile, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_pos(mapTile, 0, 0);
  lv_obj_clear_flag(mapTile, LV_OBJ_FLAG_SCROLLABLE);
  activeTile = MAP; // Ensure map logic runs in updateMainScreen

  // Set tilesScreen to same as mapTile for compatibility
  tilesScreen = mapTile;

  // Map Tile Events
  lv_obj_add_event_cb(mapTile, updateMap, LV_EVENT_VALUE_CHANGED, NULL);
  lv_obj_add_event_cb(mapTile, scrollMapEvent, LV_EVENT_ALL, NULL);

  // Initialize Map Rotation Mode from Settings
  // Sync map view state with persisted BLE setting
  if (mapRenderSettings.mapRotationMode == 1) { // 1 = Course Up
    mapView.rotationMode = Maps::ROT_COURSE_UP;
  } else {
    mapView.rotationMode = Maps::ROT_NORTH_UP;
  }
  mapView.rotationRad = 0; // Reset rotation
  mapView.updateArrowColor();

  // Sync zoom level from settings
  extern uint8_t zoom;
  if (mapRenderSettings.zoomLevel >= 0 && mapRenderSettings.zoomLevel <= 5) {
    zoom = mapRenderSettings.zoomLevel;
  }
}
