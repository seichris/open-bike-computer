/**
 * @file mainScr.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  LVGL - Main Screen
 * @version 0.2.2
 * @date 2025-05
 */

#include "mainScr.hpp"
#include "../../ble_navigation/ble_navigation.hpp" // Access mapRenderSettings
#include "../../route_overlay/route_overlay.hpp"
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
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
extern bool touchPressed;
#endif

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
lv_obj_t *rideStatsTile;
lv_obj_t *batteryStatusTile;
lv_obj_t *mapTile;
lv_obj_t *satTrackTile;
lv_obj_t *btnFullScreen;
lv_obj_t *btnZoomIn;
lv_obj_t *btnZoomOut;

static lv_obj_t *mapGuidanceOverlay;
static lv_obj_t *mapGuidanceArrow;
static lv_obj_t *mapGuidanceDistance;
static lv_obj_t *mapGuidanceDestinationPicker;
static lv_obj_t *mapGuidanceCycleStrip;
static uint32_t mapGuidanceCatalogRevision = UINT32_MAX;
static uint32_t mapGuidanceStatusRevision = UINT32_MAX;
static bool mapGuidancePickerExpanded = true;
static bool mapGuidanceHadNavigationData = false;
struct DestinationRowContext {
  uint32_t generation = 0;
  uint16_t token = 0;
};
static constexpr lv_point_precise_t MAP_GUIDANCE_STAR_POINTS[] = {
    {9, 0},  {11, 6}, {18, 7}, {13, 11}, {15, 18}, {9, 14},
    {3, 18}, {5, 11}, {0, 7},  {7, 6},   {9, 0}};
static DestinationRowContext
    mapGuidanceRowContexts[destination_picker_protocol::MAX_ITEMS];

Maps mapView;

bool isMapScreenActive() { return activeTile == MAP; }

bool isMapGuidanceScreenActive() { return activeTile == MAP_GUIDANCE; }

bool shouldInterruptMapRenderForScreenCycle() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  if (!isMainScreen || activeTile != MAP_GUIDANCE) {
    return false;
  }

  // The BOOT button always handles the forward action. On Map + Navigation,
  // also use the touch controller's interrupt hint while the destination
  // picker is open (or tap-to-switch is enabled) so a new tap can pre-empt the
  // synchronous vector renderer before LVGL consumes the touch event.
  if (waveshareBootScreenCyclePending ||
      digitalRead(BOARD_BOOT_PIN) == LOW) {
    return true;
  }
  const bool pickerNeedsInput =
      mapGuidancePickerExpanded && !hasCurrentNavigationData();
  return (pickerNeedsInput || mapRenderSettings.tapToSwitchScreens) &&
         (touchPressed || digitalRead(TCH_I2C_INT) == LOW);
#else
  return false;
#endif
}

const ScreenMapRenderSettings &currentMapStyleSettings() {
  return map_profile_protocol::select(mapRenderSettings.mapStyle,
                                      mapRenderSettings.mapNavigationStyle,
                                      isMapGuidanceScreenActive());
}

static void tapCycleScreenEvent(lv_event_t *event);
static void mapGuidanceOverlayTapEvent(lv_event_t *event);
static void updateMapGuidanceOverlay();
static void refreshMapGuidanceOverlayAsync(void *userData);

static int16_t mapInteractionAnchorX() {
  return gui_layout::mapScreenAnchorX(TFT_WIDTH, mapView.mapScrWidth);
}

static int16_t mapInteractionAnchorY() {
  const uint16_t mapHeight =
      mapSet.mapFullScreen ? mapView.mapScrFull : mapView.mapScrHeight;
  return gui_layout::mapScreenAnchorY(TFT_HEIGHT, mapHeight);
}

static uint16_t currentCourseUpHeading() {
  uint16_t routeHeading = 0;
  if (routeOverlay.headingNear(gps.gpsData.latitude, gps.gpsData.longitude,
                               routeHeading)) {
    return routeHeading;
  }
  return gps.gpsData.heading;
}

static bool isMapBackedTile(uint8_t tile) {
  return tile == MAP || tile == MAP_GUIDANCE;
}

static uint8_t normalizedEnabledScreensMask() {
  const uint8_t mask =
      mapRenderSettings.enabledScreensMask & DEVICE_SCREEN_SUPPORTED_MASK;
  return mask == 0 ? DEVICE_SCREEN_SUPPORTED_MASK : mask;
}

static uint8_t deviceScreenBit(uint8_t screen) {
  return (screen <= DEVICE_SCREEN_BATTERY_STATUS) ? (1 << screen) : 0;
}

static constexpr uint8_t DEVICE_SCREEN_CYCLE_ORDER[] = {
    DEVICE_SCREEN_MAP_PLUS_NAVIGATION, DEVICE_SCREEN_RIDE_STATS,
    DEVICE_SCREEN_MAP, DEVICE_SCREEN_NAVIGATION,
    DEVICE_SCREEN_BATTERY_STATUS};
static constexpr uint8_t DEVICE_SCREEN_COUNT =
    sizeof(DEVICE_SCREEN_CYCLE_ORDER) / sizeof(DEVICE_SCREEN_CYCLE_ORDER[0]);

static tileName tileForDeviceScreen(uint8_t screen) {
  switch (screen) {
  case DEVICE_SCREEN_NAVIGATION:
    return NAV;
  case DEVICE_SCREEN_RIDE_STATS:
    return RIDESTATS;
  case DEVICE_SCREEN_MAP_PLUS_NAVIGATION:
    return MAP_GUIDANCE;
  case DEVICE_SCREEN_BATTERY_STATUS:
    return BATTERY_STATUS;
  case DEVICE_SCREEN_MAP:
  default:
    return MAP;
  }
}

static uint8_t deviceScreenForTile(tileName tile) {
  switch (tile) {
  case NAV:
    return DEVICE_SCREEN_NAVIGATION;
  case RIDESTATS:
    return DEVICE_SCREEN_RIDE_STATS;
  case MAP_GUIDANCE:
    return DEVICE_SCREEN_MAP_PLUS_NAVIGATION;
  case BATTERY_STATUS:
    return DEVICE_SCREEN_BATTERY_STATUS;
  case MAP:
  default:
    return DEVICE_SCREEN_MAP;
  }
}

static bool isScreenEnabled(tileName tile) {
  return (normalizedEnabledScreensMask() &
          deviceScreenBit(deviceScreenForTile(tile))) != 0;
}

static uint8_t normalizedDefaultDeviceScreen() {
  const uint8_t mask = normalizedEnabledScreensMask();
  uint8_t defaultScreen = mapRenderSettings.defaultScreen;
  if (defaultScreen > DEVICE_SCREEN_BATTERY_STATUS) {
    defaultScreen = DEVICE_SCREEN_MAP_PLUS_NAVIGATION;
  }
  if (mask & deviceScreenBit(defaultScreen)) {
    return defaultScreen;
  }
  for (uint8_t screen : DEVICE_SCREEN_CYCLE_ORDER) {
    if (mask & deviceScreenBit(screen)) {
      return screen;
    }
  }
  return DEVICE_SCREEN_MAP_PLUS_NAVIGATION;
}

static tileName configuredDefaultTile() {
  return tileForDeviceScreen(normalizedDefaultDeviceScreen());
}

static tileName nextEnabledTile(tileName current) {
  const uint8_t currentScreen = deviceScreenForTile(current);
  uint8_t currentIndex = 0;
  for (uint8_t index = 0; index < DEVICE_SCREEN_COUNT; index++) {
    if (DEVICE_SCREEN_CYCLE_ORDER[index] == currentScreen) {
      currentIndex = index;
      break;
    }
  }
  for (uint8_t offset = 1; offset <= DEVICE_SCREEN_COUNT; offset++) {
    const uint8_t screen = DEVICE_SCREEN_CYCLE_ORDER[
        (currentIndex + offset) % DEVICE_SCREEN_COUNT];
    tileName candidate = tileForDeviceScreen(screen);
    if (isScreenEnabled(candidate)) {
      return candidate;
    }
  }
  return configuredDefaultTile();
}

static bool isGuidanceNavigating() { return routeOverlay.hasRoute(); }

static int16_t navigationArrowAngle(uint8_t iconID) {
  switch (iconID) {
  case 2: // NavigationIconID.left
    return -900;
  case 3: // NavigationIconID.right
    return 900;
  case 4: // NavigationIconID.uTurn
    return 1800;
  case 1: // NavigationIconID.straight
  default:
    return 0;
  }
}

static void setNavigationDistanceLabel(lv_obj_t *label,
                                       uint16_t distanceMeters) {
  if (distanceMeters >= 1000) {
    const uint16_t deciKilometers = (distanceMeters + 50U) / 100U;
    lv_label_set_text_fmt(label, "%u.%u km", deciKilometers / 10U,
                          deciKilometers % 10U);
  } else {
    lv_label_set_text_fmt(label, "%u m", distanceMeters);
  }
}

static void applyMapRotationForActiveTile() {
  if (activeTile == MAP_GUIDANCE) {
    const Maps::RotationMode desiredMode =
        isGuidanceNavigating() ? Maps::ROT_COURSE_UP : Maps::ROT_NORTH_UP;
    if (mapView.rotationMode != desiredMode) {
      mapView.rotationMode = desiredMode;
      if (desiredMode == Maps::ROT_NORTH_UP) {
        mapView.rotationRad = 0;
      }
      mapView.updateArrowColor();
      mapView.isPosMoved = true;
      log_i("Map guidance: rotation switched to %s",
            desiredMode == Maps::ROT_COURSE_UP ? "Course Up" : "North Up");
    }
    return;
  }

  if (activeTile != MAP) {
    return;
  }

  if (mapRenderSettings.mapRotationMode == 1 &&
      mapView.rotationMode != Maps::ROT_COURSE_UP) {
    mapView.rotationMode = Maps::ROT_COURSE_UP;
    mapView.updateArrowColor();
    mapView.isPosMoved = true;
    log_i("Creating Map: Syncing rotation to Course Up (from settings)");
  } else if (mapRenderSettings.mapRotationMode == 0 &&
             mapView.rotationMode != Maps::ROT_NORTH_UP) {
    mapView.rotationMode = Maps::ROT_NORTH_UP;
    mapView.rotationRad = 0;
    mapView.updateArrowColor();
    mapView.isPosMoved = true;
    log_i("Creating Map: Syncing rotation to North Up (from settings)");
  }
}

static uint16_t mapGuidanceOverlayHeight(bool expanded) {
  return expanded ? (TFT_HEIGHT * 2) / 3 : TFT_HEIGHT / 3;
}

static bool mapGuidanceTapIsOutsideOverlay(lv_event_t *event) {
  if (mapGuidanceOverlay == nullptr || event == nullptr) {
    return false;
  }

  lv_indev_t *indev = lv_event_get_indev(event);
  if (indev == nullptr) {
    return false;
  }

  lv_point_t point;
  lv_area_t overlayArea;
  lv_indev_get_point(indev, &point);
  lv_obj_get_coords(mapGuidanceOverlay, &overlayArea);
  return point.x < overlayArea.x1 || point.x > overlayArea.x2 ||
         point.y < overlayArea.y1 || point.y > overlayArea.y2;
}

static void applyMapGuidanceOverlayLayout() {
  if (!mapGuidanceOverlay || !mapGuidanceDestinationPicker ||
      !mapGuidanceCycleStrip) {
    return;
  }

  const bool expanded =
      mapGuidancePickerExpanded && !hasCurrentNavigationData();
  const uint16_t overlayHeight = mapGuidanceOverlayHeight(expanded);
  lv_obj_set_size(mapGuidanceOverlay, TFT_WIDTH, overlayHeight);
  lv_obj_set_pos(mapGuidanceOverlay, 0, TFT_HEIGHT - overlayHeight);

  if (expanded) {
    lv_obj_set_size(mapGuidanceDestinationPicker, TFT_WIDTH - 16,
                    overlayHeight - 16);
    lv_obj_align(mapGuidanceDestinationPicker, LV_ALIGN_CENTER, 0, 0);
    lv_obj_add_flag(mapGuidanceCycleStrip, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_set_size(mapGuidanceDestinationPicker, TFT_WIDTH - 52,
                    overlayHeight - 16);
    lv_obj_align(mapGuidanceDestinationPicker, LV_ALIGN_LEFT_MID, 0, 0);
    lv_obj_set_size(mapGuidanceCycleStrip, 28, overlayHeight - 16);
    lv_obj_align(mapGuidanceCycleStrip, LV_ALIGN_RIGHT_MID, 0, 0);
    lv_obj_clear_flag(mapGuidanceCycleStrip, LV_OBJ_FLAG_HIDDEN);
  }
}

static void updateMapGuidanceOverlay() {
  if (!mapGuidanceArrow || !mapGuidanceDistance ||
      !mapGuidanceDestinationPicker) {
    return;
  }

  LV_IMG_DECLARE(navup);
  lv_img_set_src(mapGuidanceArrow, &navup);

  const bool hasNavigationData = hasCurrentNavigationData();
  if (hasNavigationData != mapGuidanceHadNavigationData) {
    mapGuidanceHadNavigationData = hasNavigationData;
    mapGuidancePickerExpanded = !hasNavigationData;
  }
  applyMapGuidanceOverlayLayout();

  if (!hasNavigationData) {
    lv_img_set_angle(mapGuidanceArrow, 0);
    lv_label_set_text_static(mapGuidanceDistance, "--");

    if (!mapGuidancePickerExpanded) {
      lv_obj_add_flag(mapGuidanceDestinationPicker, LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(mapGuidanceArrow, LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(mapGuidanceDistance, LV_OBJ_FLAG_HIDDEN);
      return;
    }

    lv_obj_add_flag(mapGuidanceArrow, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(mapGuidanceDistance, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(mapGuidanceDestinationPicker, LV_OBJ_FLAG_HIDDEN);

    const DestinationCatalogSnapshot catalog =
        getDestinationCatalogSnapshot();
    const DestinationPickerStatusSnapshot status =
        getDestinationPickerStatusSnapshot();
    uint8_t visibleFavoriteCount = 0;
    for (uint8_t i = 0; i < catalog.count; i++) {
      if (catalog.items[i].kind == DestinationKind::Favorite) {
        visibleFavoriteCount++;
      }
    }
    if (catalog.revision != mapGuidanceCatalogRevision ||
        status.revision != mapGuidanceStatusRevision) {
      mapGuidanceCatalogRevision = catalog.revision;
      mapGuidanceStatusRevision = status.revision;
      lv_obj_clean(mapGuidanceDestinationPicker);

      if (status.code != DestinationPickerStatusCode::Idle) {
        lv_obj_t *statusContent =
            lv_obj_create(mapGuidanceDestinationPicker);
        lv_obj_remove_style_all(statusContent);
        lv_obj_set_size(statusContent, LV_PCT(100), LV_PCT(100));
        lv_obj_clear_flag(statusContent, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_set_flex_flow(statusContent, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(statusContent, LV_FLEX_ALIGN_CENTER,
                              LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        lv_obj_set_style_pad_row(statusContent, 12, 0);

        if (status.code == DestinationPickerStatusCode::Calculating) {
          lv_obj_t *spinner = lv_spinner_create(statusContent);
          lv_obj_set_size(spinner, 54, 54);
          lv_spinner_set_anim_params(spinner, 900, 220);
          lv_obj_set_style_arc_width(spinner, 5, LV_PART_MAIN);
          lv_obj_set_style_arc_color(spinner, lv_color_hex(0x3A3A3A),
                                     LV_PART_MAIN);
          lv_obj_set_style_arc_width(spinner, 5, LV_PART_INDICATOR);
          lv_obj_set_style_arc_color(spinner, lv_color_white(),
                                     LV_PART_INDICATOR);
        }

        lv_obj_t *label = lv_label_create(statusContent);
        lv_obj_set_width(label, LV_PCT(100));
        lv_obj_set_style_text_font(label, &lv_font_montserrat_18, 0);
        lv_obj_set_style_text_color(label, lv_color_white(), 0);
        lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
        lv_label_set_text(label, status.message[0] == '\0'
                                     ? "Starting navigation..."
                                     : status.message);
      } else if (visibleFavoriteCount == 0) {
        lv_obj_t *label = lv_label_create(mapGuidanceDestinationPicker);
        lv_obj_set_width(label, LV_PCT(100));
        lv_obj_set_style_text_font(label, &lv_font_montserrat_18, 0);
        lv_obj_set_style_text_color(label, lv_color_white(), 0);
        lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
        lv_label_set_text_static(label, "Add saved destinations in the app");
      } else {
        for (uint8_t i = 0; i < catalog.count; i++) {
          const DeviceDestination &destination = catalog.items[i];
          if (destination.kind != DestinationKind::Favorite) {
            continue;
          }

          lv_obj_t *row = lv_btn_create(mapGuidanceDestinationPicker);
          lv_obj_remove_style_all(row);
          lv_obj_set_size(row, LV_PCT(100), 64);
          lv_obj_clear_flag(row, LV_OBJ_FLAG_SCROLLABLE);
          lv_obj_clear_flag(row, LV_OBJ_FLAG_EVENT_BUBBLE);
          lv_obj_add_flag(row, LV_OBJ_FLAG_CLICKABLE);
          lv_obj_add_flag(row, LV_OBJ_FLAG_PRESS_LOCK);
          lv_obj_set_style_pad_hor(row, 8, 0);
          lv_obj_set_style_pad_ver(row, 0, 0);
          lv_obj_add_event_cb(
              row,
              [](lv_event_t *event) {
                if (lv_event_get_code(event) != LV_EVENT_RELEASED) {
                  return;
                }
                lv_event_stop_bubbling(event);
                const auto *context = static_cast<const DestinationRowContext *>(
                    lv_event_get_user_data(event));
                if (context != nullptr) {
                  const bool accepted = requestDestinationRoute(
                      context->generation, context->token);
                  log_i("UI: destination tapped generation=%lu token=%u "
                        "accepted=%d",
                        (unsigned long)context->generation, context->token,
                        accepted ? 1 : 0);
                  (void)lv_async_call(refreshMapGuidanceOverlayAsync, nullptr);
                }
              },
              LV_EVENT_RELEASED, &mapGuidanceRowContexts[i]);
          mapGuidanceRowContexts[i].generation = catalog.generation;
          mapGuidanceRowContexts[i].token = destination.token;

          lv_obj_t *star = lv_line_create(row);
          lv_obj_remove_style_all(star);
          lv_line_set_points(
              star, MAP_GUIDANCE_STAR_POINTS,
              sizeof(MAP_GUIDANCE_STAR_POINTS) /
                  sizeof(MAP_GUIDANCE_STAR_POINTS[0]));
          lv_obj_set_style_line_width(star, 2, 0);
          lv_obj_set_style_line_color(star, lv_color_hex(0xFFD60A), 0);
          lv_obj_set_style_line_rounded(star, true, 0);
          lv_obj_align(star, LV_ALIGN_LEFT_MID, 5, 0);

          lv_obj_t *label = lv_label_create(row);
          lv_obj_set_width(label, LV_PCT(100));
          lv_obj_set_style_pad_left(label, 36, 0);
          lv_obj_set_style_pad_right(label, 4, 0);
          lv_obj_set_style_text_font(label, &lv_font_montserrat_24, 0);
          lv_obj_set_style_text_color(label, lv_color_white(), 0);
          lv_label_set_long_mode(label, LV_LABEL_LONG_CLIP);
          lv_label_set_text(label, destination.label);
          lv_obj_align(label, LV_ALIGN_LEFT_MID, 0, 0);
        }
      }
    }
    return;
  }

  lv_obj_add_flag(mapGuidanceDestinationPicker, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(mapGuidanceArrow, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(mapGuidanceDistance, LV_OBJ_FLAG_HIDDEN);

  NavigationData navData = getCurrentNavigationData();
  lv_img_set_angle(mapGuidanceArrow, navigationArrowAngle(navData.iconID));
  setNavigationDistanceLabel(mapGuidanceDistance, navData.distance);
}

static void refreshMapGuidanceOverlayAsync(void *userData) {
  (void)userData;
  if (!isMainScreen || mainScreen == nullptr || activeTile != MAP_GUIDANCE) {
    return;
  }
  updateMapGuidanceOverlay();
  lv_obj_invalidate(mainScreen);
}

static bool dismissMapGuidanceDestinationPicker() {
  if (activeTile != MAP_GUIDANCE || !mapGuidancePickerExpanded ||
      hasCurrentNavigationData()) {
    return false;
  }

  mapGuidancePickerExpanded = false;
  updateMapGuidanceOverlay();
  lv_obj_invalidate(mainScreen);
  log_i("UI: dismissed destination picker");
  return true;
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
  // The Map + Navigation renderer can take long enough to mask a complete
  // button press or touch. Let the input timer run before starting more map
  // work whenever either physical input is already active.
  if (shouldInterruptMapRenderForScreenCycle()) {
    return;
  }

  // Handle BLE-triggered map updates OUTSIDE of isScrolled check
  // This ensures continuous updates even when user hasn't dragged
  if (isMainScreen && isMapBackedTile(activeTile) &&
      (mapView.isPosMoved || mapView.redrawMap)) {

    applyMapRotationForActiveTile();

    log_i("BLE map update: isPosMoved=%d redrawMap=%d followGps=%d",
          mapView.isPosMoved, mapView.redrawMap, mapView.followGps);

    // Re-center on GPS if in follow mode
    if (mapView.followGps || activeTile == MAP_GUIDANCE) {
      mapView.followGps = true;
      mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
    }

    // Trigger map regeneration and display
    lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
    if (shouldInterruptMapRenderForScreenCycle()) {
      return;
    }
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

    case MAP:
    case MAP_GUIDANCE: {
      if (shouldInterruptMapRenderForScreenCycle()) {
        return;
      }

      // SIMULATE GPS MOVEMENT - TEST MODE
      // Removed legacy simulation code - controlled via BLE now

#ifdef ENABLE_COMPASS
      heading = compass.getHeading();
#endif
      applyMapRotationForActiveTile();
      if (activeTile == MAP_GUIDANCE) {
        mapView.followGps = true;
        updateMapGuidanceOverlay();
      }

      // Track last heading for Course-Up auto-rotation
      static uint16_t lastHeading = 0;
      uint16_t currentHeading = currentCourseUpHeading();

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
        if (mapView.followGps || activeTile == MAP_GUIDANCE) {
          mapView.followGps = true;
          mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
        }
        mapView.redrawMap = true;
      }

      // Also handle hardware GPS location changes (when in follow mode)
      if (gps.hasLocationChange() &&
          (mapView.followGps || activeTile == MAP_GUIDANCE)) {
        mapView.followGps = true;
        mapView.centerOnGps(gps.gpsData.latitude, gps.gpsData.longitude);
        mapView.redrawMap = true;
      }

      lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
      break;
    }

    case NAV:
      lv_obj_send_event(navTile, LV_EVENT_VALUE_CHANGED, NULL);
      break;

    case RIDESTATS:
      lv_obj_send_event(rideStatsTile, LV_EVENT_VALUE_CHANGED, NULL);
      break;

    case BATTERY_STATUS:
      lv_obj_send_event(batteryStatusTile, LV_EVENT_VALUE_CHANGED, NULL);
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
    bool renderCompleted = true;
    if (mapSet.vectorMap) {
      renderCompleted = mapView.generateVectorMap(zoom);
    } else {
      mapView.generateRenderMap(zoom);
    }
    if (!renderCompleted) {
      // Keep both flags set so the map is regenerated cleanly if the user
      // remains on this screen. Do not display the partially rendered canvas.
      mapView.redrawMap = true;
      return;
    }
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
  if (!canScrollMap) {
    if (activeTile == MAP_GUIDANCE &&
        lv_event_get_code(event) == LV_EVENT_CLICKED) {
      if (mapGuidancePickerExpanded && !hasCurrentNavigationData()) {
        // Only the exposed map above the two-thirds overlay dismisses it. This
        // coordinate guard prevents a misdirected row touch from collapsing
        // the picker instead of selecting its destination.
        if (mapGuidanceTapIsOutsideOverlay(event)) {
          (void)dismissMapGuidanceDestinationPicker();
        }
        return;
      }
      if (mapRenderSettings.tapToSwitchScreens) {
        log_i("MAP GUIDANCE TAP: cycling main screen");
        showNextMainScreen();
      }
    }
    return;
  }

  if (canScrollMap) {
    lv_event_code_t code = lv_event_get_code(event);
    lv_indev_t *indev = lv_event_get_indev(event);
    static int last_x = 0, last_y = 0;
    static bool isDragging = false;
    static bool dragStarted = false;
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
      dragStarted = false;
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
      const int DRAG_START_THRESHOLD = 32;
      int totalMoveX = abs(p.x - pressStartX);
      int totalMoveY = abs(p.y - pressStartY);
      int totalMove = totalMoveX + totalMoveY;

      // Check for long press (1 second hold without significant movement)
      if (!longPressTriggered && pressStartTime > 0) {
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

      if (!dragStarted) {
        if (totalMove < DRAG_START_THRESHOLD) {
          break;
        }

        dragStarted = true;
        last_x = p.x;
        last_y = p.y;
        pressStartTime = 0;
        log_i("DRAG START: p(%d,%d) start(%d,%d) total=%d", p.x, p.y,
              pressStartX, pressStartY, totalMove);
        break;
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

      if (isDragging && dragStarted) {
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
          if (mapRenderSettings.tapToSwitchScreens) {
            log_i("MAP SHORT TAP: cycling main screen");
            showNextMainScreen();
          } else {
            // GPS indicator is centered in the rendered map viewport when
            // followGps is true. When followGps is false, use that center area
            // since users expect to tap the center indicator.
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
      }

      isDragging = false;
      dragStarted = false;
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
  if (!nameNav || !distNav || !arrowNav) {
    return;
  }

  LV_IMG_DECLARE(navup);
  lv_img_set_src(arrowNav, &navup);

  if (!hasCurrentNavigationData()) {
    lv_label_set_text_static(nameNav, "Waiting for instruction");
    lv_label_set_text_static(distNav, "--");
    lv_img_set_angle(arrowNav, 0);
    return;
  }

  NavigationData navData = getCurrentNavigationData();
  char formattedInstruction[160];
  formatNavigationInstruction(navData.instruction, formattedInstruction,
                              sizeof(formattedInstruction));
  lv_label_set_text(nameNav, formattedInstruction);
  setNavigationDistanceLabel(distNav, navData.distance);

  lv_img_set_angle(arrowNav, navigationArrowAngle(navData.iconID));
}

static void createMapGuidanceOverlay() {
  const uint16_t overlayHeight = mapGuidanceOverlayHeight(false);

  mapGuidanceOverlay = lv_obj_create(mainScreen);
  lv_obj_remove_style_all(mapGuidanceOverlay);
  lv_obj_set_size(mapGuidanceOverlay, TFT_WIDTH, overlayHeight);
  lv_obj_set_pos(mapGuidanceOverlay, 0, TFT_HEIGHT - overlayHeight);
  lv_obj_clear_flag(mapGuidanceOverlay, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(mapGuidanceOverlay, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_set_style_bg_color(mapGuidanceOverlay, lv_color_black(), 0);
  lv_obj_set_style_bg_opa(mapGuidanceOverlay, 230, 0);
  lv_obj_set_style_pad_all(mapGuidanceOverlay, 8, 0);
  lv_obj_add_event_cb(mapGuidanceOverlay, mapGuidanceOverlayTapEvent,
                      LV_EVENT_CLICKED, NULL);

  mapGuidanceDestinationPicker = lv_obj_create(mapGuidanceOverlay);
  lv_obj_remove_style_all(mapGuidanceDestinationPicker);
  lv_obj_set_size(mapGuidanceDestinationPicker, TFT_WIDTH - 52,
                  overlayHeight - 16);
  lv_obj_align(mapGuidanceDestinationPicker, LV_ALIGN_LEFT_MID, 0, 0);
  lv_obj_set_flex_flow(mapGuidanceDestinationPicker, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(mapGuidanceDestinationPicker, LV_FLEX_ALIGN_START,
                        LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);
  lv_obj_set_style_pad_all(mapGuidanceDestinationPicker, 4, 0);
  lv_obj_set_style_pad_row(mapGuidanceDestinationPicker, 4, 0);
  // A favorites-only catalog always fits in the expanded overlay. Keeping this
  // container scrollable can turn small touch jitter into a scroll gesture and
  // suppress the destination row's selection event.
  lv_obj_clear_flag(mapGuidanceDestinationPicker, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scrollbar_mode(mapGuidanceDestinationPicker,
                            LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(mapGuidanceDestinationPicker, LV_OBJ_FLAG_EVENT_BUBBLE);

  mapGuidanceCycleStrip = lv_btn_create(mapGuidanceOverlay);
  lv_obj_set_size(mapGuidanceCycleStrip, 28, overlayHeight - 16);
  lv_obj_align(mapGuidanceCycleStrip, LV_ALIGN_RIGHT_MID, 0, 0);
  lv_obj_set_style_radius(mapGuidanceCycleStrip, 8, 0);
  lv_obj_set_style_bg_color(mapGuidanceCycleStrip, lv_color_hex(0x181818), 0);
  lv_obj_set_style_bg_opa(mapGuidanceCycleStrip, LV_OPA_COVER, 0);
  lv_obj_clear_flag(mapGuidanceCycleStrip, LV_OBJ_FLAG_EVENT_BUBBLE);
  lv_obj_add_event_cb(mapGuidanceCycleStrip, tapCycleScreenEvent,
                      LV_EVENT_CLICKED, NULL);
  lv_obj_t *cycleLabel = lv_label_create(mapGuidanceCycleStrip);
  lv_obj_set_style_text_color(cycleLabel, lv_color_white(), 0);
  lv_obj_set_style_text_font(cycleLabel, &lv_font_montserrat_18, 0);
  lv_label_set_text_static(cycleLabel, LV_SYMBOL_RIGHT);
  lv_obj_center(cycleLabel);

  mapGuidanceArrow = lv_img_create(mapGuidanceOverlay);
  LV_IMG_DECLARE(navup);
  lv_img_set_src(mapGuidanceArrow, &navup);
  lv_img_set_zoom(mapGuidanceArrow,
                  TFT_HEIGHT > 320 ? iconScale * 2 : iconScale);
  lv_img_set_pivot(mapGuidanceArrow, 50, 50);
  lv_obj_align(mapGuidanceArrow, LV_ALIGN_LEFT_MID, 76, 0);

  mapGuidanceDistance = lv_label_create(mapGuidanceOverlay);
  lv_obj_set_width(mapGuidanceDistance, 205);
  lv_obj_set_style_text_font(mapGuidanceDistance, &lv_font_montserrat_48, 0);
  lv_obj_set_style_text_color(mapGuidanceDistance, lv_color_white(), 0);
  lv_obj_set_style_text_align(mapGuidanceDistance, LV_TEXT_ALIGN_LEFT, 0);
  lv_label_set_long_mode(mapGuidanceDistance, LV_LABEL_LONG_CLIP);
  lv_label_set_text_static(mapGuidanceDistance, "--");
  lv_obj_align(mapGuidanceDistance, LV_ALIGN_LEFT_MID, 212, 0);

  mapGuidanceCatalogRevision = UINT32_MAX;
  mapGuidanceStatusRevision = UINT32_MAX;
  mapGuidanceHadNavigationData = hasCurrentNavigationData();
  mapGuidancePickerExpanded = !mapGuidanceHadNavigationData;
  updateMapGuidanceOverlay();

  lv_obj_add_flag(mapGuidanceOverlay, LV_OBJ_FLAG_HIDDEN);
}

static void showMainTile(tileName tile) {
  if (!mapTile || !navTile || !rideStatsTile || !batteryStatusTile ||
      !mapGuidanceOverlay) {
    return;
  }

  lv_obj_add_flag(mapTile, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(navTile, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(rideStatsTile, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(batteryStatusTile, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(mapGuidanceOverlay, LV_OBJ_FLAG_HIDDEN);

  activeTile = tile;
  canScrollMap = tile == MAP;
  if (isMapBackedTile(activeTile)) {
    zoom = currentMapStyleSettings().zoomLevel;
    mapView.isPosMoved = true;
  }

  switch (tile) {
  case MAP_GUIDANCE:
    lv_obj_clear_flag(mapTile, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(mapGuidanceOverlay, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(mapGuidanceOverlay);
    mapView.followGps = true;
    applyMapRotationForActiveTile();
    mapGuidanceHadNavigationData = hasCurrentNavigationData();
    mapGuidancePickerExpanded = !mapGuidanceHadNavigationData;
    updateMapGuidanceOverlay();
    mapView.redrawMap = true;
    lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
    log_i("UI: switched to map guidance screen");
    break;
  case NAV:
    lv_obj_clear_flag(navTile, LV_OBJ_FLAG_HIDDEN);
    lv_obj_send_event(navTile, LV_EVENT_VALUE_CHANGED, NULL);
    log_i("UI: switched to navigation instruction screen");
    break;
  case RIDESTATS:
    lv_obj_clear_flag(rideStatsTile, LV_OBJ_FLAG_HIDDEN);
    lv_obj_send_event(rideStatsTile, LV_EVENT_VALUE_CHANGED, NULL);
    log_i("UI: switched to ride telemetry screen");
    break;
  case BATTERY_STATUS:
    lv_obj_clear_flag(batteryStatusTile, LV_OBJ_FLAG_HIDDEN);
    lv_obj_send_event(batteryStatusTile, LV_EVENT_VALUE_CHANGED, NULL);
    log_i("UI: switched to battery status screen");
    break;
  case MAP:
  default:
    lv_obj_clear_flag(mapTile, LV_OBJ_FLAG_HIDDEN);
    mapView.redrawMap = true;
    lv_obj_send_event(mapTile, LV_EVENT_VALUE_CHANGED, NULL);
    log_i("UI: switched to map screen");
    break;
  }
}

void showNextMainScreen() {
  showMainTile(nextEnabledTile((tileName)activeTile));
}

void showConfiguredDefaultMainScreen() { showMainTile(configuredDefaultTile()); }

void applyDeviceScreenSettings() {
  if (!isMainScreen || !mainScreen || !mapTile || !navTile || !rideStatsTile ||
      !batteryStatusTile || !mapGuidanceOverlay) {
    return;
  }

  if (!isScreenEnabled((tileName)activeTile)) {
    showMainTile(configuredDefaultTile());
  }
}

static void tapCycleScreenEvent(lv_event_t *event) {
  if (!mapRenderSettings.tapToSwitchScreens) {
    return;
  }

  if (lv_event_get_code(event) != LV_EVENT_CLICKED) {
    return;
  }

  log_i("UI: short tap cycling main screen");
  showNextMainScreen();
}

static void mapGuidanceOverlayTapEvent(lv_event_t *event) {
  if (mapGuidancePickerExpanded && !hasCurrentNavigationData()) {
    return;
  }
  tapCycleScreenEvent(event);
}

void toggleNavigationScreen() {
  if (!isMainScreen || !mainScreen || !mapTile || !navTile || !rideStatsTile ||
      !batteryStatusTile || !mapGuidanceOverlay) {
    return;
  }

  if (dismissMapGuidanceDestinationPicker()) {
    return;
  }
  showNextMainScreen();
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
  lv_obj_add_flag(mapTile, LV_OBJ_FLAG_CLICKABLE);
  activeTile = MAP; // Ensure map logic runs in updateMainScreen

  navTile = lv_obj_create(mainScreen);
  lv_obj_remove_style_all(navTile);
  lv_obj_set_size(navTile, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_pos(navTile, 0, 0);
  lv_obj_clear_flag(navTile, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(navTile, LV_OBJ_FLAG_CLICKABLE);
  navigationScr(navTile);
  lv_obj_add_event_cb(navTile, updateNavEvent, LV_EVENT_VALUE_CHANGED, NULL);
  lv_obj_add_event_cb(navTile, tapCycleScreenEvent, LV_EVENT_CLICKED, NULL);
  lv_obj_add_flag(navTile, LV_OBJ_FLAG_HIDDEN);

  rideStatsTile = lv_obj_create(mainScreen);
  lv_obj_remove_style_all(rideStatsTile);
  lv_obj_set_size(rideStatsTile, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_pos(rideStatsTile, 0, 0);
  lv_obj_clear_flag(rideStatsTile, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(rideStatsTile, LV_OBJ_FLAG_CLICKABLE);
  rideTelemetryScr(rideStatsTile);
  lv_obj_add_event_cb(rideStatsTile, updateRideTelemetryEvent,
                      LV_EVENT_VALUE_CHANGED, NULL);
  lv_obj_add_event_cb(rideStatsTile, tapCycleScreenEvent, LV_EVENT_CLICKED,
                      NULL);
  lv_obj_add_flag(rideStatsTile, LV_OBJ_FLAG_HIDDEN);

  batteryStatusTile = lv_obj_create(mainScreen);
  lv_obj_remove_style_all(batteryStatusTile);
  lv_obj_set_size(batteryStatusTile, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_pos(batteryStatusTile, 0, 0);
  lv_obj_clear_flag(batteryStatusTile, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(batteryStatusTile, LV_OBJ_FLAG_CLICKABLE);
  batteryStatusScr(batteryStatusTile);
  lv_obj_add_event_cb(batteryStatusTile, updateBatteryStatusEvent,
                      LV_EVENT_VALUE_CHANGED, NULL);
  lv_obj_add_event_cb(batteryStatusTile, tapCycleScreenEvent,
                      LV_EVENT_CLICKED, NULL);
  lv_obj_add_flag(batteryStatusTile, LV_OBJ_FLAG_HIDDEN);

  createMapGuidanceOverlay();

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
  if (mapRenderSettings.mapStyle.zoomLevel <= 5) {
    zoom = mapRenderSettings.mapStyle.zoomLevel;
  }
}
