/**
 * @file ble_navigation.cpp
 * @brief BLE navigation server implementation
 *
 * Handles incoming navigation data from iOS app and triggers map updates.
 */

#include "ble_navigation.hpp"
#include "ble_connection_policy.hpp"
#include "device_ownership.hpp"
#include "ownership_button_policy.hpp"
#include "device_screen_protocol.hpp"
#include "map_profile_persistence.hpp"
#include "transfer_control_dispatch.hpp"
#include "../gps/gps.hpp"
#include "../gui/src/waitingScr.hpp"
#include "../gui/src/globalGuiDef.h"
#include "../maps/src/maps.hpp"
#include "../device_transfer/device_transfer_http.hpp"
#include "../firmware_metadata/firmware_metadata.hpp"
#include "../firmware_update/firmware_update_http.hpp"
#include "../map_transfer_http/map_transfer_http.hpp"
#include "../map_transfer/map_stream_compiled_trust.hpp"
#include "../route_overlay/route_overlay.hpp"
#include "../speaker/speaker.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "../waveshare_board/pcf85063.hpp"
#endif
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <esp_system.h>
#include <freertos/semphr.h>
#include <host/ble_hs_id.h>
#include <mbedtls/md.h>
#include <WiFi.h>

#if !defined(CONFIG_BT_NIMBLE_MAX_CONNECTIONS) || \
    CONFIG_BT_NIMBLE_MAX_CONNECTIONS != 1
#error "Bike Computer ownership requires CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1"
#endif

extern Gps gps;
extern device_transfer::HttpTransferServer deviceTransferHttp;
extern map_transfer::MapTransferHttpServer mapTransferHttp;
extern firmware_update::FirmwareUpdateHttpServer firmwareUpdateHttp;
extern Maps mapView;
extern Storage storage;

// Global instance
BLENavigationServer bleNavServer;

// Forward declaration of map redraw trigger
extern void triggerMapRedraw();
extern void applyDeviceScreenSettings();
extern bool isMapScreenActive();
extern bool isMapGuidanceScreenActive();

// NavigationData struct is now in ble_navigation.hpp

// Map rendering settings moved to header for external access
// Global map render settings (accessible from maps.cpp)
MapRenderSettings mapRenderSettings;

// NVS Preferences for persistent settings
static Preferences settingsPrefs;

// Global navigation data
static NavigationData currentNavData = {0, 0, ""};
static volatile bool navDataUpdated = false;
static volatile int16_t phoneBatteryLevelPercent = -1;
static volatile bool phoneBatteryCharging = false;
static bool bleSessionAuthenticated = false;
static bool bleSessionUsesIndependentMapProfiles = false;
static constexpr uint8_t CAPABILITY_EXTENDED_MAP_VISIBILITY =
    map_profile_protocol::EXTENDED_VISIBILITY_CAPABILITY_MASK;
static constexpr uint8_t CAPABILITY_BATTERY_STATUS_SCREEN = 1 << 5;
static char pendingAuthNonce[33] = "";
static NimBLECharacteristic *authCharacteristic = nullptr;
static NimBLECharacteristic *mapTransferStatusCharacteristic = nullptr;
static BLEDebugStats bleDebugStats;
static_assert(BLE_HS_CONN_HANDLE_NONE == ble_connection_policy::noConnection,
              "single-connection policy must match NimBLE's empty handle");
static uint16_t activeConnHandle = BLE_HS_CONN_HANDLE_NONE;
static bool unauthTimeoutDisconnectRequested = false;
static device_ownership::DeviceOwnership deviceOwnership;
static bool deviceOwnershipReady = false;
static bool ownershipPairingActiveSnapshot = false;
static StaticSemaphore_t deviceOwnershipMutexStorage;
static SemaphoreHandle_t deviceOwnershipMutex = nullptr;
static StaticSemaphore_t notificationTransportMutexStorage;
static SemaphoreHandle_t notificationTransportMutex = nullptr;
static bool ownershipAdvertisingDirty = false;
static bool ownershipDisconnectPending = false;
static bool ownershipRestartRequested = false;
static uint32_t ownershipRestartRequestedMs = 0;
static portMUX_TYPE ownershipUiMux = portMUX_INITIALIZER_UNLOCKED;
static bool ownershipUiUpdatePending = false;
static char ownershipUiName[device_ownership::MAX_DEVICE_NAME_BYTES + 1] = "";
static bool ownershipUiClaimed = false;
static int32_t ownershipUiPairingCode = -1;
static uint32_t ownershipUiPairingGeneration = 0;
static ownership_button_policy::ComparisonRenderGate
    ownershipComparisonRenderGate;
static ble_transfer::PendingRequest pendingTransferControl;
static portMUX_TYPE destinationPickerMux = portMUX_INITIALIZER_UNLOCKED;
static DestinationCatalogSnapshot destinationCatalog;
static DestinationPickerStatusSnapshot destinationPickerStatus;
static destination_picker_protocol::CatalogReassembler destinationCatalogReassembler;
static StaticSemaphore_t destinationCatalogReassemblerMutexStorage;
static SemaphoreHandle_t destinationCatalogReassemblerMutex = nullptr;
static bool destinationRequestPending = false;
static uint32_t destinationRequestStartedMs = 0;
static uint32_t destinationStatusUpdatedMs = 0;

static bool notifyAuthenticatedNavigation(NimBLECharacteristic *characteristic,
                                          const uint8_t *data, size_t length);

static void queueOwnershipUiUpdate(int32_t pairingCode = -1,
                                   uint32_t pairingGeneration = 0) {
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    return;
  }
  const std::string name = deviceOwnership.deviceName();
  const bool claimed = deviceOwnership.isClaimed();
  xSemaphoreGive(deviceOwnershipMutex);
  portENTER_CRITICAL(&ownershipUiMux);
  strncpy(ownershipUiName, name.c_str(), sizeof(ownershipUiName) - 1);
  ownershipUiName[sizeof(ownershipUiName) - 1] = '\0';
  ownershipUiClaimed = claimed;
  ownershipUiPairingCode = pairingCode;
  ownershipUiPairingGeneration = pairingGeneration;
  ownershipUiUpdatePending = true;
  portEXIT_CRITICAL(&ownershipUiMux);
}

static void applyPendingOwnershipUiUpdate() {
  char name[sizeof(ownershipUiName)] = "";
  bool claimed = false;
  int32_t pairingCode = -1;
  uint32_t pairingGeneration = 0;
  portENTER_CRITICAL(&ownershipUiMux);
  const bool pending = ownershipUiUpdatePending;
  if (pending) {
    strncpy(name, ownershipUiName, sizeof(name) - 1);
    claimed = ownershipUiClaimed;
    pairingCode = ownershipUiPairingCode;
    pairingGeneration = ownershipUiPairingGeneration;
    ownershipUiUpdatePending = false;
  }
  portEXIT_CRITICAL(&ownershipUiMux);
  if (pending) {
    updateWaitingOwnershipStatus(name, claimed, pairingCode);
    portENTER_CRITICAL(&ownershipUiMux);
    if (pairingCode >= 0) {
      ownershipComparisonRenderGate.request(pairingGeneration);
    } else {
      ownershipComparisonRenderGate.cancel();
    }
    portEXIT_CRITICAL(&ownershipUiMux);
  }
}

static void applyOwnershipAdvertisingData() {
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    return;
  }
  const std::string name = deviceOwnership.advertisedName();
  const std::vector<uint8_t> manufacturerData =
      deviceOwnership.advertisementManufacturerData();
  xSemaphoreGive(deviceOwnershipMutex);
  NimBLEDevice::setDeviceName(name);
  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  advertising->setName(name);
  advertising->setManufacturerData(manufacturerData);
  ownershipAdvertisingDirty = false;
}

NavigationData getCurrentNavigationData() { return currentNavData; }

bool hasCurrentNavigationData() {
  return currentNavData.distance > 0 || currentNavData.instruction[0] != '\0';
}

int16_t getPhoneBatteryLevelPercent() { return phoneBatteryLevelPercent; }
bool isPhoneBatteryCharging() { return phoneBatteryCharging; }

DestinationCatalogSnapshot getDestinationCatalogSnapshot() {
  portENTER_CRITICAL(&destinationPickerMux);
  DestinationCatalogSnapshot snapshot = destinationCatalog;
  portEXIT_CRITICAL(&destinationPickerMux);
  return snapshot;
}

DestinationPickerStatusSnapshot getDestinationPickerStatusSnapshot() {
  portENTER_CRITICAL(&destinationPickerMux);
  DestinationPickerStatusSnapshot snapshot = destinationPickerStatus;
  portEXIT_CRITICAL(&destinationPickerMux);
  return snapshot;
}

static void setDestinationPickerStatus(DestinationPickerStatusCode code,
                                       uint32_t generation, uint16_t token,
                                       const char *message) {
  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&destinationPickerMux);
  destinationPickerStatus.code = code;
  destinationPickerStatus.generation = generation;
  destinationPickerStatus.token = token;
  destinationPickerStatus.revision++;
  strncpy(destinationPickerStatus.message, message == nullptr ? "" : message,
          sizeof(destinationPickerStatus.message) - 1);
  destinationPickerStatus.message[sizeof(destinationPickerStatus.message) - 1] =
      '\0';
  destinationStatusUpdatedMs = nowMs;
  portEXIT_CRITICAL(&destinationPickerMux);
}

static bool beginDestinationRequest(uint32_t nowMs) {
  portENTER_CRITICAL(&destinationPickerMux);
  if (destinationRequestPending) {
    portEXIT_CRITICAL(&destinationPickerMux);
    return false;
  }
  destinationRequestPending = true;
  destinationRequestStartedMs = nowMs;
  portEXIT_CRITICAL(&destinationPickerMux);
  return true;
}

static bool applyDestinationResponseIfPending(
    DestinationPickerStatusCode code, uint32_t generation, uint16_t token,
    const char *message) {
  const uint32_t nowMs = millis();
  portENTER_CRITICAL(&destinationPickerMux);
  const bool matches = destinationRequestPending &&
                       destinationPickerStatus.generation == generation &&
                       destinationPickerStatus.token == token;
  if (matches) {
    destinationPickerStatus.code = code;
    destinationPickerStatus.revision++;
    strncpy(destinationPickerStatus.message, message == nullptr ? "" : message,
            sizeof(destinationPickerStatus.message) - 1);
    destinationPickerStatus
        .message[sizeof(destinationPickerStatus.message) - 1] = '\0';
    destinationStatusUpdatedMs = nowMs;
    if (code != DestinationPickerStatusCode::Calculating) {
      destinationRequestPending = false;
    }
  }
  portEXIT_CRITICAL(&destinationPickerMux);
  return matches;
}

static bool finishDestinationRequestIfPending() {
  portENTER_CRITICAL(&destinationPickerMux);
  const bool wasPending = destinationRequestPending;
  destinationRequestPending = false;
  portEXIT_CRITICAL(&destinationPickerMux);
  return wasPending;
}

static bool destinationRequestTimedOut(uint32_t nowMs) {
  portENTER_CRITICAL(&destinationPickerMux);
  const bool timedOut = destinationRequestPending &&
                        static_cast<uint32_t>(nowMs -
                                              destinationRequestStartedMs) >
                            destination_picker_protocol::REQUEST_TIMEOUT_MS;
  if (timedOut) {
    destinationRequestPending = false;
  }
  portEXIT_CRITICAL(&destinationPickerMux);
  return timedOut;
}

static bool destinationStatusShouldExpire(uint32_t nowMs) {
  portENTER_CRITICAL(&destinationPickerMux);
  const bool shouldExpire =
      !destinationRequestPending &&
      destinationPickerStatus.code != DestinationPickerStatusCode::Idle &&
      static_cast<uint32_t>(nowMs - destinationStatusUpdatedMs) >
          destination_picker_protocol::TERMINAL_STATUS_DISPLAY_MS;
  portEXIT_CRITICAL(&destinationPickerMux);
  return shouldExpire;
}

static bool destinationCatalogContains(uint32_t generation, uint16_t token) {
  bool found = false;
  portENTER_CRITICAL(&destinationPickerMux);
  if (destinationCatalog.generation == generation) {
    for (uint8_t i = 0; i < destinationCatalog.count; i++) {
      if (destinationCatalog.items[i].token == token) {
        found = true;
        break;
      }
    }
  }
  portEXIT_CRITICAL(&destinationPickerMux);
  return found;
}

bool requestDestinationRoute(uint32_t generation, uint16_t token) {
  if (!destinationCatalogContains(generation, token)) {
    setDestinationPickerStatus(DestinationPickerStatusCode::Stale, generation,
                               token, "Destination list changed");
    return false;
  }
  if (!bleNavServer.isConnected() || !bleSessionAuthenticated ||
      mapTransferStatusCharacteristic == nullptr) {
    setDestinationPickerStatus(DestinationPickerStatusCode::Failed, generation,
                               token, "Open app to start navigation");
    return false;
  }
  if (!beginDestinationRequest(millis())) {
    return false;
  }

  uint8_t request[10] = {'D', 'R', 'E', 'Q'};
  destination_picker_protocol::writeUInt32LE(generation, request + 4);
  destination_picker_protocol::writeUInt16LE(token, request + 8);
  setDestinationPickerStatus(DestinationPickerStatusCode::Calculating,
                             generation, token, "Starting navigation...");
  if (!notifyAuthenticatedNavigation(mapTransferStatusCharacteristic, request,
                                     sizeof(request))) {
    finishDestinationRequestIfPending();
    setDestinationPickerStatus(DestinationPickerStatusCode::Failed, generation,
                               token, "Secure notification failed");
    return false;
  }
  Serial.printf("BLE Destination: requested generation=%lu token=%u\n",
                (unsigned long)generation, token);
  return true;
}

static uint8_t deviceScreenBit(uint8_t screen) {
  return (screen <= DEVICE_SCREEN_BATTERY_STATUS) ? (1 << screen) : 0;
}

static uint8_t normalizedEnabledScreensMask(int32_t rawMask) {
  uint8_t mask = (uint8_t)rawMask & DEVICE_SCREEN_SUPPORTED_MASK;
  return mask == 0 ? DEVICE_SCREEN_SUPPORTED_MASK : mask;
}

static uint8_t normalizedDefaultScreen(int32_t rawDefault,
                                       uint8_t enabledScreensMask) {
  uint8_t defaultScreen =
      rawDefault >= 0 && rawDefault <= DEVICE_SCREEN_BATTERY_STATUS
          ? (uint8_t)rawDefault
          : (uint8_t)DEVICE_SCREEN_MAP_PLUS_NAVIGATION;
  if (enabledScreensMask & deviceScreenBit(defaultScreen)) {
    return defaultScreen;
  }
  if (enabledScreensMask & deviceScreenBit(DEVICE_SCREEN_MAP_PLUS_NAVIGATION)) {
    return DEVICE_SCREEN_MAP_PLUS_NAVIGATION;
  }
  if (enabledScreensMask & deviceScreenBit(DEVICE_SCREEN_RIDE_STATS)) {
    return DEVICE_SCREEN_RIDE_STATS;
  }
  if (enabledScreensMask & deviceScreenBit(DEVICE_SCREEN_MAP)) {
    return DEVICE_SCREEN_MAP;
  }
  if (enabledScreensMask & deviceScreenBit(DEVICE_SCREEN_NAVIGATION)) {
    return DEVICE_SCREEN_NAVIGATION;
  }
  if (enabledScreensMask & deviceScreenBit(DEVICE_SCREEN_BATTERY_STATUS)) {
    return DEVICE_SCREEN_BATTERY_STATUS;
  }
  return DEVICE_SCREEN_MAP_PLUS_NAVIGATION;
}

static uint32_t normalizedDisconnectedSleepTimeoutSeconds(int64_t rawSeconds) {
  if (rawSeconds <= 0) {
    return 0;
  }
  return (uint32_t)std::min(std::max(rawSeconds, (int64_t)60), (int64_t)600);
}

static void clearCurrentNavigationData() {
  currentNavData = {0, 0, ""};
  navDataUpdated = true;
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

static bool unwrapOwnerAuthenticatedPayload(
    device_ownership::AuthenticatedChannel channel, const std::string &frame,
    std::string &payload, const char *payloadName) {
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    payload = frame;
    return !deviceOwnershipReady;
  }
  const bool requiresFrame = deviceOwnership.isSessionAuthenticated();
  const bool authenticationStateDiverged =
      bleSessionAuthenticated && !requiresFrame;
  const bool accepted = !authenticationStateDiverged &&
                        (!requiresFrame ||
                         deviceOwnership.unwrapAuthenticatedPayload(
                             channel, frame, payload));
  if (!requiresFrame) {
    payload = frame;
  }
  xSemaphoreGive(deviceOwnershipMutex);
  if (authenticationStateDiverged) {
    bleSessionAuthenticated = false;
    bleDebugStats.authenticated = false;
    ownershipDisconnectPending = true;
    Serial.println("BLE: Ownership session was lost; disconnect requested");
  }
  if (!accepted) {
    bleDebugStats.rejectedUnauthenticatedCount++;
    bleDebugStats.lastRejectedUnauthenticatedMs = millis();
    Serial.printf("BLE: Rejected %s: invalid authenticated frame\n",
                  payloadName == nullptr ? "payload" : payloadName);
  }
  return accepted;
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

static void notifyAuthResponse(const std::string &response) {
  if (authCharacteristic == nullptr || response.empty() ||
      notificationTransportMutex == nullptr ||
      xSemaphoreTake(notificationTransportMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    return;
  }
  constexpr size_t kMaximumOwnershipNotificationBytes = 182;
  if (response.size() > kMaximumOwnershipNotificationBytes) {
    Serial.printf("BLE: Ownership response too large: %u bytes\n",
                  static_cast<unsigned>(response.size()));
    xSemaphoreGive(notificationTransportMutex);
    return;
  }
  uint16_t peerMtu = 23;
  NimBLEService *service = authCharacteristic->getService();
  NimBLEServer *server = service == nullptr ? nullptr : service->getServer();
  if (server != nullptr && activeConnHandle != BLE_HS_CONN_HANDLE_NONE) {
    peerMtu = server->getPeerMTU(activeConnHandle);
  }
  if (response.size() > static_cast<size_t>(peerMtu - 3)) {
    Serial.printf(
        "BLE: Ownership response needs ATT MTU %u; peer negotiated %u\n",
        static_cast<unsigned>(response.size() + 3), peerMtu);
    xSemaphoreGive(notificationTransportMutex);
    return;
  }
  authCharacteristic->setValue(
      reinterpret_cast<const uint8_t *>(response.data()), response.size());
  authCharacteristic->notify();
  xSemaphoreGive(notificationTransportMutex);
}

static void notifyAuthResponse(const char *response) {
  if (response != nullptr) notifyAuthResponse(std::string(response));
}

static bool notifyAuthenticatedNavigation(NimBLECharacteristic *characteristic,
                                          const uint8_t *data, size_t length) {
  if (characteristic == nullptr || data == nullptr ||
      !bleSessionAuthenticated || !deviceOwnershipReady ||
      deviceOwnershipMutex == nullptr || notificationTransportMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    return false;
  }
  std::string frame;
  const std::string payload(reinterpret_cast<const char *>(data), length);
  const bool protectedPayload = deviceOwnership.protectAuthenticatedPayload(
      device_ownership::AuthenticatedChannel::Navigation, payload, frame);
  if (!protectedPayload || activeConnHandle == BLE_HS_CONN_HANDLE_NONE) {
    xSemaphoreGive(deviceOwnershipMutex);
    return false;
  }
  if (xSemaphoreTake(notificationTransportMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    xSemaphoreGive(deviceOwnershipMutex);
    return false;
  }
  NimBLEService *service = characteristic->getService();
  NimBLEServer *server = service == nullptr ? nullptr : service->getServer();
  if (server == nullptr ||
      frame.size() > static_cast<size_t>(server->getPeerMTU(activeConnHandle) - 3)) {
    Serial.printf("BLE: Protected navigation notification too large: %u bytes\n",
                  static_cast<unsigned>(frame.size()));
    xSemaphoreGive(notificationTransportMutex);
    xSemaphoreGive(deviceOwnershipMutex);
    return false;
  }
  // Keep sequence assignment, characteristic value publication, and notify in
  // one critical section. Calls arrive from both NimBLE and application tasks;
  // splitting these operations can publish R2 sequence N+1 before N.
  characteristic->setValue(
      reinterpret_cast<const uint8_t *>(frame.data()), frame.size());
  characteristic->notify();
  xSemaphoreGive(notificationTransportMutex);
  xSemaphoreGive(deviceOwnershipMutex);
  return true;
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

static void handleAuthPayload(const std::string &frame) {
  std::string value;
  if (!unwrapOwnerAuthenticatedPayload(
          device_ownership::AuthenticatedChannel::Auth, frame, value,
          "ownership command")) {
    return;
  }
  if (value.length() == 2 &&
      (((uint8_t)value[0] == 0x01 && (uint8_t)value[1] == 0x00) ||
       ((uint8_t)value[0] == 0x00 && (uint8_t)value[1] == 0x00))) {
    return;
  }

  if (value.length() > 256) {
    Serial.println("BLE: Rejected auth payload: too large");
    logAuthPayloadPreview(value);
    return;
  }

  if (deviceOwnershipReady) {
    device_ownership::CommandResult ownershipResult;
    uint32_t pairingCode = 0;
    uint32_t pairingGeneration = 0;
    bool ownershipLockAcquired = false;
    bool ownershipSessionAuthenticated = false;
    if (deviceOwnershipMutex != nullptr &&
        xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(250)) == pdTRUE) {
      ownershipLockAcquired = true;
      ownershipResult = deviceOwnership.handle(value, millis());
      pairingCode = deviceOwnership.pairingCode();
      pairingGeneration = deviceOwnership.pairingGeneration();
      if (frame.size() >= 2 && frame[0] == 'S' && frame[1] == '2' &&
          !ownershipResult.response.empty() &&
          !(ownershipResult.response.size() >= 2 &&
            ownershipResult.response[0] == 'R' &&
            ownershipResult.response[1] == '2') &&
          deviceOwnership.isSessionAuthenticated()) {
        std::string protectedResponse;
        if (deviceOwnership.protectAuthenticatedPayload(
                device_ownership::AuthenticatedChannel::Auth,
                ownershipResult.response, protectedResponse)) {
          ownershipResult.response = std::move(protectedResponse);
        } else {
          ownershipResult.response.clear();
        }
      }
      ownershipSessionAuthenticated =
          deviceOwnership.isSessionAuthenticated();
      if (!ownershipResult.response.empty()) {
        // Publish before releasing the ownership lock. This keeps the state
        // transition, R2 sequence assignment, and transport order atomic with
        // respect to both a following BLE write and a physical BOOT action.
        notifyAuthResponse(ownershipResult.response);
      }
      xSemaphoreGive(deviceOwnershipMutex);
    }
    if (!ownershipLockAcquired) {
      Serial.println("BLE: Rejected ownership command: state lock unavailable");
      return;
    }
    if (bleSessionAuthenticated && !ownershipSessionAuthenticated) {
      bleSessionAuthenticated = false;
      bleDebugStats.authenticated = false;
      ownershipDisconnectPending = true;
      Serial.println("BLE: Ownership command invalidated session; disconnect requested");
    }
    if (ownershipResult.matched) {
      switch (ownershipResult.event) {
      case device_ownership::Event::PairingStarted:
        ownershipPairingActiveSnapshot = true;
        queueOwnershipUiUpdate(
            static_cast<int32_t>(pairingCode),
            pairingGeneration);
        Serial.println("BLE: Secure ownership comparison started");
        break;
      case device_ownership::Event::Paired:
        ownershipPairingActiveSnapshot = false;
        ownershipAdvertisingDirty = true;
        queueOwnershipUiUpdate();
        Serial.println("BLE: Device ownership registered");
        break;
      case device_ownership::Event::Authenticated:
        bleSessionAuthenticated = true;
        bleDebugStats.authenticated = true;
        bleDebugStats.authSuccessCount++;
        bleDebugStats.lastAuthSuccessMs = millis();
        queueOwnershipUiUpdate();
        Serial.println("BLE: Owner session authenticated");
        break;
      case device_ownership::Event::Renamed:
        ownershipAdvertisingDirty = true;
        queueOwnershipUiUpdate();
        Serial.println("BLE: Device name updated");
        break;
      case device_ownership::Event::Unpaired:
        bleSessionAuthenticated = false;
        bleDebugStats.authenticated = false;
        ownershipAdvertisingDirty = true;
        queueOwnershipUiUpdate();
        ownershipRestartRequested = true;
        ownershipRestartRequestedMs = millis();
        Serial.println("BLE: Device ownership removed; restart scheduled");
        break;
      case device_ownership::Event::None:
        break;
      }
      return;
    }
  }

  char payload[257];
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

  bool legacyAllowed = false;
  bool claimed = true;
  std::string stableDeviceId;
  if (deviceOwnershipReady && deviceOwnershipMutex != nullptr &&
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
    legacyAllowed = deviceOwnership.allowsLegacyAuthentication();
    claimed = deviceOwnership.isClaimed();
    stableDeviceId = deviceOwnership.deviceIdHex();
    xSemaphoreGive(deviceOwnershipMutex);
  }
  if (!deviceOwnershipReady || !legacyAllowed) {
    const std::string response =
        (deviceOwnershipReady && claimed ? "OWNED|" : "ERROR|") +
        (deviceOwnershipReady ? stableDeviceId : "ownership_unavailable");
    notifyAuthResponse(response.c_str());
    Serial.println("BLE: Rejected legacy shared-key authentication");
    return;
  }

  if (strcmp(command, "HELLO") == 0 && proof == nullptr) {
    char message[48];
    char mac[65];
    char response[112];
    bleSessionAuthenticated = false;
    bleSessionUsesIndependentMapProfiles = false;
    phoneBatteryLevelPercent = -1;
    phoneBatteryCharging = false;
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

static std::string trimAscii(const std::string &value) {
  size_t begin = 0;
  while (begin < value.size() &&
         std::isspace(static_cast<unsigned char>(value[begin]))) {
    begin++;
  }
  size_t end = value.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    end--;
  }
  return value.substr(begin, end - begin);
}

static void handleSoundPlaybackRequest(
    const waveshare_board::speaker::PlaybackRequest &request,
    const char *source) {
  if (!waveshare_board::speaker::isSupported(request.sound)) {
    Serial.printf("BLE Sound: sound ID %u is unavailable on this hardware\n",
                  static_cast<unsigned>(request.sound));
    return;
  }

  if (!waveshare_board::speaker::requestPlay(request.sound,
                                             request.volumePercent)) {
    Serial.printf("BLE Sound: failed to queue sound ID %u\n",
                  static_cast<unsigned>(request.sound));
    return;
  }

  Serial.printf("BLE Sound: queued sound ID %u at %u%% from %s\n",
                static_cast<unsigned>(request.sound), request.volumePercent,
                source == nullptr ? "unknown" : source);
}

static bool handleSoundPlayCommand(const std::string &value,
                                   const char *authLabel,
                                   const char *source) {
  waveshare_board::speaker::PlaybackRequest request{};
  const auto result = waveshare_board::speaker::classifyPlayCommand(
      reinterpret_cast<const uint8_t *>(value.data()), value.length(),
      bleSessionAuthenticated, request);
  if (result == waveshare_board::speaker::PlayCommandResult::NotMatched) {
    return false;
  }
  if (result == waveshare_board::speaker::PlayCommandResult::RejectedUnauthenticated) {
    requireAuthenticated(authLabel);
    return true;
  }
  if (result == waveshare_board::speaker::PlayCommandResult::RejectedMalformed) {
    Serial.printf("BLE Sound: rejected %s payload\n",
                  source == nullptr ? "unknown" : source);
    return true;
  }
  handleSoundPlaybackRequest(request, source);
  return true;
}

static void notifyPowerButtonHonkStatus(
    NimBLECharacteristic *pChar,
    const waveshare_board::speaker::PowerButtonHonkCommand &command,
    bool applied);

static bool handlePowerButtonHonkCommand(const std::string &value,
                                         const char *authLabel,
                                         const char *source,
                                         NimBLECharacteristic *statusChar) {
  waveshare_board::speaker::PowerButtonHonkCommand command{};
  const auto result =
      waveshare_board::speaker::classifyPowerButtonHonkCommand(
          reinterpret_cast<const uint8_t *>(value.data()), value.length(),
          bleSessionAuthenticated, command);
  if (result == waveshare_board::speaker::PlayCommandResult::NotMatched) {
    return false;
  }
  if (result ==
      waveshare_board::speaker::PlayCommandResult::RejectedUnauthenticated) {
    requireAuthenticated(authLabel);
    return true;
  }
  if (result ==
      waveshare_board::speaker::PlayCommandResult::RejectedMalformed) {
    Serial.printf("BLE Sound: rejected PWR honk payload from %s\n",
                  source == nullptr ? "unknown" : source);
    return true;
  }
  const bool applied =
      waveshare_board::speaker::configurePowerButtonHonk(command.config);
  notifyPowerButtonHonkStatus(statusChar, command, applied);
  if (!applied) {
    Serial.printf("BLE Sound: failed to configure PWR honk from %s\n",
                  source == nullptr ? "unknown" : source);
    return true;
  }
  Serial.printf("BLE Sound: configured PWR honk enabled=%d sound=%u volume=%u "
                "from %s\n",
                command.config.enabled ? 1 : 0,
                static_cast<unsigned>(command.config.sound),
                command.config.volumePercent,
                source == nullptr ? "unknown" : source);
  return true;
}

static std::string jsonEscape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else {
      out.push_back(c);
    }
  }
  return out;
}

static std::string mapTransferStatusJson() {
  map_transfer::HttpTransferStatus transferStatus = mapTransferHttp.status();
  map_transfer::ActiveMapSelection activeMap;
  map_transfer::MapTransferInstaller installer("/sdcard");
  map_transfer::InstallStatus activeStatus =
      installer.readActiveMap(activeMap);
  const bool streamSupported = mapTransferHttp.streamInstallSupported();

  std::string body = std::string("{\"configured\":") +
                     (transferStatus.configured ? "true" : "false") +
                     ",\"enabled\":" +
                     (transferStatus.enabled ? "true" : "false") +
                     ",\"port\":" + std::to_string(transferStatus.port) +
                     ",\"firmwareVersion\":\"" +
                     jsonEscape(firmware_metadata::version()) +
                     "\",\"firmwareBuild\":" +
                     std::to_string(firmware_metadata::build()) +
                     ",\"firmwareGitSha\":\"" +
                     jsonEscape(firmware_metadata::gitSha()) + "\"" +
                     ",\"protocols\":[1" +
                     (streamSupported ? ",2" : "") +
                     "]" +
                     (streamSupported
                          ? ",\"streamFormatVersions\":[1],\"streamTrust\":" +
                                map_transfer::compiledMapStreamTrustCapabilitiesJson()
                          : "") +
                     ",\"sdPresent\":" +
                     (storage.getSdLoaded() ? "true" : "false") +
                     ",\"mapFound\":" +
                     (mapView.debugIsMapFound() ? "true" : "false") +
                     ",\"mapBlocks\":" +
                     std::to_string(mapView.debugCachedBlockCount());

  if (!transferStatus.baseUrl.empty()) {
    body += ",\"baseUrl\":\"" + jsonEscape(transferStatus.baseUrl) + "\"";
  }

  if (!transferStatus.apSsid.empty()) {
    body += ",\"apSsid\":\"" + jsonEscape(transferStatus.apSsid) + "\"";
  }
  if (activeStatus.ok) {
    body += ",\"activeMapId\":\"" + jsonEscape(activeMap.mapId) + "\"";
    if (!activeMap.sessionId.empty()) {
      body += ",\"activeSessionId\":\"" +
              jsonEscape(activeMap.sessionId) + "\"";
    }
  } else {
    body += ",\"activeError\":{\"code\":\"" + jsonEscape(activeStatus.code) +
            "\"}";
  }

  body += ",\"activation\":" + mapTransferHttp.activationStatusJson(true);

  if (!transferStatus.lastErrorCode.empty() &&
      !mapTransferHttp.activationHasError()) {
    body += ",\"lastError\":{\"code\":\"" +
            jsonEscape(transferStatus.lastErrorCode) + "\"}";
  }

  body += "}";
  return body;
}

static std::string genericTransferStatusJson() {
  device_transfer::HttpTransferStatus transferStatus =
      deviceTransferHttp.status();
  std::string body = std::string("{\"configured\":") +
                     (transferStatus.configured ? "true" : "false") +
                     ",\"enabled\":" +
                     (transferStatus.enabled ? "true" : "false") +
                     ",\"port\":" + std::to_string(transferStatus.port) +
                     ",\"mode\":\"" + jsonEscape(transferStatus.mode) + "\"";

  if (!transferStatus.baseUrl.empty()) {
    body += ",\"baseUrl\":\"" + jsonEscape(transferStatus.baseUrl) + "\"";
  }
  if (!transferStatus.apSsid.empty()) {
    body += ",\"apSsid\":\"" + jsonEscape(transferStatus.apSsid) + "\"";
  }
  if (!transferStatus.sessionToken.empty()) {
    body += ",\"sessionToken\":\"" + jsonEscape(transferStatus.sessionToken) +
            "\"";
  }
  if (!transferStatus.lastErrorCode.empty()) {
    body += ",\"lastError\":{\"code\":\"" +
            jsonEscape(transferStatus.lastErrorCode) + "\",\"message\":\"" +
            jsonEscape(transferStatus.lastErrorMessage) + "\"}";
  }
  firmware_update::FirmwareUpdateStatus firmwareStatus =
      firmwareUpdateHttp.status();
  body += ",\"firmware\":{\"status\":\"" +
          jsonEscape(firmwareStatus.status) + "\",\"target\":\"" +
          jsonEscape(firmwareStatus.target) + "\",\"version\":\"" +
          jsonEscape(firmwareStatus.runningVersion) + "\",\"build\":" +
          std::to_string(firmwareStatus.runningBuild) +
          ",\"gitSha\":\"" + jsonEscape(firmwareStatus.runningGitSha) + "\"" +
          ",\"updaterProtocol\":" +
          std::to_string(firmware_metadata::kUpdaterProtocolVersion) +
          ",\"receivedBytes\":" +
          std::to_string(firmwareStatus.receivedBytes) +
          ",\"totalBytes\":" + std::to_string(firmwareStatus.totalBytes);
  if (!firmwareStatus.errorCode.empty()) {
    body += ",\"lastError\":{\"code\":\"" +
            jsonEscape(firmwareStatus.errorCode) + "\",\"message\":\"" +
            jsonEscape(firmwareStatus.errorMessage) + "\"}";
  }
  body += "}}";
  return body;
}

static void notifyMapTransferStatus(NimBLECharacteristic *pChar) {
  if (pChar == nullptr) {
    pChar = mapTransferStatusCharacteristic;
  }
  if (pChar == nullptr) {
    return;
  }

  // Notifications must fit even when the central keeps the minimum ATT MTU
  // (23 bytes, 20-byte value). Frame the JSON into independently valid chunks
  // instead of relying on the requested 512-byte MTU being negotiated.
  constexpr size_t kChunkBytes = 13;
  static uint8_t transferId = 0;
  const std::string body = mapTransferStatusJson();
  const std::string legacy = "MSTS" + body;
  uint16_t peerMtu = 23;
  NimBLEService *service = pChar->getService();
  NimBLEServer *server = service == nullptr ? nullptr : service->getServer();
  if (server != nullptr && activeConnHandle != BLE_HS_CONN_HANDLE_NONE) {
    peerMtu = server->getPeerMTU(activeConnHandle);
  }
  if (peerMtu >= 25 && legacy.size() <= peerMtu - 25 &&
      notifyAuthenticatedNavigation(
          pChar, reinterpret_cast<const uint8_t *>(legacy.data()),
          legacy.size())) {
    Serial.printf("BLE Map Transfer: status notified (%u bytes, MTU %u)\n",
                  (unsigned)legacy.size(), (unsigned)peerMtu);
    return;
  }
  const size_t chunkCount = (body.size() + kChunkBytes - 1) / kChunkBytes;
  if (chunkCount == 0 || chunkCount > 255) {
    Serial.printf("BLE Map Transfer: status too large (%u bytes)\n",
                  (unsigned)body.size());
    return;
  }
  transferId++;
  for (size_t index = 0; index < chunkCount; index++) {
    const size_t offset = index * kChunkBytes;
    const size_t length = std::min(kChunkBytes, body.size() - offset);
    std::string frame = "MSTC";
    frame.push_back(static_cast<char>(transferId));
    frame.push_back(static_cast<char>(index));
    frame.push_back(static_cast<char>(chunkCount));
    frame.append(body.data() + offset, length);
    if (!notifyAuthenticatedNavigation(
            pChar, reinterpret_cast<const uint8_t *>(frame.data()),
            frame.size())) {
      Serial.println("BLE Map Transfer: protected status chunk failed");
      return;
    }
    delay(2);
  }
  Serial.printf("BLE Map Transfer: status notified (%u bytes, %u chunks)\n",
                (unsigned)body.size(), (unsigned)chunkCount);
}

static void notifyGenericTransferStatus(NimBLECharacteristic *pChar) {
  if (pChar == nullptr) {
    pChar = mapTransferStatusCharacteristic;
  }
  if (pChar == nullptr) {
    return;
  }

  constexpr size_t kChunkBytes = 128;
  static uint8_t transferId = 0;
  const std::string body = genericTransferStatusJson();
  const std::string response = "DSTS" + body;
  if (notifyAuthenticatedNavigation(
          pChar, reinterpret_cast<const uint8_t *>(response.data()),
          response.size())) {
    Serial.printf("BLE Device Transfer: status notified (%u bytes)\n",
                  static_cast<unsigned>(response.size()));
    return;
  }
  const size_t chunkCount = (body.size() + kChunkBytes - 1) / kChunkBytes;
  if (chunkCount == 0 || chunkCount > 255) {
    Serial.printf("BLE Device Transfer: status too large (%u bytes)\n",
                  static_cast<unsigned>(body.size()));
    return;
  }
  transferId++;
  for (size_t index = 0; index < chunkCount; index++) {
    const size_t offset = index * kChunkBytes;
    const size_t chunkLength = std::min(kChunkBytes, body.size() - offset);
    std::string chunk = "DSTC";
    chunk.push_back(static_cast<char>(transferId));
    chunk.push_back(static_cast<char>(index));
    chunk.push_back(static_cast<char>(chunkCount));
    chunk.append(body.data() + offset, chunkLength);
    if (!notifyAuthenticatedNavigation(
            pChar, reinterpret_cast<const uint8_t *>(chunk.data()),
            chunk.size())) {
      Serial.println("BLE Device Transfer: protected status chunk failed");
      return;
    }
    delay(2);
  }
}

static void queueTransferControl(ble_transfer::Action action,
                                 uint8_t notifications) {
  pendingTransferControl.merge(action, notifications);
}

static void processPendingTransferControl() {
  const ble_transfer::Request request = pendingTransferControl.take();
  if (request.empty()) {
    return;
  }

  switch (request.action) {
  case ble_transfer::Action::EnableMap: {
    const device_transfer::HttpTransferStatus transferStatus =
        deviceTransferHttp.status();
    if (transferStatus.enabled && !transferStatus.mode.empty() &&
        transferStatus.mode != "map") {
      mapTransferHttp.setLastError("transfer_busy",
                                   "another transfer mode is active");
      Serial.println("BLE Map Transfer: enter rejected, transfer is busy");
    } else if (transferStatus.enabled && transferStatus.mode == "map") {
      Serial.println("BLE Map Transfer: enter already applied");
    } else if (mapTransferHttp.activationSnapshot().running) {
      mapTransferHttp.setLastError(
          "activation_busy", "map activation is still using map storage");
      Serial.println(
          "BLE Map Transfer: enter rejected, activation is still running");
    } else if (!deviceTransferHttp.waitUntilStopped(2000)) {
      mapTransferHttp.setLastError(
          "transfer_stopping", "previous transfer work is still stopping");
      Serial.println(
          "BLE Map Transfer: enter rejected, transfer worker is stopping");
    } else if (!storage.ensureSdMounted()) {
      mapTransferHttp.setLastError("sd_unavailable",
                                   "SD card is not mounted");
      Serial.println(
          "BLE Map Transfer: enter rejected, SD card is not mounted");
    } else if (!mapTransferHttp.refreshStreamStorageCapability(true)) {
      storage.markSdUnavailable();
      mapTransferHttp.setLastError(
          "sd_unwritable", "SD card map storage is not writable");
      Serial.println(
          "BLE Map Transfer: enter rejected, SD card is not writable");
    } else {
      const bool enabled = mapTransferHttp.setEnabled(true);
      Serial.printf("BLE Map Transfer: enter applied, enabled=%d\n", enabled);
    }
    break;
  }
  case ble_transfer::Action::EnableFirmware: {
    const device_transfer::HttpTransferStatus transferStatus =
        deviceTransferHttp.status();
    if (transferStatus.enabled && !transferStatus.mode.empty() &&
        transferStatus.mode != "firmware") {
      firmwareUpdateHttp.setLastError("transfer_busy",
                                      "another transfer mode is active");
      Serial.println(
          "BLE Device Transfer: firmware enter rejected, transfer is busy");
    } else {
      const bool enabled = firmwareUpdateHttp.setEnabled(true);
      Serial.printf(
          "BLE Device Transfer: firmware enter applied, enabled=%d\n",
          enabled);
    }
    break;
  }
  case ble_transfer::Action::DisableMap: {
    bool disabled = true;
    if (deviceTransferHttp.status().mode == "map") {
      disabled = mapTransferHttp.setEnabled(false);
    }
    Serial.printf("BLE Map Transfer: exit applied, disabled=%d\n", disabled);
    break;
  }
  case ble_transfer::Action::DisableAll: {
    const bool disabled = deviceTransferHttp.setEnabled(false);
    Serial.printf("BLE Device Transfer: exit applied, disabled=%d\n",
                  disabled);
    break;
  }
  case ble_transfer::Action::None:
    break;
  }

  if (request.notifications & ble_transfer::NotifyMap) {
    notifyMapTransferStatus(mapTransferStatusCharacteristic);
  }
  if (request.notifications & ble_transfer::NotifyGeneric) {
    notifyGenericTransferStatus(mapTransferStatusCharacteristic);
  }
}

static void notifyDeviceCapabilities(NimBLECharacteristic *pChar,
                                     bool includePowerButtonConfig) {
  if (pChar == nullptr) {
    pChar = mapTransferStatusCharacteristic;
  }
  if (pChar == nullptr) {
    return;
  }

  const bool speakerAvailable = waveshare_board::speaker::isAvailable();
  const bool powerButtonHonkAvailable =
      waveshare_board::speaker::isPowerButtonHonkAvailable();
  uint8_t response[8] = {
      'C', 'A', 'P', 'S',
      static_cast<uint8_t>(
          waveshare_board::speaker::capabilityFlags(
              speakerAvailable, powerButtonHonkAvailable,
              powerButtonHonkAvailable) |
          map_profile_protocol::CAPABILITY_MASK |
          CAPABILITY_EXTENDED_MAP_VISIBILITY |
          CAPABILITY_BATTERY_STATUS_SCREEN |
          destination_picker_protocol::CAPABILITY_MASK),
  };
  size_t responseSize = 5;
  waveshare_board::speaker::PowerButtonHonkConfig config{};
  if (includePowerButtonConfig && powerButtonHonkAvailable) {
    if (!waveshare_board::speaker::getPowerButtonHonkConfig(config) ||
        !waveshare_board::speaker::encodePowerButtonHonkPayload(
            config, response + responseSize,
            waveshare_board::speaker::POWER_BUTTON_HONK_PAYLOAD_SIZE)) {
      Serial.println("BLE Capabilities: PWR config unavailable; retry required");
      return;
    }
    responseSize += waveshare_board::speaker::POWER_BUTTON_HONK_PAYLOAD_SIZE;
  }
  if (!notifyAuthenticatedNavigation(pChar, response, responseSize)) {
    Serial.println("BLE Capabilities: protected notification failed");
    return;
  }
  Serial.printf("BLE Capabilities: notified flags=0x%02X config=%d\n",
                response[4], responseSize > 5 ? 1 : 0);
}

static void notifyPowerButtonHonkStatus(
    NimBLECharacteristic *pChar,
    const waveshare_board::speaker::PowerButtonHonkCommand &command,
    bool applied) {
  if (pChar == nullptr) {
    pChar = mapTransferStatusCharacteristic;
  }
  if (pChar == nullptr) {
    return;
  }

  uint8_t response[waveshare_board::speaker::POWER_BUTTON_HONK_STATUS_SIZE]{};
  const size_t responseSize =
      waveshare_board::speaker::powerButtonHonkStatusSize(command);
  if (!waveshare_board::speaker::encodePowerButtonHonkStatus(
          command, applied, response, responseSize)) {
    return;
  }
  if (!notifyAuthenticatedNavigation(pChar, response, responseSize)) {
    Serial.println("BLE Sound: protected PWR status notification failed");
    return;
  }
  Serial.printf("BLE Sound: PWR honk apply status notified success=%d\n",
                applied ? 1 : 0);
}

static bool handleDeviceCapabilitiesCommand(const std::string &value,
                                            NimBLECharacteristic *pChar,
                                            const char *authLabel) {
  if (!hasPrefix(value, "CAPS")) {
    return false;
  }
  if (requireAuthenticated(authLabel)) {
    const uint8_t clientVersion =
        value.length() == 5 ? static_cast<uint8_t>(value[4]) : 0;
    const bool includePowerButtonConfig =
        clientVersion >= 1;
    notifyDeviceCapabilities(pChar, includePowerButtonConfig);
  }
  return true;
}

static bool commitDestinationCatalog(const std::string &json) {
  JsonDocument document;
  const DeserializationError error = deserializeJson(document, json);
  if (error) {
    Serial.printf("BLE Destination: rejected catalog JSON: %s\n",
                  error.c_str());
    return false;
  }
  if (!document["version"].is<uint8_t>() ||
      document["version"].as<uint8_t>() !=
          destination_picker_protocol::CATALOG_VERSION ||
      !document["generation"].is<uint32_t>() ||
      document["generation"].as<uint32_t>() == 0 ||
      !document["items"].is<JsonArrayConst>()) {
    Serial.println("BLE Destination: rejected catalog envelope");
    return false;
  }

  const JsonArrayConst items = document["items"].as<JsonArrayConst>();
  if (items.size() > destination_picker_protocol::MAX_ITEMS) {
    Serial.println("BLE Destination: rejected oversized catalog");
    return false;
  }

  DestinationCatalogSnapshot candidate{};
  candidate.generation = document["generation"].as<uint32_t>();
  bool sawRecent = false;
  uint8_t favoriteCount = 0;
  uint8_t recentCount = 0;
  for (JsonVariantConst entryVariant : items) {
    if (!entryVariant.is<JsonObjectConst>()) {
      Serial.println("BLE Destination: rejected non-object item");
      return false;
    }
    const JsonObjectConst entry = entryVariant.as<JsonObjectConst>();
    if (!entry["token"].is<uint16_t>() ||
        !entry["kind"].is<const char *>() ||
        !entry["label"].is<const char *>()) {
      Serial.println("BLE Destination: rejected malformed item");
      return false;
    }

    DeviceDestination item{};
    item.token = entry["token"].as<uint16_t>();
    const JsonString kindString = entry["kind"].as<JsonString>();
    const JsonString labelString = entry["label"].as<JsonString>();
    const char *kind = kindString.c_str();
    const char *label = labelString.c_str();
    const size_t labelLength = labelString.size();
    if (item.token == 0 || labelLength == 0 ||
        labelLength > destination_picker_protocol::MAX_LABEL_BYTES ||
        memchr(label, '\0', labelLength) != nullptr ||
        !destination_picker_protocol::isValidUtf8(label, labelLength)) {
      Serial.println("BLE Destination: rejected invalid token or label");
      return false;
    }
    for (uint8_t i = 0; i < candidate.count; i++) {
      if (candidate.items[i].token == item.token) {
        Serial.println("BLE Destination: rejected duplicate token");
        return false;
      }
    }

    if (kindString.size() == 8 && memcmp(kind, "favorite", 8) == 0) {
      if (sawRecent || ++favoriteCount >
                           destination_picker_protocol::MAX_FAVORITES) {
        Serial.println("BLE Destination: rejected favorite ordering/count");
        return false;
      }
      item.kind = DestinationKind::Favorite;
    } else if (kindString.size() == 6 && memcmp(kind, "recent", 6) == 0) {
      sawRecent = true;
      if (++recentCount > destination_picker_protocol::MAX_RECENTS) {
        Serial.println("BLE Destination: rejected recent count");
        return false;
      }
      item.kind = DestinationKind::Recent;
    } else {
      Serial.println("BLE Destination: rejected unknown item kind");
      return false;
    }
    memcpy(item.label, label, labelLength);
    item.label[labelLength] = '\0';
    candidate.items[candidate.count++] = item;
  }

  portENTER_CRITICAL(&destinationPickerMux);
  candidate.revision = destinationCatalog.revision + 1;
  destinationCatalog = candidate;
  portEXIT_CRITICAL(&destinationPickerMux);
  Serial.printf("BLE Destination: committed generation=%lu items=%u\n",
                (unsigned long)candidate.generation, candidate.count);
  return true;
}

static bool handleDestinationPickerPayload(const std::string &value,
                                           const char *authLabel) {
  if (hasPrefix(value, "DLST")) {
    if (!requireAuthenticated(authLabel)) {
      return true;
    }
    if (destinationCatalogReassemblerMutex == nullptr ||
        xSemaphoreTake(destinationCatalogReassemblerMutex,
                       pdMS_TO_TICKS(100)) != pdTRUE) {
      Serial.println("BLE Destination: catalog reassembler unavailable");
      return true;
    }
    const auto result = destinationCatalogReassembler.consume(
        reinterpret_cast<const uint8_t *>(value.data()), value.size(),
        millis());
    std::string catalogJson;
    if (result == destination_picker_protocol::ChunkResult::Complete) {
      catalogJson = destinationCatalogReassembler.payload();
      destinationCatalogReassembler.reset();
    }
    xSemaphoreGive(destinationCatalogReassemblerMutex);
    if (result == destination_picker_protocol::ChunkResult::Rejected) {
      Serial.println("BLE Destination: rejected catalog chunk");
      return true;
    }
    if (result == destination_picker_protocol::ChunkResult::Complete) {
      (void)commitDestinationCatalog(catalogJson);
    }
    return true;
  }

  if (!hasPrefix(value, "DNST")) {
    return false;
  }
  if (!requireAuthenticated(authLabel)) {
    return true;
  }
  if (value.size() < 11) {
    Serial.println("BLE Destination: rejected short status");
    return true;
  }
  const uint8_t *data = reinterpret_cast<const uint8_t *>(value.data());
  const uint32_t generation =
      destination_picker_protocol::readUInt32LE(data + 4);
  const uint16_t token = destination_picker_protocol::readUInt16LE(data + 8);
  const auto code = static_cast<DestinationPickerStatusCode>(data[10]);
  if (code < DestinationPickerStatusCode::Calculating ||
      code > DestinationPickerStatusCode::Stale) {
    Serial.println("BLE Destination: rejected unknown status");
    return true;
  }

  std::string message = value.substr(11);
  if (message.size() > destination_picker_protocol::MAX_LABEL_BYTES ||
      !destination_picker_protocol::isValidUtf8(message.data(),
                                                message.size())) {
    Serial.println("BLE Destination: rejected oversized status message");
    return true;
  }
  if (message.empty()) {
    switch (code) {
    case DestinationPickerStatusCode::Calculating:
      message = "Starting navigation...";
      break;
    case DestinationPickerStatusCode::Started:
      message = "Navigation started";
      break;
    case DestinationPickerStatusCode::Stale:
      message = "Destination list changed";
      break;
    case DestinationPickerStatusCode::Failed:
    default:
      message = "Could not start navigation";
      break;
    }
  }
  if (!applyDestinationResponseIfPending(code, generation, token,
                                         message.c_str())) {
    Serial.println("BLE Destination: ignored status for inactive request");
    return true;
  }
  Serial.printf("BLE Destination: status=%u generation=%lu token=%u\n",
                static_cast<unsigned>(code), (unsigned long)generation, token);
  return true;
}

static void handleMapTransferControlPayload(const uint8_t *data, size_t len,
                                            NimBLECharacteristic *) {
  std::string command;
  if (data != nullptr && len > 0) {
    command.assign(reinterpret_cast<const char *>(data), len);
    command = trimAscii(command);
  }

  if (command == "enter") {
    queueTransferControl(ble_transfer::Action::EnableMap,
                         ble_transfer::NotifyMap);
    Serial.println("BLE Map Transfer: enter queued");
    return;
  }

  if (command == "exit") {
    queueTransferControl(ble_transfer::Action::DisableMap,
                         ble_transfer::NotifyMap);
    Serial.println("BLE Map Transfer: exit queued");
    return;
  }

  Serial.printf("BLE Map Transfer: rejected unknown command '%s'\n",
                command.c_str());
  queueTransferControl(ble_transfer::Action::None,
                       ble_transfer::NotifyMap);
}

static void handleGenericTransferControlPayload(const uint8_t *data, size_t len,
                                                NimBLECharacteristic *) {
  std::string command;
  if (data != nullptr && len > 0) {
    command.assign(reinterpret_cast<const char *>(data), len);
    command = trimAscii(command);
  }

  if (command == "enter|map") {
    queueTransferControl(ble_transfer::Action::EnableMap,
                         ble_transfer::NotifyMap |
                             ble_transfer::NotifyGeneric);
    Serial.println("BLE Device Transfer: map enter queued");
    return;
  }

  if (command == "enter|firmware") {
    queueTransferControl(ble_transfer::Action::EnableFirmware,
                         ble_transfer::NotifyGeneric);
    Serial.println("BLE Device Transfer: firmware enter queued");
    return;
  }

  if (command == "exit") {
    queueTransferControl(ble_transfer::Action::DisableAll,
                         ble_transfer::NotifyMap |
                             ble_transfer::NotifyGeneric);
    Serial.println("BLE Device Transfer: exit queued");
    return;
  }

  Serial.printf("BLE Device Transfer: rejected unknown command '%s'\n",
                command.c_str());
  queueTransferControl(ble_transfer::Action::None,
                       ble_transfer::NotifyGeneric);
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
    clearCurrentNavigationData();
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
  if (map_profile_protocol::isIndependentSetting(settingId)) {
    bleSessionUsesIndependentMapProfiles = true;
  }
  const bool mirrorLegacyMapProfile =
      map_profile_protocol::shouldMirrorLegacySetting(
          settingId, bleSessionUsesIndependentMapProfiles);
  const auto persistMapProfileSetting = [&]() {
    settingsPrefs.begin("mapSettings", false);
    map_profile_persistence::persistSetting(
        settingsPrefs, mapRenderSettings.mapStyle,
        mapRenderSettings.mapNavigationStyle,
        mapRenderSettings.navigationOverlayVisibilityMask, settingId,
        mirrorLegacyMapProfile);
    settingsPrefs.end();
  };

  switch (settingId) {
  case 1:
    mapRenderSettings.mapStyle.minPolygonSize =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.minPolygonSize =
          mapRenderSettings.mapStyle.minPolygonSize;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: minPolygonSize = %d (saved)\n",
                  mapRenderSettings.mapStyle.minPolygonSize);
    break;
  case 2:
    mapRenderSettings.mapStyle.detailLevel =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.detailLevel =
          mapRenderSettings.mapStyle.detailLevel;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: detailLevel = %d (saved)\n",
                  mapRenderSettings.mapStyle.detailLevel);
    break;
  case 3:
    mapRenderSettings.mapStyle.routeLineWidth =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.routeLineWidth =
          mapRenderSettings.mapStyle.routeLineWidth;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: routeLineWidth = %d (saved)\n",
                  mapRenderSettings.mapStyle.routeLineWidth);
    break;
  case 9:
    mapRenderSettings.mapStyle.streetLineWidthBoost =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.streetLineWidthBoost =
          mapRenderSettings.mapStyle.streetLineWidthBoost;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: streetLineWidthBoost = %d (saved)\n",
                  mapRenderSettings.mapStyle.streetLineWidthBoost);
    break;
  case 10:
    mapRenderSettings.mapStyle.positionMarkerScale =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.positionMarkerScale =
          mapRenderSettings.mapStyle.positionMarkerScale;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: positionMarkerScale = %d (saved)\n",
                  mapRenderSettings.mapStyle.positionMarkerScale);
    break;
  case 11:
    mapRenderSettings.tapToSwitchScreens = settingValue != 0 ? 1 : 0;
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("tapSwitch", mapRenderSettings.tapToSwitchScreens);
    settingsPrefs.end();
    Serial.printf("BLE Settings: tapToSwitchScreens = %d (saved)\n",
                  mapRenderSettings.tapToSwitchScreens);
    break;
  case 13: {
    settingValue = device_screen_protocol::applyCompatibility(
        settingValue, mapRenderSettings.enabledScreensMask);
    mapRenderSettings.enabledScreensMask =
        normalizedEnabledScreensMask(settingValue);
    mapRenderSettings.defaultScreen = normalizedDefaultScreen(
        mapRenderSettings.defaultScreen, mapRenderSettings.enabledScreensMask);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("screenMask", mapRenderSettings.enabledScreensMask);
    settingsPrefs.putUChar("defaultScreen", mapRenderSettings.defaultScreen);
    settingsPrefs.end();
    applyDeviceScreenSettings();
    Serial.printf("BLE Settings: enabledScreensMask = 0x%02X (saved)\n",
                  mapRenderSettings.enabledScreensMask);
    break;
  }
  case 14:
    mapRenderSettings.defaultScreen = normalizedDefaultScreen(
        settingValue, mapRenderSettings.enabledScreensMask);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUChar("defaultScreen", mapRenderSettings.defaultScreen);
    settingsPrefs.end();
    Serial.printf("BLE Settings: defaultScreen = %d (saved)\n",
                  mapRenderSettings.defaultScreen);
    break;
  case 15: {
    mapRenderSettings.disconnectedSleepTimeoutSeconds =
        normalizedDisconnectedSleepTimeoutSeconds(settingValue);
    settingsPrefs.begin("mapSettings", false);
    settingsPrefs.putUInt("discSleepSec",
                          mapRenderSettings.disconnectedSleepTimeoutSeconds);
    settingsPrefs.end();
    Serial.printf("BLE Settings: disconnectedSleepTimeoutSeconds = %lu "
                  "(saved, 0=never)\n",
                  (unsigned long)
                      mapRenderSettings.disconnectedSleepTimeoutSeconds);
    break;
  }
  case 4:
    Serial.println("BLE Settings: ignoring legacy displayRotation; rotation "
                   "is selected by the firmware target");
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
    mapRenderSettings.mapStyle.zoomLevel =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.zoomLevel =
          mapRenderSettings.mapStyle.zoomLevel;
    }
    if (isMapScreenActive()) {
      zoom = mapRenderSettings.mapStyle.zoomLevel;
    } else if (map_profile_protocol::shouldApplyMirroredZoomToMapNavigation(
                   mirrorLegacyMapProfile, isMapGuidanceScreenActive())) {
      zoom = mapRenderSettings.mapNavigationStyle.zoomLevel;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: zoomLevel = %d (saved)\n",
                  mapRenderSettings.mapStyle.zoomLevel);
    break;
  }
  case 8: {
    const uint32_t mask = (uint32_t)settingValue;
    mapRenderSettings.mapStyle.visibilityMask =
        normalizedMapFeatureVisibilityMask(mask);
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.visibilityMask =
          mapRenderSettings.mapStyle.visibilityMask;
    }
    mapRenderSettings.navigationOverlayVisibilityMask =
        mask & MAP_VISIBILITY_OVERLAY_MASK;
    persistMapProfileSetting();
    Serial.printf("BLE Settings: visibilityMask = 0x%08X (saved)\n",
                  mask);
    break;
  }
  case 16:
    mapRenderSettings.mapNavigationStyle.minPolygonSize =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    persistMapProfileSetting();
    break;
  case 17:
    mapRenderSettings.mapNavigationStyle.detailLevel =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    persistMapProfileSetting();
    break;
  case 18:
    mapRenderSettings.mapNavigationStyle.routeLineWidth =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    persistMapProfileSetting();
    break;
  case 19:
    mapRenderSettings.mapNavigationStyle.zoomLevel =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    if (isMapGuidanceScreenActive()) {
      extern uint8_t zoom;
      zoom = mapRenderSettings.mapNavigationStyle.zoomLevel;
    }
    persistMapProfileSetting();
    break;
  case 20:
    mapRenderSettings.mapNavigationStyle.visibilityMask =
        normalizedMapFeatureVisibilityMask((uint32_t)settingValue);
    persistMapProfileSetting();
    break;
  case 21:
    mapRenderSettings.mapNavigationStyle.streetLineWidthBoost =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    persistMapProfileSetting();
    break;
  case 22:
    mapRenderSettings.mapNavigationStyle.positionMarkerScale =
        (uint8_t)map_profile_protocol::clampValue(settingId, settingValue);
    persistMapProfileSetting();
    break;
  case 23:
    if (settingValue < 0 || settingValue > 100) {
      Serial.printf("BLE Settings: rejected phone battery level %ld from %s\n",
                    (long)settingValue,
                    source == nullptr ? "unknown" : source);
      return;
    }
    phoneBatteryLevelPercent = static_cast<int16_t>(settingValue);
    Serial.printf("BLE Settings: phoneBatteryLevel = %d%%\n",
                  phoneBatteryLevelPercent);
    return;
  case 24:
    if (settingValue < 0 || settingValue > 1) {
      Serial.printf("BLE Settings: rejected phone charging state %ld from %s\n",
                    (long)settingValue,
                    source == nullptr ? "unknown" : source);
      return;
    }
    phoneBatteryCharging = settingValue == 1;
    Serial.printf("BLE Settings: phoneBatteryCharging = %s\n",
                  phoneBatteryCharging ? "yes" : "no");
    return;
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

static bool resetOwnershipConnectionState() {
  if (!deviceOwnershipReady) {
    return true;
  }
  if (deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, portMAX_DELAY) != pdTRUE) {
    return false;
  }
  deviceOwnership.resetConnection();
  ownershipPairingActiveSnapshot = false;
  xSemaphoreGive(deviceOwnershipMutex);
  return true;
}

class MyBLEServerCallbacks : public NimBLEServerCallbacks {
public:
  BLENavigationServer *server;

  MyBLEServerCallbacks(BLENavigationServer *srv) : server(srv) {}

  void onConnect(NimBLEServer *pServer) override {
    // NimBLE-Arduino 1.4 invokes both overloads for the same event. The
    // descriptor overload below is the only one allowed to mutate state.
    (void)pServer;
  }

  void onConnect(NimBLEServer *pServer, ble_gap_conn_desc *desc) override {
    if (desc == nullptr) {
      Serial.println("BLE: Rejected connection without a handle");
      return;
    }
    if (activeConnHandle == desc->conn_handle && server->connected) {
      Serial.printf("BLE: Ignoring duplicate connection callback handle=%u\n",
                    desc->conn_handle);
      return;
    }
    if (!ble_connection_policy::beginSession(
            activeConnHandle, desc->conn_handle,
            [] { return resetOwnershipConnectionState(); })) {
      Serial.printf("BLE: Rejecting connection handle=%u (busy or ownership reset unavailable)\n",
                    desc->conn_handle);
      pServer->disconnect(desc->conn_handle);
      return;
    }
    acceptConnection();
  }

  void acceptConnection() {
    server->connected = true;
    bleSessionAuthenticated = false;
    bleSessionUsesIndependentMapProfiles = false;
    phoneBatteryLevelPercent = -1;
    phoneBatteryCharging = false;
    unauthTimeoutDisconnectRequested = false;
    ownershipDisconnectPending = false;
    bleDebugStats.connected = true;
    bleDebugStats.authenticated = false;
    bleDebugStats.connectCount++;
    bleDebugStats.lastConnectMs = millis();
    pendingAuthNonce[0] = '\0';
    if (deviceOwnershipReady) {
      queueOwnershipUiUpdate();
    }
    if (destinationCatalogReassemblerMutex != nullptr &&
        xSemaphoreTake(destinationCatalogReassemblerMutex,
                       pdMS_TO_TICKS(100)) == pdTRUE) {
      destinationCatalogReassembler.reset();
      xSemaphoreGive(destinationCatalogReassemblerMutex);
    }
    Serial.println("BLE: iOS client connected!");
    // Stop advertising when connected
    NimBLEDevice::stopAdvertising();
  }

  void onDisconnect(NimBLEServer *pServer,
                    ble_gap_conn_desc *desc) override {
    if (desc == nullptr || !ble_connection_policy::endSession(
                               activeConnHandle, desc->conn_handle,
                               [] { return resetOwnershipConnectionState(); })) {
      Serial.printf("BLE: Secondary connection handle=%u disconnected\n",
                    desc == nullptr ? BLE_HS_CONN_HANDLE_NONE
                                    : desc->conn_handle);
      return;
    }
    disconnectActive();
  }

  void onDisconnect(NimBLEServer *pServer) override {
    // See onConnect(NimBLEServer*): the pinned NimBLE version invokes both.
    (void)pServer;
  }

  void disconnectActive() {
    if (activeConnHandle == BLE_HS_CONN_HANDLE_NONE && !server->connected) {
      return;
    }
    queueTransferControl(ble_transfer::Action::DisableMap,
                         ble_transfer::NotifyNone);
    server->connected = false;
    bleSessionAuthenticated = false;
    bleSessionUsesIndependentMapProfiles = false;
    phoneBatteryLevelPercent = -1;
    phoneBatteryCharging = false;
    unauthTimeoutDisconnectRequested = false;
    ownershipDisconnectPending = false;
    bleDebugStats.connected = false;
    bleDebugStats.authenticated = false;
    bleDebugStats.disconnectCount++;
    bleDebugStats.lastDisconnectMs = millis();
    pendingAuthNonce[0] = '\0';
    if (deviceOwnershipReady) {
      if (ownershipAdvertisingDirty) {
        applyOwnershipAdvertisingData();
      }
      queueOwnershipUiUpdate();
    }
    if (finishDestinationRequestIfPending()) {
      const DestinationPickerStatusSnapshot status =
          getDestinationPickerStatusSnapshot();
      setDestinationPickerStatus(DestinationPickerStatusCode::Failed,
                                 status.generation, status.token,
                                 "Open app to start navigation");
    }
    Serial.println("BLE: iOS client disconnected");
    // Restart advertising
    Serial.println("BLE: Restarting advertising...");
    NimBLEDevice::startAdvertising();
  }
};

class MyNavCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    const std::string frame = pChar->getValue();
    if (frame.empty()) {
      return;
    }
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Navigation, frame, value,
            "navigation characteristic")) {
      return;
    }

    if (handleDestinationPickerPayload(value, "destination picker")) {
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

    if (hasPrefix(value, "MTRN")) {
      if (!requireAuthenticated("map transfer control")) {
        return;
      }
      handleMapTransferControlPayload((const uint8_t *)value.data() + 4,
                                      value.length() - 4, pChar);
      return;
    }

    if (hasPrefix(value, "MSTS")) {
      if (!requireAuthenticated("map transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyMap);
      return;
    }

    if (hasPrefix(value, "DTRN")) {
      if (!requireAuthenticated("device transfer control")) {
        return;
      }
      handleGenericTransferControlPayload((const uint8_t *)value.data() + 4,
                                          value.length() - 4, pChar);
      return;
    }

    if (handleDeviceCapabilitiesCommand(value, pChar,
                                        "device capabilities")) {
      return;
    }

    if (hasPrefix(value, "DSTS")) {
      if (!requireAuthenticated("device transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
      return;
    }

    if (handleSoundPlayCommand(value, "sound playback", "fallback")) {
      return;
    }

    if (handlePowerButtonHonkCommand(value, "PWR honk configuration",
                                     "fallback", pChar)) {
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
    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Route, frame, value,
            "route characteristic")) {
      return;
    }
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
    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Gps, frame, value,
            "GPS characteristic")) {
      return;
    }
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
    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Settings, frame, value,
            "settings characteristic")) {
      return;
    }

    if (handleDestinationPickerPayload(value, "native destination picker")) {
      return;
    }

    if (hasPrefix(value, "MTRN")) {
      if (!requireAuthenticated("native map transfer control")) {
        return;
      }
      handleMapTransferControlPayload((const uint8_t *)value.data() + 4,
                                      value.length() - 4,
                                      mapTransferStatusCharacteristic);
      return;
    }

    if (hasPrefix(value, "MSTS")) {
      if (!requireAuthenticated("native map transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyMap);
      return;
    }

    if (hasPrefix(value, "DTRN")) {
      if (!requireAuthenticated("native device transfer control")) {
        return;
      }
      handleGenericTransferControlPayload((const uint8_t *)value.data() + 4,
                                          value.length() - 4,
                                          mapTransferStatusCharacteristic);
      return;
    }

    if (handleDeviceCapabilitiesCommand(value,
                                        mapTransferStatusCharacteristic,
                                        "native device capabilities")) {
      return;
    }

    if (hasPrefix(value, "DSTS")) {
      if (!requireAuthenticated("native device transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
      return;
    }

    if (handleSoundPlayCommand(value, "native sound playback", "native")) {
      return;
    }

    if (handlePowerButtonHonkCommand(value, "native PWR honk configuration",
                                     "native",
                                     mapTransferStatusCharacteristic)) {
      return;
    }

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
  prefs.begin("mapSettings", false);

  map_profile_persistence::load(prefs, mapRenderSettings.mapStyle,
                                mapRenderSettings.mapNavigationStyle);
  mapRenderSettings.mapRotationMode = prefs.getUChar("mapRotMode", 0);
  mapRenderSettings.tapToSwitchScreens = prefs.getUChar("tapSwitch", 0);
  uint8_t storedScreenMask =
      prefs.getUChar("screenMask", DEVICE_SCREEN_SUPPORTED_MASK);
  if (!prefs.getBool("batteryScrV1", false)) {
    storedScreenMask |= deviceScreenBit(DEVICE_SCREEN_BATTERY_STATUS);
    prefs.putUChar("screenMask", storedScreenMask);
    prefs.putBool("batteryScrV1", true);
  }
  mapRenderSettings.enabledScreensMask =
      normalizedEnabledScreensMask(storedScreenMask);
  mapRenderSettings.defaultScreen = normalizedDefaultScreen(
      prefs.getUChar("defaultScreen", DEVICE_SCREEN_MAP_PLUS_NAVIGATION),
      mapRenderSettings.enabledScreensMask);
  mapRenderSettings.disconnectedSleepTimeoutSeconds =
      normalizedDisconnectedSleepTimeoutSeconds(
          prefs.getUInt("discSleepSec", 120));
  const uint32_t storedVisibilityMask = prefs.getUInt("visMask", 0x3FF);
  mapRenderSettings.navigationOverlayVisibilityMask =
      storedVisibilityMask & MAP_VISIBILITY_OVERLAY_MASK;

  prefs.end();

  Serial.printf("BLE: Loaded settings from NVS - minPolySize=%d, "
                "detailLevel=%d, routeWidth=%d, streetBoost=%d, "
                "markerScale=%d, tapSwitch=%d, "
                "screenMask=0x%02X, defaultScreen=%d, discSleepSec=%lu\n",
                mapRenderSettings.mapStyle.minPolygonSize,
                mapRenderSettings.mapStyle.detailLevel,
                mapRenderSettings.mapStyle.routeLineWidth,
                mapRenderSettings.mapStyle.streetLineWidthBoost,
                mapRenderSettings.mapStyle.positionMarkerScale,
                mapRenderSettings.tapToSwitchScreens,
                mapRenderSettings.enabledScreensMask,
                mapRenderSettings.defaultScreen,
                (unsigned long)
                    mapRenderSettings.disconnectedSleepTimeoutSeconds);
}

void BLENavigationServer::init(const char *deviceName) {
  if (initialized) {
    Serial.println("BLE: Already initialized");
    return;
  }

  // Load persisted settings from NVS
  loadSettingsFromNVS();

  Serial.println("BLE: Initializing NimBLE server...");

  if (destinationCatalogReassemblerMutex == nullptr) {
    destinationCatalogReassemblerMutex = xSemaphoreCreateMutexStatic(
        &destinationCatalogReassemblerMutexStorage);
  }

  if (deviceOwnershipMutex == nullptr) {
    deviceOwnershipMutex =
        xSemaphoreCreateMutexStatic(&deviceOwnershipMutexStorage);
  }

  if (notificationTransportMutex == nullptr) {
    notificationTransportMutex =
        xSemaphoreCreateMutexStatic(&notificationTransportMutexStorage);
  }

  deviceOwnershipReady = deviceOwnershipMutex != nullptr &&
                         notificationTransportMutex != nullptr &&
                         xSemaphoreTake(deviceOwnershipMutex,
                                        pdMS_TO_TICKS(250)) == pdTRUE;
  std::string effectiveDeviceName = deviceName;
  std::string stableDeviceId;
  bool ownershipClaimed = true;
  std::vector<uint8_t> manufacturerData;
  if (deviceOwnershipReady) {
    deviceOwnershipReady = deviceOwnership.begin();
    if (deviceOwnershipReady) {
      effectiveDeviceName = deviceOwnership.advertisedName();
      stableDeviceId = deviceOwnership.deviceIdHex();
      ownershipClaimed = deviceOwnership.isClaimed();
      manufacturerData = deviceOwnership.advertisementManufacturerData();
    }
    xSemaphoreGive(deviceOwnershipMutex);
  }
  if (deviceOwnershipReady) {
    Serial.printf("BLE: Ownership identity=%s claimed=%d name='%s'\n",
                  stableDeviceId.c_str(), ownershipClaimed,
                  effectiveDeviceName.c_str());
    queueOwnershipUiUpdate();
  } else {
    portENTER_CRITICAL(&ownershipUiMux);
    ownershipUiClaimed = true;
    portEXIT_CRITICAL(&ownershipUiMux);
    Serial.println("BLE: Ownership storage unavailable; authentication locked");
  }

  initBleIdentityAndSecurity(effectiveDeviceName.c_str());
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
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
          NIMBLE_PROPERTY::NOTIFY // Added NOTIFY support just in case
  );
  mapTransferStatusCharacteristic = pNavCharacteristic;
  pNavCharacteristic->setCallbacks(new MyNavCharacteristicCallbacks());

  // Create local auth characteristic required by the current iOS app before it
  // marks the device as navigation-ready.
  pAuthCharacteristic = pService->createCharacteristic(
      AUTH_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
          NIMBLE_PROPERTY::NOTIFY);
  pAuthCharacteristic->setCallbacks(new MyAuthCharacteristicCallbacks());
  pAuthCharacteristic->setValue("LOCKED");
  authCharacteristic = pAuthCharacteristic;

  pRouteCharacteristic = pService->createCharacteristic(
      ROUTE_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
          NIMBLE_PROPERTY::NOTIFY);
  pRouteCharacteristic->setCallbacks(new MyRouteCharacteristicCallbacks());

  // Create GPS Position Characteristic (UUID 2A72)
  NimBLECharacteristic *pGPSCharacteristic =
      pService->createCharacteristic(
          GPS_CHAR_UUID, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pGPSCharacteristic->setCallbacks(new MyGPSCharacteristicCallbacks());

  // Create Settings Characteristic (UUID 2A73) for runtime configuration
  NimBLECharacteristic *pSettingsCharacteristic =
      pService->createCharacteristic(
          SETTINGS_CHAR_UUID,
          NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pSettingsCharacteristic->setCallbacks(
      new MySettingsCharacteristicCallbacks());

  // Start service
  pService->start();

  // Start advertising
  NimBLEAdvertising *pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  if (deviceOwnershipReady) {
    pAdvertising->setName(effectiveDeviceName);
    pAdvertising->setManufacturerData(manufacturerData);
  }
  pAdvertising->setScanResponse(true);
  pAdvertising->start();

  initialized = true;
  bleDebugStats.initialized = true;
  bleDebugStats.connected = connected;
  bleDebugStats.authenticated = bleSessionAuthenticated;
  Serial.printf("BLE: Server started, advertising as '%s'\n",
                effectiveDeviceName.c_str());
}

void BLENavigationServer::process() {
  if (deviceOwnershipReady) {
    bool pairingExpired = false;
    if (deviceOwnershipMutex != nullptr &&
        xSemaphoreTake(deviceOwnershipMutex, 0) == pdTRUE) {
      const bool wasPairing = deviceOwnership.hasPairingCode();
      deviceOwnership.process(millis());
      ownershipPairingActiveSnapshot = deviceOwnership.hasPairingCode();
      pairingExpired = wasPairing && !ownershipPairingActiveSnapshot;
      xSemaphoreGive(deviceOwnershipMutex);
    }
    if (pairingExpired) {
      queueOwnershipUiUpdate();
    }
    applyPendingOwnershipUiUpdate();
  }
  if (ownershipRestartRequested &&
      static_cast<uint32_t>(millis() - ownershipRestartRequestedMs) >= 500) {
    Serial.println("BLE: Restarting after ownership removal");
    Serial.flush();
    ESP.restart();
  }
  processPendingTransferControl();
  const uint32_t nowMs = millis();
  if (destinationCatalogReassemblerMutex != nullptr &&
      xSemaphoreTake(destinationCatalogReassemblerMutex, 0) == pdTRUE) {
    const bool expired = destinationCatalogReassembler.expire(nowMs);
    xSemaphoreGive(destinationCatalogReassemblerMutex);
    if (expired) {
      Serial.println(
          "BLE Destination: discarded incomplete catalog after timeout");
    }
  }
  if (destinationRequestTimedOut(nowMs)) {
    const DestinationPickerStatusSnapshot status =
        getDestinationPickerStatusSnapshot();
    setDestinationPickerStatus(DestinationPickerStatusCode::Failed,
                               status.generation, status.token,
                               "Open app to start navigation");
  } else if (destinationStatusShouldExpire(nowMs)) {
    const DestinationPickerStatusSnapshot status =
        getDestinationPickerStatusSnapshot();
    setDestinationPickerStatus(DestinationPickerStatusCode::Idle,
                               status.generation, status.token, "");
  }

  static uint32_t lastLog = 0;
  if (deviceOwnershipReady && deviceOwnershipMutex != nullptr &&
      xSemaphoreTake(deviceOwnershipMutex, 0) == pdTRUE) {
    ownershipPairingActiveSnapshot = deviceOwnership.hasPairingCode();
    xSemaphoreGive(deviceOwnershipMutex);
  }
  const uint32_t unauthenticatedLimitMs =
      ownershipPairingActiveSnapshot ? 120000 : 12000;
  if (connected && ownershipDisconnectPending) {
    ownershipDisconnectPending = false;
    unauthTimeoutDisconnectRequested = true;
    if (pServer != nullptr && activeConnHandle != BLE_HS_CONN_HANDLE_NONE) {
      pServer->disconnect(activeConnHandle);
    }
  }
  if (connected && !bleSessionAuthenticated &&
      !unauthTimeoutDisconnectRequested &&
      millis() - bleDebugStats.lastConnectMs > unauthenticatedLimitMs) {
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

bool BLENavigationServer::forgetOwner() {
  bool cleared = false;
  if (deviceOwnershipReady && deviceOwnershipMutex != nullptr &&
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(250)) == pdTRUE) {
    cleared = deviceOwnership.isClaimed() && deviceOwnership.clearOwner();
    xSemaphoreGive(deviceOwnershipMutex);
  }
  if (!cleared) {
    return false;
  }
  bleSessionAuthenticated = false;
  bleDebugStats.authenticated = false;
  ownershipAdvertisingDirty = true;
  queueOwnershipUiUpdate();
  ownershipRestartRequested = true;
  ownershipRestartRequestedMs = millis();
  Serial.println("BLE: Owner cleared by physical recovery action");
  return true;
}

void BLENavigationServer::noteOwnershipDisplayFlushCompleted() {
  portENTER_CRITICAL(&ownershipUiMux);
  ownershipComparisonRenderGate.displayFlushed();
  portEXIT_CRITICAL(&ownershipUiMux);
}

bool BLENavigationServer::ownershipPairingRenderedRequest(
    uint32_t &pairingGeneration) {
  portENTER_CRITICAL(&ownershipUiMux);
  pairingGeneration = ownershipComparisonRenderGate.renderedGeneration();
  portEXIT_CRITICAL(&ownershipUiMux);
  return pairingGeneration != 0;
}

bool BLENavigationServer::armOwnershipPairingConfirmation(
    uint32_t pairingGeneration) {
  portENTER_CRITICAL(&ownershipUiMux);
  const bool requestMatches = pairingGeneration != 0 &&
      ownershipComparisonRenderGate.renderedGeneration() ==
          pairingGeneration;
  portEXIT_CRITICAL(&ownershipUiMux);
  if (!requestMatches || !deviceOwnershipReady ||
      deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(250)) != pdTRUE) {
    return false;
  }
  const bool armed =
      deviceOwnership.armPairingConfirmation(pairingGeneration);
  xSemaphoreGive(deviceOwnershipMutex);
  portENTER_CRITICAL(&ownershipUiMux);
  ownershipComparisonRenderGate.consumeRendered(pairingGeneration);
  portEXIT_CRITICAL(&ownershipUiMux);
  return armed;
}

bool BLENavigationServer::hasOwnershipPairingCode() {
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(50)) != pdTRUE) {
    return ownershipPairingActiveSnapshot;
  }
  const bool active = deviceOwnership.hasPairingCode();
  xSemaphoreGive(deviceOwnershipMutex);
  return active;
}

bool BLENavigationServer::isOwnershipClaimed() {
  portENTER_CRITICAL(&ownershipUiMux);
  const bool claimed = ownershipUiClaimed;
  portEXIT_CRITICAL(&ownershipUiMux);
  return claimed;
}

bool BLENavigationServer::confirmOwnershipPairing() {
  bool confirmed = false;
  uint32_t pairingCode = 0;
  std::string stableDeviceId;
  if (deviceOwnershipReady && deviceOwnershipMutex != nullptr &&
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(250)) == pdTRUE) {
    confirmed = deviceOwnership.confirmPairingOnDevice();
    if (confirmed) {
      stableDeviceId = deviceOwnership.deviceIdHex();
      pairingCode = deviceOwnership.pairingCode();
    }
    xSemaphoreGive(deviceOwnershipMutex);
  }
  if (!confirmed) {
    return false;
  }
  const std::string response = "PAIR_READY|" + stableDeviceId;
  notifyAuthResponse(response.c_str());
  queueOwnershipUiUpdate(static_cast<int32_t>(pairingCode));
  Serial.println("BLE: Ownership pairing confirmed with physical button press");
  return true;
}

// ============================================================================
// Map Redraw Trigger (weak symbol - can be overridden by main app)
// ============================================================================

__attribute__((weak)) void triggerMapRedraw() {
  // Default implementation - will be overridden by mainScr.cpp
  Serial.println("BLE: triggerMapRedraw called (default - no map linked)");
}

__attribute__((weak)) void applyDeviceScreenSettings() {
  // Default implementation - will be overridden by mainScr.cpp
}
