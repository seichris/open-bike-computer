/**
 * @file ble_navigation.cpp
 * @brief BLE navigation server implementation
 *
 * Handles incoming navigation data from iOS app and triggers map updates.
 */

#include "ble_navigation.hpp"
#include "../gps/gps.hpp"
#include "../gui/src/waitingScr.hpp"
#include "../route_overlay/route_overlay.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "../waveshare_board/display.hpp"
#include "../waveshare_board/pcf85063.hpp"
#endif
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <esp_system.h>
#include <host/ble_hs_id.h>
#include <mbedtls/md.h>

extern Gps gps;

// Global instance
BLENavigationServer bleNavServer;

// Forward declaration of map redraw trigger
extern void triggerMapRedraw();

// NavigationData struct is now in ble_navigation.hpp

// Map rendering settings moved to header for external access
// Global map render settings (accessible from maps.cpp)
MapRenderSettings mapRenderSettings;

// NVS Preferences for persistent settings
static Preferences settingsPrefs;

// Global navigation data
static NavigationData currentNavData = {0, 0, ""};
static volatile bool navDataUpdated = false;
static bool bleSessionAuthenticated = false;
static char pendingAuthNonce[33] = "";
static NimBLECharacteristic *authCharacteristic = nullptr;
static BLEDebugStats bleDebugStats;
static uint16_t activeConnHandle = BLE_HS_CONN_HANDLE_NONE;
static bool unauthTimeoutDisconnectRequested = false;

NavigationData getCurrentNavigationData() { return currentNavData; }

bool hasCurrentNavigationData() {
  return currentNavData.distance > 0 || currentNavData.instruction[0] != '\0';
}

// Route geometry debouncing - skip redundant parses
static uint32_t lastRouteHash = 0;
static size_t lastRouteLen = 0;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
static uint32_t lastBleRtcSyncMs = 0;
constexpr uint32_t BLE_RTC_SYNC_INTERVAL_MS = 10UL * 60UL * 1000UL;
#endif

struct BleIdentity {
  uint8_t address[6] = {};
  bool created = false;
};

static void formatBleAddress(const uint8_t *address, char *out,
                             size_t outSize) {
  if (address == nullptr || out == nullptr || outSize == 0) {
    return;
  }

  snprintf(out, outSize, "%02x:%02x:%02x:%02x:%02x:%02x", address[5],
           address[4], address[3], address[2], address[1], address[0]);
}

static bool loadOrCreateStableRandomIdentity(BleIdentity &identity) {
  Preferences prefs;
  if (!prefs.begin("bleIdentity", false)) {
    Serial.println("BLE: Failed to open BLE identity NVS");
    return false;
  }

  if (prefs.isKey("addr") &&
      prefs.getBytesLength("addr") == sizeof(identity.address) &&
      prefs.getBytes("addr", identity.address, sizeof(identity.address)) ==
          sizeof(identity.address)) {
    prefs.end();
    return true;
  }

  uint32_t randomA = esp_random();
  uint32_t randomB = esp_random();
  memcpy(identity.address, &randomA, sizeof(randomA));
  memcpy(identity.address + sizeof(randomA), &randomB, 2);
  identity.address[5] = (identity.address[5] & 0x3F) | 0xC0;
  identity.created = true;

  bool stored =
      prefs.putBytes("addr", identity.address, sizeof(identity.address)) ==
      sizeof(identity.address);
  prefs.end();
  if (!stored) {
    Serial.println("BLE: Failed to persist BLE random static identity");
  }
  return stored;
}

static void initBleIdentityAndSecurity(const char *deviceName) {
  char advertisedAddress[18] = "";
#ifdef BLE_DEV_RANDOM_IDENTITY
  NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM, true);
  NimBLEDevice::init(deviceName);
  ble_addr_t randomAddress;
  if (ble_hs_id_gen_rnd(1, &randomAddress) == 0 &&
      ble_hs_id_set_rnd(randomAddress.val) == 0) {
    formatBleAddress(randomAddress.val, advertisedAddress,
                     sizeof(advertisedAddress));
    Serial.println(
        "BLE: BLE_DEV_RANDOM_IDENTITY enabled; using fresh random identity");
  } else {
    Serial.println("BLE: Failed to configure random identity; using stable "
                   "controller identity");
    NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_PUBLIC, false);
  }
#else
  BleIdentity identity;
  bool hasStableIdentity = loadOrCreateStableRandomIdentity(identity);
  if (hasStableIdentity) {
    NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM, false);
  }
  NimBLEDevice::init(deviceName);
  if (hasStableIdentity && ble_hs_id_set_rnd(identity.address) == 0) {
    formatBleAddress(identity.address, advertisedAddress,
                     sizeof(advertisedAddress));
    Serial.printf("BLE: Using %s persisted random static identity\n",
                  identity.created ? "new" : "existing");
  } else {
    Serial.println("BLE: Using stable controller identity fallback");
    NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_PUBLIC, false);
  }
#endif

  NimBLEDevice::setSecurityAuth(false, false, false);
  NimBLEDevice::deleteAllBonds();
  Serial.printf("BLE: Advertising identity address %s (bonding disabled)\n",
                advertisedAddress[0] == '\0'
                    ? NimBLEDevice::getAddress().toString().c_str()
                    : advertisedAddress);
}

static uint8_t sanitizeMapDisplayRotation(uint8_t requestedRotation,
                                          const char *source) {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  if (requestedRotation > waveshare_board::display::MAX_SUPPORTED_ROTATION) {
    Serial.printf("BLE Settings: %s displayRotation %u unsupported, clamping "
                  "to 0\n",
                  source, requestedRotation);
    return waveshare_board::display::ROTATION_0;
  }
  if (requestedRotation == waveshare_board::display::ROTATION_90 &&
      !waveshare_board::display::EXPERIMENTAL_90_ROTATION_ENABLED) {
    Serial.printf("BLE Settings: %s displayRotation 1 disabled on Waveshare "
                  "until CO5300 window is verified; using 0\n",
                  source);
    return waveshare_board::display::ROTATION_0;
  }
#else
  (void)source;
#endif
  return requestedRotation;
}

/**
 * @brief Parse navigation instruction data
 */
static void parseNavigationData(const std::string &data) {
  // Format: "IconID|Distance|Instruction"
  int firstPipe = data.find('|');
  int secondPipe = data.find('|', firstPipe + 1);

  if (firstPipe == std::string::npos || secondPipe == std::string::npos) {
    Serial.println("BLE: Invalid navigation data format");
    return;
  }

  currentNavData.iconID = atoi(data.substr(0, firstPipe).c_str());
  currentNavData.distance =
      atoi(data.substr(firstPipe + 1, secondPipe - firstPipe - 1).c_str());

  std::string instruction = data.substr(secondPipe + 1);
  strncpy(currentNavData.instruction, instruction.c_str(),
          sizeof(currentNavData.instruction) - 1);
  currentNavData.instruction[sizeof(currentNavData.instruction) - 1] = '\0';

  navDataUpdated = true;

  Serial.printf("BLE Nav: Icon=%d, Dist=%dm, Instr=%s\n", currentNavData.iconID,
                currentNavData.distance, currentNavData.instruction);
}

static bool requireAuthenticated(const char *payloadName) {
  if (bleSessionAuthenticated) {
    return true;
  }

  bleDebugStats.rejectedUnauthenticatedCount++;
  bleDebugStats.lastRejectedUnauthenticatedMs = millis();
  Serial.printf("BLE: Rejected %s: session is not authenticated\n",
                payloadName == nullptr ? "payload" : payloadName);
  return false;
}

static bool isHexNonce(const char *nonce) {
  if (nonce == nullptr || strlen(nonce) != 32) {
    return false;
  }

  for (size_t i = 0; i < 32; i++) {
    if (!isxdigit((unsigned char)nonce[i])) {
      return false;
    }
  }

  return true;
}

static bool hmacSha256Hex(const char *message, char *outHex,
                          size_t outHexSize) {
  static const unsigned char authKey[] = "BikeComputer BLE v1 local pairing key";
  unsigned char digest[32];
  const mbedtls_md_info_t *mdInfo =
      mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);

  if (message == nullptr || outHex == nullptr || outHexSize < 65 ||
      mdInfo == nullptr) {
    return false;
  }

  int result = mbedtls_md_hmac(mdInfo, authKey, strlen((const char *)authKey),
                               (const unsigned char *)message, strlen(message),
                               digest);
  if (result != 0) {
    return false;
  }

  static const char hex[] = "0123456789abcdef";
  for (size_t i = 0; i < sizeof(digest); i++) {
    outHex[i * 2] = hex[(digest[i] >> 4) & 0x0F];
    outHex[(i * 2) + 1] = hex[digest[i] & 0x0F];
  }
  outHex[64] = '\0';
  return true;
}

static bool constantTimeEquals(const char *a, const char *b) {
  if (a == nullptr || b == nullptr) {
    return false;
  }

  size_t aLen = strlen(a);
  size_t bLen = strlen(b);
  if (aLen != bLen) {
    return false;
  }

  unsigned char diff = 0;
  for (size_t i = 0; i < aLen; i++) {
    diff |= (unsigned char)(a[i] ^ b[i]);
  }
  return diff == 0;
}

static void notifyAuthResponse(const char *response) {
  if (authCharacteristic == nullptr || response == nullptr) {
    return;
  }

  authCharacteristic->setValue((uint8_t *)response, strlen(response));
  authCharacteristic->notify();
}

static void logAuthPayloadPreview(const std::string &value) {
  char ascii[49];
  char hex[97];
  size_t previewLen = std::min(value.length(), (size_t)48);

  for (size_t i = 0; i < previewLen; i++) {
    uint8_t byte = (uint8_t)value[i];
    ascii[i] = (byte >= 0x20 && byte <= 0x7E) ? (char)byte : '.';
    snprintf(hex + (i * 2), sizeof(hex) - (i * 2), "%02X", byte);
  }

  ascii[previewLen] = '\0';
  hex[previewLen * 2] = '\0';
  Serial.printf("BLE: Auth payload preview len=%u ascii='%s' hex=%s\n",
                (unsigned)value.length(), ascii, hex);
}

static void handleAuthPayload(const std::string &value) {
  if (value.length() == 2 &&
      (((uint8_t)value[0] == 0x01 && (uint8_t)value[1] == 0x00) ||
       ((uint8_t)value[0] == 0x00 && (uint8_t)value[1] == 0x00))) {
    return;
  }

  if (value.length() > 128) {
    Serial.println("BLE: Rejected auth payload: too large");
    logAuthPayloadPreview(value);
    return;
  }

  char payload[129];
  memcpy(payload, value.data(), value.length());
  payload[value.length()] = '\0';

  char *command = strtok(payload, "|");
  char *nonce = strtok(nullptr, "|");
  char *proof = strtok(nullptr, "|");
  char *extra = strtok(nullptr, "|");

  if (command == nullptr || nonce == nullptr || extra != nullptr ||
      !isHexNonce(nonce)) {
    Serial.println("BLE: Rejected auth payload: invalid format");
    logAuthPayloadPreview(value);
    return;
  }

  if (strcmp(command, "HELLO") == 0 && proof == nullptr) {
    char message[48];
    char mac[65];
    char response[112];
    bleSessionAuthenticated = false;
    snprintf(message, sizeof(message), "server|%s", nonce);
    if (!hmacSha256Hex(message, mac, sizeof(mac))) {
      Serial.println("BLE: Failed to compute auth response");
      return;
    }

    strncpy(pendingAuthNonce, nonce, sizeof(pendingAuthNonce));
    pendingAuthNonce[sizeof(pendingAuthNonce) - 1] = '\0';
    snprintf(response, sizeof(response), "SERVER|%s|%s", nonce, mac);
    notifyAuthResponse(response);
    bleDebugStats.authChallengeCount++;
    bleDebugStats.lastAuthChallengeMs = millis();
    Serial.println("BLE: Auth challenge answered");
    return;
  }

  if (strcmp(command, "CLIENT") == 0 && proof != nullptr) {
    char message[48];
    char expected[65];
    if (!constantTimeEquals(nonce, pendingAuthNonce)) {
      Serial.println("BLE: Rejected auth proof: nonce mismatch");
      return;
    }

    snprintf(message, sizeof(message), "client|%s", nonce);
    if (!hmacSha256Hex(message, expected, sizeof(expected))) {
      Serial.println("BLE: Failed to compute client auth proof");
      return;
    }

    if (!constantTimeEquals(proof, expected)) {
      Serial.println("BLE: Rejected auth proof: invalid MAC");
      return;
    }

    bleSessionAuthenticated = true;
    bleDebugStats.authenticated = true;
    bleDebugStats.authSuccessCount++;
    bleDebugStats.lastAuthSuccessMs = millis();
    pendingAuthNonce[0] = '\0';
    char response[40];
    snprintf(response, sizeof(response), "OK|%s", nonce);
    notifyAuthResponse(response);
    Serial.println("BLE: Session authenticated");
    return;
  }

  Serial.println("BLE: Rejected auth payload: unknown command");
  logAuthPayloadPreview(value);
}

static bool hasPrefix(const std::string &value, const char *prefix) {
  return value.length() >= 4 && memcmp(value.data(), prefix, 4) == 0;
}

static void handleRouteGeometryPayload(const uint8_t *data, size_t len,
                                       const char *source) {
  if (len == 0) {
    lastRouteHash = 0;
    lastRouteLen = 0;
    Serial.printf("BLE: %s route geometry cleared\n",
                  source == nullptr ? "unknown" : source);
    bleDebugStats.routePacketCount++;
    bleDebugStats.lastRoutePacketMs = millis();
    routeOverlay.clear();
    triggerMapRedraw();
    return;
  }

  if (data == nullptr) {
    Serial.printf("BLE: Rejected %s route geometry: null payload\n",
                  source == nullptr ? "unknown" : source);
    return;
  }

  uint32_t hash = 0;
  for (size_t i = 0; i < len; i++) {
    hash = hash * 31 + data[i];
  }

  if (hash == lastRouteHash && len == lastRouteLen) {
    return;
  }

  lastRouteHash = hash;
  lastRouteLen = len;

  Serial.printf("BLE: %s route geometry received: %u bytes\n",
                source == nullptr ? "unknown" : source, (unsigned)len);
  bleDebugStats.routePacketCount++;
  bleDebugStats.lastRoutePacketMs = millis();

  if (!gpsReceivedFromApp && len >= 8) {
    int32_t routeStartLat = 0;
    int32_t routeStartLon = 0;
    memcpy(&routeStartLat, data, sizeof(routeStartLat));
    memcpy(&routeStartLon, data + sizeof(routeStartLon), sizeof(routeStartLon));
    gps.gpsData.latitude = (double)routeStartLat / 1000000.0;
    gps.gpsData.longitude = (double)routeStartLon / 1000000.0;
    gpsReceivedFromApp = true;
    pendingTransitionToMap = true;
    Serial.printf(
        "BLE route geometry: seeded map start %.6f,%.6f; transitioning to map\n",
        gps.gpsData.latitude, gps.gpsData.longitude);
  }

  routeOverlay.parseRouteData(data, len);
  triggerMapRedraw();
}

static void handleGpsPayload(const uint8_t *data, size_t len,
                             const char *source) {
  if (data == nullptr || len < 8) {
    Serial.printf("BLE: Rejected %s GPS position: expected at least 8 bytes\n",
                  source == nullptr ? "unknown" : source);
    return;
  }

  int32_t lat;
  int32_t lon;
  memcpy(&lat, data, sizeof(lat));
  memcpy(&lon, data + 4, sizeof(lon));

  gps.gpsData.latitude = (double)lat / 1000000.0;
  gps.gpsData.longitude = (double)lon / 1000000.0;
  gps.gpsData.fixMode = 3;
  gps.gpsData.satellites = 10;
  gps.gpsData.speed = 0;
  gps.gpsData.altitude = 0;
  gps.gpsData.distanceTraveled = 0;
  gps.gpsData.elapsedSeconds = 0;
  gps.gpsData.routeRemaining = 0;
  gps.gpsData.hasRouteRemaining = false;

  if (len >= 10) {
    uint16_t headingVal;
    memcpy(&headingVal, data + 8, sizeof(headingVal));
    gps.gpsData.heading = headingVal;
  }

  if (len >= 16) {
    uint16_t speedCmps;
    memcpy(&speedCmps, data + 14, sizeof(speedCmps));
    if (speedCmps != 0xFFFF) {
      gps.gpsData.speed = (uint16_t)((speedCmps * 36U + 500U) / 1000U);
    } else {
      gps.gpsData.speed = 0;
    }
  }

  if (len >= 18) {
    int16_t altitudeMeters;
    memcpy(&altitudeMeters, data + 16, sizeof(altitudeMeters));
    gps.gpsData.altitude = altitudeMeters;
  }

  if (len >= 22) {
    uint32_t distanceMeters;
    memcpy(&distanceMeters, data + 18, sizeof(distanceMeters));
    gps.gpsData.distanceTraveled = distanceMeters;
  }

  if (len >= 26) {
    uint32_t elapsedSeconds;
    memcpy(&elapsedSeconds, data + 22, sizeof(elapsedSeconds));
    gps.gpsData.elapsedSeconds = elapsedSeconds;
  }

  if (len >= 30) {
    uint32_t routeRemainingMeters;
    memcpy(&routeRemainingMeters, data + 26, sizeof(routeRemainingMeters));
    gps.gpsData.hasRouteRemaining = routeRemainingMeters != 0xFFFFFFFF;
    if (gps.gpsData.hasRouteRemaining) {
      gps.gpsData.routeRemaining = routeRemainingMeters;
    }
  }

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  bool rtcTimestampSynced = false;
  if (len >= 14) {
    uint32_t unixTime = 0;
    memcpy(&unixTime, data + 10, sizeof(unixTime));

    const uint32_t now = millis();
    const waveshare_board::rtc::Status &rtcStatus =
        waveshare_board::rtc::status();
    if (!rtcStatus.timeValid || lastBleRtcSyncMs == 0 ||
        now - lastBleRtcSyncMs >= BLE_RTC_SYNC_INTERVAL_MS) {
      rtcTimestampSynced = waveshare_board::rtc::syncFromUnixTime(
          static_cast<time_t>(unixTime), "BLE GPS timestamp");
      if (rtcTimestampSynced) {
        lastBleRtcSyncMs = now;
      }
    }
  }
#endif

  Serial.printf(
      "BLE: %s GPS position received: lat=%ld lon=%ld heading=%u rtcSync=%d\n",
      source == nullptr ? "unknown" : source, (long)lat, (long)lon,
      (unsigned)gps.gpsData.heading,
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
      rtcTimestampSynced
#else
      0
#endif
  );
  bleDebugStats.gpsPacketCount++;
  bleDebugStats.lastGpsPacketMs = millis();

  if (!gpsReceivedFromApp) {
    gpsReceivedFromApp = true;
    pendingTransitionToMap = true;
    Serial.println("BLE GPS: First position received, transitioning to map...");
  }

  triggerMapRedraw();
}

static void handleMapSetting(uint8_t settingId, int32_t settingValue,
                             const char *source) {
  bleDebugStats.settingsPacketCount++;
  bleDebugStats.lastSettingsPacketMs = millis();

  switch (settingId) {
  case 1:
    mapRenderSettings.minPolygonSize =
        (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)50);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("minPolySize", mapRenderSettings.minPolygonSize);
    settingsPrefs.end();
    Serial.printf("BLE Settings: minPolygonSize = %d (saved)\n",
                  mapRenderSettings.minPolygonSize);
    break;
  case 2:
    mapRenderSettings.detailLevel =
        (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)2);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("detailLevel", mapRenderSettings.detailLevel);
    settingsPrefs.end();
    Serial.printf("BLE Settings: detailLevel = %d (saved)\n",
                  mapRenderSettings.detailLevel);
    break;
  case 3:
    mapRenderSettings.routeLineWidth =
        (uint8_t)std::min(std::max(settingValue, (int32_t)2), (int32_t)48);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("routeWidth", mapRenderSettings.routeLineWidth);
    settingsPrefs.end();
    Serial.printf("BLE Settings: routeLineWidth = %d (saved)\n",
                  mapRenderSettings.routeLineWidth);
    break;
  case 9:
    mapRenderSettings.streetLineWidthBoost =
        (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)24);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("streetBoost",
                           mapRenderSettings.streetLineWidthBoost);
    settingsPrefs.end();
    Serial.printf("BLE Settings: streetLineWidthBoost = %d (saved)\n",
                  mapRenderSettings.streetLineWidthBoost);
    break;
  case 10:
    mapRenderSettings.positionMarkerScale =
        (uint8_t)std::min(std::max(settingValue, (int32_t)1), (int32_t)5);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("markerScale",
                           mapRenderSettings.positionMarkerScale);
    settingsPrefs.end();
    Serial.printf("BLE Settings: positionMarkerScale = %d (saved)\n",
                  mapRenderSettings.positionMarkerScale);
    break;
  case 11:
    mapRenderSettings.tapToSwitchScreens = settingValue != 0 ? 1 : 0;
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("tapSwitch", mapRenderSettings.tapToSwitchScreens);
    settingsPrefs.end();
    Serial.printf("BLE Settings: tapToSwitchScreens = %d (saved)\n",
                  mapRenderSettings.tapToSwitchScreens);
    break;
  case 4:
    mapRenderSettings.displayRotation =
        (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)3);
    mapRenderSettings.displayRotation =
        sanitizeMapDisplayRotation(mapRenderSettings.displayRotation, "write");
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("rotation", mapRenderSettings.displayRotation);
    settingsPrefs.end();
    Serial.printf("BLE Settings: displayRotation = %d (reboot to apply)\n",
                  mapRenderSettings.displayRotation);
    break;
  case 5:
    Serial.println("BLE Settings: Reboot command received! Restarting...");
    delay(500);
    ESP.restart();
    break;
  case 6:
    mapRenderSettings.mapRotationMode =
        (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)1);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("mapRotMode", mapRenderSettings.mapRotationMode);
    settingsPrefs.end();
    Serial.printf("BLE Settings: mapRotationMode = %d (saved)\n",
                  mapRenderSettings.mapRotationMode);
    break;
  case 7: {
    extern uint8_t zoom;
    mapRenderSettings.zoomLevel =
        (uint8_t)std::min(std::max(settingValue, (int32_t)0), (int32_t)5);
    zoom = mapRenderSettings.zoomLevel;
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("zoomLevel", mapRenderSettings.zoomLevel);
    settingsPrefs.end();
    Serial.printf("BLE Settings: zoomLevel = %d (saved)\n",
                  mapRenderSettings.zoomLevel);
    break;
  }
  case 8:
    mapRenderSettings.visibilityMask = (uint32_t)settingValue;
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUInt("visMask", mapRenderSettings.visibilityMask);
    settingsPrefs.end();
    Serial.printf("BLE Settings: visibilityMask = 0x%08X (saved)\n",
                  mapRenderSettings.visibilityMask);
    break;
  default:
    Serial.printf("BLE Settings: Unknown setting ID %d from %s\n", settingId,
                  source == nullptr ? "unknown" : source);
    break;
  }

  triggerMapRedraw();
}

static void handleMapSettingPayload(const uint8_t *data, size_t len,
                                    const char *source) {
  if (data == nullptr || len < 5) {
    Serial.printf("BLE: Rejected %s map setting: expected 5 bytes\n",
                  source == nullptr ? "unknown" : source);
    return;
  }

  uint8_t settingId = data[0];
  int32_t settingValue;
  memcpy(&settingValue, data + 1, sizeof(settingValue));
  handleMapSetting(settingId, settingValue, source);
}

// ============================================================================
// NimBLE Callbacks
// ============================================================================

class MyBLEServerCallbacks : public NimBLEServerCallbacks {
public:
  BLENavigationServer *server;

  MyBLEServerCallbacks(BLENavigationServer *srv) : server(srv) {}

  void onConnect(NimBLEServer *pServer) override {
    activeConnHandle = BLE_HS_CONN_HANDLE_NONE;
    server->connected = true;
    bleSessionAuthenticated = false;
    unauthTimeoutDisconnectRequested = false;
    bleDebugStats.connected = true;
    bleDebugStats.authenticated = false;
    bleDebugStats.connectCount++;
    bleDebugStats.lastConnectMs = millis();
    pendingAuthNonce[0] = '\0';
    Serial.println("BLE: iOS client connected!");
    // Stop advertising when connected
    NimBLEDevice::stopAdvertising();
  }

  void onConnect(NimBLEServer *pServer, ble_gap_conn_desc *desc) override {
    onConnect(pServer);
    if (desc != nullptr) {
      activeConnHandle = desc->conn_handle;
    }
  }

  void onDisconnect(NimBLEServer *pServer) override {
    server->connected = false;
    bleSessionAuthenticated = false;
    unauthTimeoutDisconnectRequested = false;
    activeConnHandle = BLE_HS_CONN_HANDLE_NONE;
    bleDebugStats.connected = false;
    bleDebugStats.authenticated = false;
    bleDebugStats.disconnectCount++;
    bleDebugStats.lastDisconnectMs = millis();
    pendingAuthNonce[0] = '\0';
    Serial.println("BLE: iOS client disconnected");
    // Restart advertising
    Serial.println("BLE: Restarting advertising...");
    NimBLEDevice::startAdvertising();
  }
};

class MyNavCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (value.empty()) {
      return;
    }

    if (hasPrefix(value, "MAPR")) {
      if (!requireAuthenticated("fallback route geometry")) {
        return;
      }
      handleRouteGeometryPayload((const uint8_t *)value.data() + 4,
                                 value.length() - 4, "fallback");
      return;
    }

    if (hasPrefix(value, "GPSP")) {
      if (!requireAuthenticated("fallback GPS position")) {
        return;
      }
      handleGpsPayload((const uint8_t *)value.data() + 4, value.length() - 4,
                       "fallback");
      return;
    }

    if (hasPrefix(value, "MSET")) {
      if (!requireAuthenticated("fallback map setting")) {
        return;
      }
      handleMapSettingPayload((const uint8_t *)value.data() + 4,
                              value.length() - 4, "fallback");
      return;
    }

    if (!requireAuthenticated("navigation instruction")) {
      return;
    }

    Serial.printf("BLE Nav received: %u bytes\n", (unsigned)value.length());
    bleDebugStats.navPacketCount++;
    bleDebugStats.lastNavPacketMs = millis();
    parseNavigationData(value);
  }
};

class MyRouteCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (!requireAuthenticated("route geometry")) {
      return;
    }

    handleRouteGeometryPayload((const uint8_t *)value.data(), value.length(),
                               "native");
  }
};

class MyGPSCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (!requireAuthenticated("GPS position")) {
      return;
    }

    handleGpsPayload((const uint8_t *)value.data(), value.length(), "native");
  }
};

/**
 * @brief Settings characteristic callback - receives runtime config from iOS
 * app Format: [settingId:1][value:4] = 5 bytes Setting IDs: 1=minPolygonSize,
 * 2=detailLevel, 3=routeLineWidth, 9=streetLineWidthBoost,
 * 10=positionMarkerScale
 */
class MySettingsCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (!requireAuthenticated("map setting")) {
      return;
    }

    handleMapSettingPayload((const uint8_t *)value.data(), value.length(),
                            "native");
  }
};

class MyAuthCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    std::string value = pChar->getValue();
    if (!value.empty()) {
      handleAuthPayload(value);
    }
  }
};

// ============================================================================
// BLE Navigation Server Implementation
// ============================================================================

/**
 * @brief Load all map settings from NVS at startup
 */
static void loadSettingsFromNVS() {
  Preferences prefs;
  prefs.begin("mapSettings", true); // read-only

  mapRenderSettings.minPolygonSize = prefs.getUChar("minPolySize", 0);
  mapRenderSettings.detailLevel = prefs.getUChar("detailLevel", 2);
  mapRenderSettings.routeLineWidth = prefs.getUChar("routeWidth", 4);
  mapRenderSettings.streetLineWidthBoost = prefs.getUChar("streetBoost", 0);
  mapRenderSettings.positionMarkerScale = prefs.getUChar("markerScale", 2);
  mapRenderSettings.displayRotation =
      sanitizeMapDisplayRotation(prefs.getUChar("rotation", 0), "NVS");
  mapRenderSettings.mapRotationMode = prefs.getUChar("mapRotMode", 0);
  mapRenderSettings.zoomLevel = prefs.getUChar("zoomLevel", 4);
  mapRenderSettings.tapToSwitchScreens = prefs.getUChar("tapSwitch", 0);
  mapRenderSettings.visibilityMask = prefs.getUInt("visMask", 0xFFFFFFFF);

  prefs.end();

  Serial.printf("BLE: Loaded settings from NVS - minPolySize=%d, "
                "detailLevel=%d, routeWidth=%d, streetBoost=%d, "
                "markerScale=%d, rotation=%d, tapSwitch=%d\n",
                mapRenderSettings.minPolygonSize, mapRenderSettings.detailLevel,
                mapRenderSettings.routeLineWidth,
                mapRenderSettings.streetLineWidthBoost,
                mapRenderSettings.positionMarkerScale,
                mapRenderSettings.displayRotation,
                mapRenderSettings.tapToSwitchScreens);
}

void BLENavigationServer::init(const char *deviceName) {
  if (initialized) {
    Serial.println("BLE: Already initialized");
    return;
  }

  // Load persisted settings from NVS
  loadSettingsFromNVS();

  Serial.println("BLE: Initializing NimBLE server...");

  initBleIdentityAndSecurity(deviceName);
  NimBLEDevice::setPower(ESP_PWR_LVL_P9); // Maximum power
  NimBLEDevice::setMTU(512);              // Increase MTU for route geometry

  // Create server
  pServer = NimBLEDevice::createServer();
  pServer->setCallbacks(new MyBLEServerCallbacks(this));

  // Create BikeComputer Navigation Service.
  NimBLEService *pService = pServer->createService(SERVICE_UUID);

  // Create Navigation Instruction Characteristic (UUID 2A6E)
  pNavCharacteristic = pService->createCharacteristic(
      NAV_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE_NR |
          NIMBLE_PROPERTY::NOTIFY // Added NOTIFY support just in case
  );
  pNavCharacteristic->setCallbacks(new MyNavCharacteristicCallbacks());

  // Create local auth characteristic required by the current iOS app before it
  // marks the device as navigation-ready.
  pAuthCharacteristic = pService->createCharacteristic(
      AUTH_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  pAuthCharacteristic->setCallbacks(new MyAuthCharacteristicCallbacks());
  pAuthCharacteristic->setValue("LOCKED");
  authCharacteristic = pAuthCharacteristic;

  pRouteCharacteristic = pService->createCharacteristic(
      ROUTE_CHAR_UUID, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  pRouteCharacteristic->setCallbacks(new MyRouteCharacteristicCallbacks());

  // Create GPS Position Characteristic (UUID 2A72)
  NimBLECharacteristic *pGPSCharacteristic =
      pService->createCharacteristic(GPS_CHAR_UUID, NIMBLE_PROPERTY::WRITE_NR);
  pGPSCharacteristic->setCallbacks(new MyGPSCharacteristicCallbacks());

  // Create Settings Characteristic (UUID 2A73) for runtime configuration
  NimBLECharacteristic *pSettingsCharacteristic =
      pService->createCharacteristic(SETTINGS_CHAR_UUID,
                                     NIMBLE_PROPERTY::WRITE_NR);
  pSettingsCharacteristic->setCallbacks(
      new MySettingsCharacteristicCallbacks());

  // Start service
  pService->start();

  // Start advertising
  NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  initialized = true;
  bleDebugStats.initialized = true;
  bleDebugStats.connected = connected;
  bleDebugStats.authenticated = bleSessionAuthenticated;
  Serial.printf("BLE: Server started, advertising as '%s'\n", deviceName);
}

void BLENavigationServer::process() {
  static uint32_t lastLog = 0;
  if (connected && !bleSessionAuthenticated &&
      !unauthTimeoutDisconnectRequested &&
      millis() - bleDebugStats.lastConnectMs > 12000) {
    Serial.println("BLE: Disconnecting unauthenticated client after timeout");
    unauthTimeoutDisconnectRequested = true;
    if (pServer != nullptr && activeConnHandle != BLE_HS_CONN_HANDLE_NONE) {
      pServer->disconnect(activeConnHandle);
    }
  }

  if (millis() - lastLog > 5000) {
    lastLog = millis();
    bleDebugStats.initialized = initialized;
    bleDebugStats.connected = connected;
    bleDebugStats.authenticated = bleSessionAuthenticated;

    if (connected) {
      Serial.println("BLE Status: CONNECTED");
    } else {
      // Only log advertising status if NOT connected, to confirm it's still
      // alive
      if (initialized)
        Serial.println("BLE Status: ADVERTISING (Waiting for connection...)");
    }

    Serial.printf("BLE Debug: up=%lus init=%d conn=%d auth=%d connects=%lu "
                  "disconnects=%lu authOK=%lu nav=%lu route=%lu gps=%lu "
                  "settings=%lu rejectAuth=%lu lastMs[c=%lu a=%lu n=%lu r=%lu "
                  "g=%lu s=%lu rej=%lu]\n",
                  millis() / 1000, initialized, connected,
                  bleSessionAuthenticated, bleDebugStats.connectCount,
                  bleDebugStats.disconnectCount, bleDebugStats.authSuccessCount,
                  bleDebugStats.navPacketCount, bleDebugStats.routePacketCount,
                  bleDebugStats.gpsPacketCount,
                  bleDebugStats.settingsPacketCount,
                  bleDebugStats.rejectedUnauthenticatedCount,
                  bleDebugStats.lastConnectMs, bleDebugStats.lastAuthSuccessMs,
                  bleDebugStats.lastNavPacketMs,
                  bleDebugStats.lastRoutePacketMs,
                  bleDebugStats.lastGpsPacketMs,
                  bleDebugStats.lastSettingsPacketMs,
                  bleDebugStats.lastRejectedUnauthenticatedMs);
  }
}

BLEDebugStats BLENavigationServer::getDebugStats() const {
  BLEDebugStats stats = bleDebugStats;
  stats.initialized = initialized;
  stats.connected = connected;
  stats.authenticated = bleSessionAuthenticated;
  return stats;
}

// ============================================================================
// Map Redraw Trigger (weak symbol - can be overridden by main app)
// ============================================================================

__attribute__((weak)) void triggerMapRedraw() {
  // Default implementation - will be overridden by mainScr.cpp
  Serial.println("BLE: triggerMapRedraw called (default - no map linked)");
}
