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
 * Settings IDs: 1=minPolygonSize, 2=detailLevel, 3=routeLineWidth,
 * 4=displayRotation, 6=mapRotationMode, 7=zoomLevel, 8=visibilityMask
 */
struct MapRenderSettings {
  uint8_t minPolygonSize = 0; // 0-50: Skip polygons smaller than N pixels²
  uint8_t detailLevel = 2;    // 0=Low, 1=Med, 2=High
  uint8_t routeLineWidth = 4; // 2-8: Route overlay line width in pixels
  uint8_t displayRotation =
      0; // 0-3: Display rotation (0=0°, 1=90°, 2=180°, 3=270°)
  uint8_t mapRotationMode = 0; // 0=North Up, 1=Course Up
  uint8_t zoomLevel = 2;       // 0-5: Zoom level (0=super, 2=default)
  uint32_t visibilityMask =
      0xFFFFFFFF; // Bitmask: bit0=buildings, bit1=nature, bit2=paths
};

extern MapRenderSettings mapRenderSettings;

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
