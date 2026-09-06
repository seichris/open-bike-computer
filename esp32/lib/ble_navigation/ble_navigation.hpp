#pragma once

/**
 * @file ble_navigation.hpp
 * @brief BLE navigation server for iOS app communication
 *
 * Implements NimBLE server with the BikeComputer navigation/map contract:
 * - 2A6E: Navigation instructions (text format)
 * - 2A6F: Route geometry (binary compressed format)
 * - 2A72: GPS position
 * - 2A73: Map settings
 * - 9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002: local auth handshake
 * - 9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1003: workout telemetry
 */

#include <Arduino.h>
#include "ble_radio_policy.hpp"
#include "destination_picker_protocol.hpp"
#include "map_profile_protocol.hpp"
#include "renderer_diagnostics_ble_protocol.hpp"
#include "ride_ble_protocol.generated.hpp"

// Forward declarations - actual NimBLE includes only in .cpp
class NimBLEServer;
class NimBLECharacteristic;

/**
 * @brief BLE Navigation Server
 */
// Navigation data structure
struct NavigationData {
  uint8_t iconID;
  uint16_t distance;
  char instruction[64];
};

enum class WorkoutStartRequestPresentation : uint8_t {
  Unavailable = 0,
  StartOnIPhone = 1,
  StartOnAppleWatch = 2,
};

/**
 * @brief Map rendering settings (configurable via BLE from iOS app)
 * IDs 1,2,3,7,8,9,10 configure the Map screen. IDs 16-22 configure
 * Map + Navigation. IDs 6,11-15 configure shared/device behavior, and IDs
 * 23-24 carry the connected phone's transient battery percentage and charging
 * state. IDs 25-26 control the Map + Navigation bird's-eye projection and
 * perspective. IDs 27-34 configure street labels for Map and Map + Navigation,
 * and ID 35 controls OSM 3D buildings in bird's-eye navigation. ID 36
 * controls automatic connected-display inactivity.
 * Legacy ID 4 is ignored because display rotation is selected by the hardware
 * target.
 */
enum DeviceScreenSetting : uint8_t {
  DEVICE_SCREEN_MAP = 0,
  DEVICE_SCREEN_NAVIGATION = 1,
  DEVICE_SCREEN_RIDE_STATS = 2,
  DEVICE_SCREEN_MAP_PLUS_NAVIGATION = 3,
  DEVICE_SCREEN_BATTERY_STATUS = 4,
};

static constexpr uint8_t DEVICE_SCREEN_SUPPORTED_MASK =
    (1 << DEVICE_SCREEN_MAP) | (1 << DEVICE_SCREEN_NAVIGATION) |
    (1 << DEVICE_SCREEN_RIDE_STATS) | (1 << DEVICE_SCREEN_MAP_PLUS_NAVIGATION) |
    (1 << DEVICE_SCREEN_BATTERY_STATUS);

static constexpr uint32_t MAP_VISIBILITY_BUILDINGS =
    map_profile_protocol::VISIBILITY_BUILDINGS;
static constexpr uint32_t MAP_VISIBILITY_GREEN_SPACE =
    map_profile_protocol::VISIBILITY_GREEN_SPACE;
static constexpr uint32_t MAP_VISIBILITY_PATHS =
    map_profile_protocol::VISIBILITY_PATHS;
static constexpr uint32_t MAP_VISIBILITY_MAJOR_ROADS =
    map_profile_protocol::VISIBILITY_MAJOR_ROADS;
static constexpr uint32_t MAP_VISIBILITY_LOCAL_STREETS =
    map_profile_protocol::VISIBILITY_LOCAL_STREETS;
static constexpr uint32_t MAP_VISIBILITY_WATER =
    map_profile_protocol::VISIBILITY_WATER;
static constexpr uint32_t MAP_VISIBILITY_RAILWAYS =
    map_profile_protocol::VISIBILITY_RAILWAYS;
static constexpr uint32_t MAP_VISIBILITY_OTHER_AREAS =
    map_profile_protocol::VISIBILITY_OTHER_AREAS;
static constexpr uint32_t MAP_VISIBILITY_ROUTE_OVERLAY =
    map_profile_protocol::VISIBILITY_ROUTE_OVERLAY;
static constexpr uint32_t MAP_VISIBILITY_POSITION_MARKER =
    map_profile_protocol::VISIBILITY_POSITION_MARKER;
static constexpr uint32_t MAP_VISIBILITY_SERVICE_ROADS =
    map_profile_protocol::VISIBILITY_SERVICE_ROADS;
static constexpr uint32_t MAP_VISIBILITY_TRACKS =
    map_profile_protocol::VISIBILITY_TRACKS;
static constexpr uint32_t MAP_VISIBILITY_EXTENDED_MARKER =
    map_profile_protocol::VISIBILITY_EXTENDED_MARKER;
static constexpr uint32_t MAP_VISIBILITY_EXTENDED_FEATURE_MASK =
    map_profile_protocol::VISIBILITY_EXTENDED_FEATURE_MASK;
static constexpr uint32_t MAP_VISIBILITY_OVERLAY_MASK =
    map_profile_protocol::VISIBILITY_OVERLAY_MASK;

static inline uint32_t normalizedMapFeatureVisibilityMask(uint32_t mask) {
  return map_profile_protocol::normalizedFeatureVisibilityMask(mask);
}

struct ScreenMapRenderSettings {
  uint8_t minPolygonSize = 0; // 0-50: Skip polygons smaller than N pixels²
  uint8_t detailLevel = map_profile_protocol::MAP_DEFAULT_DETAIL_LEVEL;
  uint8_t routeLineWidth = map_profile_protocol::MAP_DEFAULT_ROUTE_LINE_WIDTH;
  uint8_t streetLineWidth = map_profile_protocol::DEFAULT_STREET_WIDTH;
  uint8_t positionMarkerScale = 2;  // 1-5: Current-position marker scale
  uint8_t zoomLevel = map_profile_protocol::MAP_DEFAULT_ZOOM_LEVEL;
  uint32_t visibilityMask = MAP_VISIBILITY_EXTENDED_FEATURE_MASK;
  uint8_t labelDensity = map_profile_protocol::DEFAULT_LABEL_DENSITY;
  uint8_t labelLanguageMode =
      map_profile_protocol::DEFAULT_LABEL_LANGUAGE_MODE;
  uint8_t labelTextSize = map_profile_protocol::DEFAULT_LABEL_TEXT_SIZE;
  uint8_t labelOrientation =
      map_profile_protocol::DEFAULT_LABEL_ORIENTATION;
};

struct MapRenderSettings {
  ScreenMapRenderSettings mapStyle;
  ScreenMapRenderSettings mapNavigationStyle = [] {
    ScreenMapRenderSettings settings;
    settings.detailLevel =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_DETAIL_LEVEL;
    settings.routeLineWidth =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_ROUTE_LINE_WIDTH;
    settings.streetLineWidth = map_profile_protocol::DEFAULT_STREET_WIDTH;
    settings.positionMarkerScale = 2;
    settings.zoomLevel = map_profile_protocol::MAP_NAVIGATION_DEFAULT_ZOOM_LEVEL;
    settings.visibilityMask =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_VISIBILITY_MASK;
    settings.labelDensity =
        map_profile_protocol::MAP_NAVIGATION_DEFAULT_LABEL_DENSITY;
    return settings;
  }();
  bool mapNavigationBirdsEyeEnabled = true;
  uint8_t mapNavigationBirdsEyePerspective =
      map_profile_protocol::MAP_NAVIGATION_DEFAULT_BIRDS_EYE_PERSPECTIVE;
  bool mapNavigation3DBuildingsEnabled = true;
  uint8_t mapRotationMode = 0; // 0=North Up, 1=Course Up
  uint8_t mapNavigationRotationMode = 1;
  uint8_t tapToSwitchScreens = 0; // 0=off, 1=short tap cycles main screens
  uint8_t enabledScreensMask =
      DEVICE_SCREEN_SUPPORTED_MASK; // Bits follow DeviceScreenSetting
  uint8_t defaultScreen =
      DEVICE_SCREEN_MAP_PLUS_NAVIGATION; // DeviceScreenSetting value
  uint32_t disconnectedSleepTimeoutSeconds =
      120; // 0=never auto-sleep while disconnected
  uint32_t navigationOverlayVisibilityMask =
      MAP_VISIBILITY_OVERLAY_MASK;
};

extern MapRenderSettings mapRenderSettings;
const ScreenMapRenderSettings &currentMapStyleSettings();

NavigationData getCurrentNavigationData();
bool hasCurrentNavigationData();
int16_t getPhoneBatteryLevelPercent();
bool isPhoneBatteryCharging();

enum class DestinationKind : uint8_t {
  Favorite = 1,
  Recent = 2,
};

struct DeviceDestination {
  uint16_t token = 0;
  DestinationKind kind = DestinationKind::Recent;
  char label[destination_picker_protocol::MAX_LABEL_BYTES + 1] = "";
};

struct DestinationCatalogSnapshot {
  uint32_t generation = 0;
  uint32_t revision = 0;
  uint8_t count = 0;
  DeviceDestination items[destination_picker_protocol::MAX_ITEMS]{};
};

enum class DestinationPickerStatusCode : uint8_t {
  Idle = 0,
  Calculating = 1,
  Started = 2,
  Failed = 3,
  Stale = 4,
};

struct DestinationPickerStatusSnapshot {
  uint32_t generation = 0;
  uint32_t revision = 0;
  uint16_t token = 0;
  DestinationPickerStatusCode code = DestinationPickerStatusCode::Idle;
  char message[destination_picker_protocol::MAX_LABEL_BYTES + 1] = "";
};

DestinationCatalogSnapshot getDestinationCatalogSnapshot();
DestinationPickerStatusSnapshot getDestinationPickerStatusSnapshot();
bool requestDestinationRoute(uint32_t generation, uint16_t token);

struct BLEDebugStats {
  bool initialized = false;
  bool connected = false;
  bool authenticated = false;
  uint32_t connectCount = 0;
  uint32_t disconnectCount = 0;
  uint32_t authChallengeCount = 0;
  uint32_t authSuccessCount = 0;
  uint32_t navPacketCount = 0;
  uint32_t routePacketCount = 0;
  uint32_t gpsPacketCount = 0;
  uint32_t settingsPacketCount = 0;
  uint32_t rejectedUnauthenticatedCount = 0;
  uint32_t lastConnectMs = 0;
  uint32_t lastDisconnectMs = 0;
  uint32_t lastAuthChallengeMs = 0;
  uint32_t lastAuthSuccessMs = 0;
  uint32_t lastNavPacketMs = 0;
  uint32_t lastRoutePacketMs = 0;
  uint32_t lastGpsPacketMs = 0;
  uint32_t lastGpsPacketGapMs = 0;
  uint32_t maximumGpsPacketGapMs = 0;
  uint32_t lastSettingsPacketMs = 0;
  uint32_t lastRejectedUnauthenticatedMs = 0;
  bool connectionParametersValid = false;
  uint16_t connectionIntervalUnits = 0;
  uint16_t connectionLatency = 0;
  uint16_t supervisionTimeoutUnits = 0;
  uint32_t connectionParameterSampleCount = 0;
  uint32_t lastConnectionParameterSampleMs = 0;
  int8_t txPowerDbm = ble_radio_policy::kConfiguration.txPowerDbm;
  ble_radio_policy::AdvertisingMode advertisingMode =
      ble_radio_policy::AdvertisingMode::Default;
  ble_radio_policy::ConnectionProfile requestedConnectionProfile =
      ble_radio_policy::ConnectionProfile::Unset;
};

class BLENavigationServer {
public:
  BLENavigationServer() = default;

  /**
   * @brief Initialize the BLE server
   * @param deviceName Name to advertise as
   */
  void init(const char *deviceName = "BikeComputer");

  /**
   * @brief Check if a client is connected
   */
  bool isConnected() const { return connected; }

  /**
   * @brief Process any pending BLE events (call from main loop)
   */
  void process();

  /** Record physical input that should reopen the fast-advertising window. */
  void noteUserWake();

  /** Publish current navigation activity for opt-in radio experiments. */
  void setNavigationActivity(bool active);

  /**
   * @brief Clear the registered iPhone owner after physical recovery input.
   */
  bool forgetOwner();
  void noteOwnershipDisplayFlushCompleted();
  bool ownershipPairingRenderedRequest(uint32_t &pairingGeneration);
  bool armOwnershipPairingConfirmation(uint32_t pairingGeneration);
  bool isOwnershipClaimed();
  bool hasOwnershipPairingCode();
  bool confirmOwnershipPairing();

  /** Notify the authenticated iPhone app that the device requested a workout. */
  bool requestWorkoutStart();
  bool canRequestWorkoutStart() const;
  WorkoutStartRequestPresentation workoutStartRequestPresentation() const;
  bool notifyRideAutomationFrame(const uint8_t *data, size_t length);

  BLEDebugStats getDebugStats() const;

  /** True after this connection negotiated the explicit invalid-heading wire
   * sentinel. Older clients use route-first guidance because their zero value
   * is ambiguous between north and a missing Core Location course. */
  bool supportsExplicitInvalidGpsHeading() const;

  /** Consume the latest authenticated, session-scoped renderer benchmark
   * window request on the UI task. */
  bool takeRendererBenchmarkWindowRequest(
      renderer_diagnostics_ble_protocol::WindowRequest &request);

private:
  bool initialized = false;
  bool connected = false;

  // BLE UUIDs (matching iOS app)
  static constexpr const char *SERVICE_UUID =
      ride_ble_protocol_generated::SERVICE_UUID;
  static constexpr const char *NAV_CHAR_UUID =
      ride_ble_protocol_generated::NAVIGATION_UUID; // Navigation instructions
  static constexpr const char *ROUTE_CHAR_UUID =
      ride_ble_protocol_generated::ROUTE_UUID; // Route geometry
  static constexpr const char *GPS_CHAR_UUID =
      ride_ble_protocol_generated::GPS_UUID; // GPS Position
  static constexpr const char *SETTINGS_CHAR_UUID =
      ride_ble_protocol_generated::SETTINGS_UUID; // Map Settings
  static constexpr const char *AUTH_CHAR_UUID =
      ride_ble_protocol_generated::AUTH_UUID;
  static constexpr const char *WORKOUT_TELEMETRY_CHAR_UUID =
      ride_ble_protocol_generated::WORKOUT_UUID;
  static constexpr const char *RIDE_AUTOMATION_CHAR_UUID =
      ride_ble_protocol_generated::RIDE_AUTOMATION_UUID;

  NimBLEServer *pServer = nullptr;
  NimBLECharacteristic *pNavCharacteristic = nullptr;
  NimBLECharacteristic *pRouteCharacteristic = nullptr;
  NimBLECharacteristic *pAuthCharacteristic = nullptr;
  NimBLECharacteristic *pWorkoutTelemetryCharacteristic = nullptr;
  NimBLECharacteristic *pRideAutomationCharacteristic = nullptr;

  friend class MyBLEServerCallbacks;
  friend class MyNavCharacteristicCallbacks;
  friend class MyRouteCharacteristicCallbacks;
  friend class MyWorkoutTelemetryCharacteristicCallbacks;
  friend class MyRideAutomationCharacteristicCallbacks;
  friend class MyAuthCharacteristicCallbacks;
};

// Global BLE server instance
extern BLENavigationServer bleNavServer;
