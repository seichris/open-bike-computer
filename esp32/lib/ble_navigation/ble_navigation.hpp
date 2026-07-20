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
 */

#include <Arduino.h>
#include "destination_picker_protocol.hpp"
#include "map_profile_protocol.hpp"

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

/**
 * @brief Map rendering settings (configurable via BLE from iOS app)
 * IDs 1,2,3,7,8,9,10 configure the Map screen. IDs 16-22 configure
 * Map + Navigation. IDs 6,11-15 configure shared/device behavior, and IDs
 * 23-24 carry the connected phone's transient battery percentage and charging
 * state. Legacy ID 4 is ignored because display rotation is selected by the
 * hardware target.
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
  uint8_t detailLevel = 2;    // 0=Low, 1=Med, 2=High
  uint8_t routeLineWidth = 4; // 2-48: Route overlay line width in pixels
  uint8_t streetLineWidthBoost = 0; // 0-24: Extra map street width in pixels
  uint8_t positionMarkerScale = 2;  // 1-5: Current-position marker scale
  uint8_t zoomLevel = 2;             // 0-5: Zoom level (0=super, 2=default)
  uint32_t visibilityMask = MAP_VISIBILITY_EXTENDED_FEATURE_MASK;
};

struct MapRenderSettings {
  ScreenMapRenderSettings mapStyle;
  ScreenMapRenderSettings mapNavigationStyle;
  uint8_t mapRotationMode = 0; // 0=North Up, 1=Course Up
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
  uint32_t lastSettingsPacketMs = 0;
  uint32_t lastRejectedUnauthenticatedMs = 0;
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

  BLEDebugStats getDebugStats() const;

private:
  bool initialized = false;
  bool connected = false;

  // BLE UUIDs (matching iOS app)
  static constexpr const char *SERVICE_UUID =
      "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1800";
  static constexpr const char *NAV_CHAR_UUID =
      "2A6E"; // Navigation instructions
  static constexpr const char *ROUTE_CHAR_UUID = "2A6F"; // Route geometry
  static constexpr const char *GPS_CHAR_UUID =
      "2A72"; // GPS Position (Location and Speed)
  static constexpr const char *SETTINGS_CHAR_UUID =
      "2A73"; // Map Settings (runtime configuration)
  static constexpr const char *AUTH_CHAR_UUID =
      "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1002";

  NimBLEServer *pServer = nullptr;
  NimBLECharacteristic *pNavCharacteristic = nullptr;
  NimBLECharacteristic *pRouteCharacteristic = nullptr;
  NimBLECharacteristic *pAuthCharacteristic = nullptr;

  friend class MyBLEServerCallbacks;
  friend class MyNavCharacteristicCallbacks;
  friend class MyRouteCharacteristicCallbacks;
  friend class MyAuthCharacteristicCallbacks;
};

// Global BLE server instance
extern BLENavigationServer bleNavServer;
