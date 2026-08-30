/**
 * @file ble_navigation.cpp
 * @brief BLE navigation server implementation
 *
 * Handles incoming navigation data from iOS app and triggers map updates.
 */

#include "ble_navigation.hpp"

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 1
#endif
#include "ble_connection_policy.hpp"
#include "device_ownership.hpp"
#include "ownership_button_policy.hpp"
#include "ownership_ui_dispatch_policy.hpp"
#include "device_screen_protocol.hpp"
#include "gps_input_freshness.hpp"
#include "gps_position_protocol.hpp"
#include "map_setting_packet.hpp"
#include "map_setting_redraw_policy.hpp"
#include "map_profile_persistence.hpp"
#include "device_capabilities_protocol.hpp"
#include "deferred_notification_dispatch_policy.hpp"
#include "scoped_watch_payload_policy.hpp"
#include "map_transfer_status_chunk_session.hpp"
#include "renderer_diagnostics_ble_protocol.hpp"
#include "transfer_control_dispatch.hpp"
#include "workout_telemetry_protocol.hpp"
#include "workout_telemetry_runtime.hpp"
#include "ride_automation_protocol.hpp"
#include "ride_automation_runtime.hpp"
#include "ride_delivery_protocol.hpp"
#include "authenticated_workout_telemetry.hpp"
#include "../gps/gps.hpp"
#include "../gui/src/waitingScr.hpp"
#include "../gui/src/globalGuiDef.h"
#include "../gui/src/mapRenderPolicy.hpp"
#include "../maps/src/maps.hpp"
#include "../device_transfer/device_transfer_http.hpp"
#include "../device_debug/device_debug_http.hpp"
#include "../display_power/display_power_policy.hpp"
#ifdef USE_ARDUINO_GFX
#include "../display_power/display_power.hpp"
#endif
#include "../firmware_metadata/firmware_metadata.hpp"
#include "../firmware_update/firmware_update_http.hpp"
#include "../map_transfer_http/map_transfer_http.hpp"
#include "../map_transfer/map_stream_compiled_trust.hpp"
#include "../power_metrics/power_metrics.hpp"
#include "../renderer_diagnostics/renderer_diagnostics.hpp"
#include "../ride_diagnostics/ride_diagnostics.hpp"
#include "../ride_diagnostics/ride_diagnostics_control.hpp"
#include "../route_overlay/route_overlay.hpp"
#include "../speaker/speaker.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "../waveshare_board/pcf85063.hpp"
#endif
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstring>
#include <esp_system.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>
#include <host/ble_hs_id.h>
#include <host/ble_gatt.h>
#include <host/ble_hs.h>
#include <host/ble_hs_mbuf.h>
#include <nimble/porting/nimble/include/nimble/nimble_port.h>
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
extern device_debug::DeviceDebugHttp deviceDebugHttp;
extern bool startRemoteDeviceDebugSession();
extern bool stopActiveDeviceTransfer();
extern Maps mapView;
extern Storage storage;

// Global instance
BLENavigationServer bleNavServer;

// Forward declaration of the LVGL-owner map scheduler entry point.
extern void requestMapRender(map_render_policy::Reason reason);
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
static bool bleSessionSupportsStreetLabels = false;
static bool bleSessionSupports3DBuildings = false;
static std::atomic<bool> bleSessionSupportsExplicitInvalidGpsHeading{false};
static std::atomic<bool> bleSessionSupportsRendererDiagnostics{false};
static std::atomic<bool> bleSessionSupportsRideDiagnostics{false};
static std::atomic<bool> bleSessionSupportsRideDeliveryAck{false};
// Captured while the ownership mutex is held by the accepted ride write. The
// application ACK path runs in the same NimBLE callback and must never fall
// back to lease generation zero merely because another task briefly owns the
// mutex.
static std::atomic<uint32_t> rideDeliveryLeaseGenerationSnapshot{0};
static std::atomic<uint32_t> ridePayloadGeneration{1};
static ride_delivery_protocol::GroupTracker rideDeliveryTracker;
static portMUX_TYPE rideDeliveryTrackerMux = portMUX_INITIALIZER_UNLOCKED;
static std::atomic<uint32_t> lastRendererMetricsRequestMs{0};
static std::atomic<uint32_t> lastRendererWindowRequestMs{0};
static std::atomic<uint8_t> lastRendererWindowRequestProfile{
    renderer_diagnostics_ble_protocol::CURRENT_PROFILE};
static std::atomic<uint32_t> lastRideDiagnosticsGpsLogMs{0};
static portMUX_TYPE rendererWindowRequestMux = portMUX_INITIALIZER_UNLOCKED;
static renderer_diagnostics_ble_protocol::WindowRequest
    pendingRendererWindowRequest;
static bool rendererWindowRequestPending = false;
static constexpr uint8_t CAPABILITY_EXTENDED_MAP_VISIBILITY =
    map_profile_protocol::EXTENDED_VISIBILITY_CAPABILITY_MASK;
static constexpr uint8_t CAPABILITY_BATTERY_STATUS_SCREEN = 1 << 5;
static char pendingAuthNonce[33] = "";
static NimBLECharacteristic *authCharacteristic = nullptr;
static NimBLECharacteristic *mapTransferStatusCharacteristic = nullptr;
static map_transfer_status_protocol::ChunkTransmission
    pendingMapTransferStatusChunks;
static std::atomic<bool> pendingMapTransferStatusContinuation{false};
static BLEDebugStats bleDebugStats;
static gps_input_freshness::State gpsFreshnessState;
static_assert(BLE_HS_CONN_HANDLE_NONE == ble_connection_policy::noConnection,
              "single-connection policy must match NimBLE's empty handle");
static uint16_t activeConnHandle = BLE_HS_CONN_HANDLE_NONE;
static bool unauthTimeoutDisconnectRequested = false;
#if BLE_RADIO_CHARACTERIZATION
static std::atomic<bool> radioNavigationActive{false};
static std::atomic<bool> radioUserWakePending{false};
static std::atomic<uint8_t> radioAdvertisingMode{
    static_cast<uint8_t>(ble_radio_policy::AdvertisingMode::Default)};
static std::atomic<uint32_t> radioAdvertisingModeStartedMs{0};
static std::atomic<uint8_t> radioRequestedConnectionProfile{
    static_cast<uint8_t>(ble_radio_policy::ConnectionProfile::Unset)};
#endif
static std::atomic<uint16_t> radioConnectionHandle{BLE_HS_CONN_HANDLE_NONE};
// Producers may run on the Arduino/LVGL task, while NimBLE owns the live
// connection state on its host task. Refresh the host-reported MTU from each
// incoming callback as well as onMTUChange: some restored iOS connections do
// not deliver the latter callback even though their ATT MTU is already larger
// than 23. Chunking must never call getPeerMTU() outside the host task.
static std::atomic<uint16_t> activePeerMtu{23};
static std::atomic<uint32_t> lastConnectionParameterSampleMs{0};
struct RadioDebugSnapshot {
  bool connectionParametersValid = false;
  uint16_t connectionIntervalUnits = 0;
  uint16_t connectionLatency = 0;
  uint16_t supervisionTimeoutUnits = 0;
  uint32_t connectionParameterSampleCount = 0;
  uint32_t lastConnectionParameterSampleMs = 0;
  ble_radio_policy::AdvertisingMode advertisingMode =
      ble_radio_policy::AdvertisingMode::Default;
  ble_radio_policy::ConnectionProfile requestedConnectionProfile =
      ble_radio_policy::ConnectionProfile::Unset;
};
static RadioDebugSnapshot radioDebugSnapshot;
static portMUX_TYPE radioDebugMux = portMUX_INITIALIZER_UNLOCKED;
static device_ownership::DeviceOwnership deviceOwnership;
static bool deviceOwnershipReady = false;
static bool ownershipPairingActiveSnapshot = false;
static StaticSemaphore_t deviceOwnershipMutexStorage;
static SemaphoreHandle_t deviceOwnershipMutex = nullptr;
static StaticSemaphore_t notificationTransportMutexStorage;
static SemaphoreHandle_t notificationTransportMutex = nullptr;
// NimBLE characteristic callbacks run on the pinned host task. Keep those
// callbacks bounded: authenticated notifications are protected there, then
// handed to NimBLE's own event queue for the actual notify call after the
// incoming ATT event has released the host mutex. The Arduino/LVGL loop never
// calls NimBLE transport APIs directly.
constexpr uint8_t kDeferredNotificationCapacity = 8;
constexpr size_t kDeferredNotificationBytes = 256;
struct DeferredNotification {
  NimBLECharacteristic *characteristic = nullptr;
  uint16_t connectionHandle = BLE_HS_CONN_HANDLE_NONE;
  uint16_t length = 0;
  uint8_t payload[kDeferredNotificationBytes] = {};
};
static DeferredNotification deferredNotifications[
    kDeferredNotificationCapacity];
static uint8_t deferredNotificationHead = 0;
static uint8_t deferredNotificationTail = 0;
static uint8_t deferredNotificationCount = 0;
static portMUX_TYPE deferredNotificationMux = portMUX_INITIALIZER_UNLOCKED;
static struct ble_npl_event deferredNotificationEvent;
static std::atomic<bool> deferredNotificationEventReady{false};
static std::atomic<bool> deferredNotificationEventPending{false};
// Keep at most one copy of the deferred event queued or executing. NimBLE's
// event object's internal queued bit is not an application-level ownership
// gate and can race the owner task with the pinned host task.
static std::atomic<bool> deferredNotificationEventScheduled{false};
static std::atomic<TaskHandle_t> nimbleCallbackTask{nullptr};
static std::atomic<uint32_t> deferredNotificationDrops{0};
static StaticSemaphore_t diagnosticsSessionMutexStorage;
static SemaphoreHandle_t diagnosticsSessionMutex = nullptr;
static bool ownershipAdvertisingDirty = false;
static bool ownershipDisconnectPending = false;
static bool ownershipRestartRequested = false;
static uint32_t ownershipRestartRequestedMs = 0;
static portMUX_TYPE ownershipUiMux = portMUX_INITIALIZER_UNLOCKED;
static bool ownershipUiUpdatePending = false;
static bool ownershipUiClaimed = false;
static bool ownershipUiConnected = false;
static bool ownershipUiAuthenticated = false;
static bool ownershipUiPairingActive = false;
static bool ownershipUiPairingConfirmedOnDevice = false;
static uint32_t ownershipUiPairingCode = 0;
static uint32_t ownershipUiPairingGeneration = 0;
static ownership_button_policy::ComparisonRenderGate
    ownershipComparisonRenderGate;
static ble_transfer::PendingRequest pendingTransferControl;
static portMUX_TYPE pendingTlsRotationMux = portMUX_INITIALIZER_UNLOCKED;
static char pendingTlsRotationFingerprint[
    device_transfer::TLS_CERTIFICATE_SHA256_HEX_BYTES + 1] = "";
static std::atomic<bool> diagnosticsSessionStartInProgress{false};
static std::atomic<uint32_t> diagnosticsSessionStartGeneration{0};
static std::atomic<uint32_t> diagnosticsSessionActiveGeneration{0};
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
static void processDeferredNotifications();
static void scheduleDeferredNotificationEvent();
static void deferredNotificationEventHandler(struct ble_npl_event *event);
static void pumpPendingMapTransferStatusChunks();

static void clearRendererWindowRequest() {
  portENTER_CRITICAL(&rendererWindowRequestMux);
  pendingRendererWindowRequest = {};
  rendererWindowRequestPending = false;
  portEXIT_CRITICAL(&rendererWindowRequestMux);
}

static void queueRendererWindowRequest(
    const renderer_diagnostics_ble_protocol::WindowRequest &request) {
  portENTER_CRITICAL(&rendererWindowRequestMux);
  pendingRendererWindowRequest = request;
  rendererWindowRequestPending = true;
  portEXIT_CRITICAL(&rendererWindowRequestMux);
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
}

#if BLE_RADIO_CHARACTERIZATION
static const char *advertisingModeName(
    ble_radio_policy::AdvertisingMode mode) {
  switch (mode) {
  case ble_radio_policy::AdvertisingMode::Fast:
    return "fast";
  case ble_radio_policy::AdvertisingMode::Slow:
    return "slow";
  case ble_radio_policy::AdvertisingMode::Default:
  default:
    return "default";
  }
}

static const char *connectionProfileName(
    ble_radio_policy::ConnectionProfile profile) {
  switch (profile) {
  case ble_radio_policy::ConnectionProfile::Navigation:
    return "navigation";
  case ble_radio_policy::ConnectionProfile::Idle:
    return "idle";
  case ble_radio_policy::ConnectionProfile::Unset:
  default:
    return "unset";
  }
}
#endif

static esp_power_level_t configuredTxPowerLevel() {
  switch (ble_radio_policy::kConfiguration.txPowerDbm) {
  case 0:
    return ESP_PWR_LVL_N0;
  case 3:
    return ESP_PWR_LVL_P3;
  case 9:
  default:
    return ESP_PWR_LVL_P9;
  }
}

static void recordConnectionParameters(const ble_gap_conn_desc &description,
                                       uint32_t nowMs) {
  portENTER_CRITICAL(&radioDebugMux);
  const bool changed = !radioDebugSnapshot.connectionParametersValid ||
                       radioDebugSnapshot.connectionIntervalUnits !=
                           description.conn_itvl ||
                       radioDebugSnapshot.connectionLatency !=
                           description.conn_latency ||
                       radioDebugSnapshot.supervisionTimeoutUnits !=
                           description.supervision_timeout;
  radioDebugSnapshot.connectionParametersValid = true;
  radioDebugSnapshot.connectionIntervalUnits = description.conn_itvl;
  radioDebugSnapshot.connectionLatency = description.conn_latency;
  radioDebugSnapshot.supervisionTimeoutUnits = description.supervision_timeout;
  radioDebugSnapshot.connectionParameterSampleCount++;
  radioDebugSnapshot.lastConnectionParameterSampleMs = nowMs;
  portEXIT_CRITICAL(&radioDebugMux);
  lastConnectionParameterSampleMs.store(nowMs, std::memory_order_release);
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
  if (changed) {
    Serial.printf(
        "BLE Radio: effective intervalUnits=%u latency=%u timeoutUnits=%u\n",
        description.conn_itvl, description.conn_latency,
        description.supervision_timeout);
  }
#else
  (void)changed;
#endif
}

#if BLE_RADIO_CHARACTERIZATION
static void applyCharacterizationAdvertisingMode(
    ble_radio_policy::AdvertisingMode mode, bool restartAdvertising) {
  NimBLEAdvertising *advertising = NimBLEDevice::getAdvertising();
  if (advertising == nullptr) {
    return;
  }
  if (restartAdvertising) {
    if (!advertising->isAdvertising() ||
        !NimBLEDevice::stopAdvertising()) {
      return;
    }
  }
  const ble_radio_policy::IntervalRange &range =
      mode == ble_radio_policy::AdvertisingMode::Slow
          ? ble_radio_policy::kConfiguration.slowAdvertising
          : ble_radio_policy::kConfiguration.fastAdvertising;
  advertising->setMinInterval(range.minimumUnits);
  advertising->setMaxInterval(range.maximumUnits);
  const uint32_t nowMs = millis();
  radioAdvertisingMode.store(static_cast<uint8_t>(mode),
                             std::memory_order_release);
  radioAdvertisingModeStartedMs.store(nowMs, std::memory_order_release);
  portENTER_CRITICAL(&radioDebugMux);
  radioDebugSnapshot.advertisingMode = mode;
  portEXIT_CRITICAL(&radioDebugMux);
  Serial.printf("BLE Radio: advertising mode=%s minUnits=%u maxUnits=%u\n",
                advertisingModeName(mode), range.minimumUnits,
                range.maximumUnits);
  if (restartAdvertising &&
      radioConnectionHandle.load(std::memory_order_acquire) ==
          BLE_HS_CONN_HANDLE_NONE &&
      !NimBLEDevice::startAdvertising()) {
    Serial.println("BLE Radio: failed to restart advertising");
  }
}

static void processRadioCharacterization(uint32_t nowMs,
                                         NimBLEServer *server) {
  const uint16_t connectionHandle =
      radioConnectionHandle.load(std::memory_order_acquire);
  if (connectionHandle == BLE_HS_CONN_HANDLE_NONE) {
    const bool wakeRequested =
        radioUserWakePending.exchange(false, std::memory_order_acq_rel);
    const auto currentMode = static_cast<ble_radio_policy::AdvertisingMode>(
        radioAdvertisingMode.load(std::memory_order_acquire));
    const uint32_t modeStartedMs =
        radioAdvertisingModeStartedMs.load(std::memory_order_acquire);
    const auto desiredMode = ble_radio_policy::nextAdvertisingMode(
        currentMode, nowMs - modeStartedMs, wakeRequested);
    if (desiredMode != currentMode || wakeRequested) {
      applyCharacterizationAdvertisingMode(desiredMode, true);
    }
    return;
  }

  radioUserWakePending.store(false, std::memory_order_release);
  const auto desiredProfile = ble_radio_policy::connectionProfile(
      radioNavigationActive.load(std::memory_order_acquire));
  const auto appliedProfile =
      static_cast<ble_radio_policy::ConnectionProfile>(
          radioRequestedConnectionProfile.load(std::memory_order_acquire));
  if (server != nullptr && desiredProfile != appliedProfile) {
    const ble_radio_policy::ConnectionParameters &parameters =
        ble_radio_policy::connectionParameters(desiredProfile);
    server->updateConnParams(
        connectionHandle, parameters.minimumIntervalUnits,
        parameters.maximumIntervalUnits, parameters.latency,
        parameters.supervisionTimeoutUnits);
    radioRequestedConnectionProfile.store(
        static_cast<uint8_t>(desiredProfile), std::memory_order_release);
    portENTER_CRITICAL(&radioDebugMux);
    radioDebugSnapshot.requestedConnectionProfile = desiredProfile;
    portEXIT_CRITICAL(&radioDebugMux);
    Serial.printf(
        "BLE Radio: requested profile=%s intervalUnits=%u-%u latency=%u "
        "timeoutUnits=%u\n",
        connectionProfileName(desiredProfile),
        parameters.minimumIntervalUnits, parameters.maximumIntervalUnits,
        parameters.latency, parameters.supervisionTimeoutUnits);
  }
}
#endif

static void queueOwnershipUiUpdate() {
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    return;
  }
  const bool claimed = deviceOwnership.isClaimed();
  const bool pairingActive = deviceOwnership.hasPairingCode();
  const bool pairingConfirmed =
      deviceOwnership.isPairingConfirmedOnDevice();
  const uint32_t pairingCode =
      pairingActive ? deviceOwnership.pairingCode() : 0;
  const uint32_t pairingGeneration =
      pairingActive ? deviceOwnership.pairingGeneration() : 0;
  xSemaphoreGive(deviceOwnershipMutex);
  portENTER_CRITICAL(&ownershipUiMux);
  ownershipUiClaimed = claimed;
  ownershipUiConnected = bleNavServer.isConnected();
  ownershipUiAuthenticated = bleSessionAuthenticated;
  ownershipUiPairingActive = pairingActive;
  ownershipUiPairingConfirmedOnDevice = pairingConfirmed;
  ownershipUiPairingCode = pairingCode;
  ownershipUiPairingGeneration = pairingGeneration;
  ownershipUiUpdatePending = true;
  portEXIT_CRITICAL(&ownershipUiMux);
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
}

static void applyPendingOwnershipUiUpdate() {
  pre_connection_presentation::Snapshot snapshot;
  uint32_t pairingGeneration = 0;
  portENTER_CRITICAL(&ownershipUiMux);
  const bool pending = ownershipUiUpdatePending;
  if (pending) {
    snapshot.claimed = ownershipUiClaimed;
    snapshot.connected = ownershipUiConnected;
    snapshot.authenticated = ownershipUiAuthenticated;
    snapshot.pairingActive = ownershipUiPairingActive;
    snapshot.pairingConfirmedOnDevice =
        ownershipUiPairingConfirmedOnDevice;
    snapshot.pairingCode = ownershipUiPairingCode;
    pairingGeneration = ownershipUiPairingGeneration;
    ownershipUiUpdatePending = false;
  }
  portEXIT_CRITICAL(&ownershipUiMux);
  if (pending) {
    pre_connection_presentation::presentThenUpdateComparisonGate(
        snapshot, pairingGeneration,
        [](const pre_connection_presentation::Snapshot &nextSnapshot,
           pre_connection_presentation::Phase) {
          updateWaitingOwnershipStatus(nextSnapshot);
        },
        [](uint32_t generation) {
          portENTER_CRITICAL(&ownershipUiMux);
          ownershipComparisonRenderGate.request(generation);
          portEXIT_CRITICAL(&ownershipUiMux);
        },
        [] {
          portENTER_CRITICAL(&ownershipUiMux);
          ownershipComparisonRenderGate.cancel();
          portEXIT_CRITICAL(&ownershipUiMux);
        });
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
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
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
  if (matches) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
  }
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

static scoped_watch_payload_policy::RequestSessionRole
currentRequestSessionRole() {
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    // Owner-only requests fail closed when role state cannot be read.
    return scoped_watch_payload_policy::RequestSessionRole::Unreadable;
  }
  const bool scopedWatch = deviceOwnership.isWatchRideSession();
  xSemaphoreGive(deviceOwnershipMutex);
  return scopedWatch
             ? scoped_watch_payload_policy::RequestSessionRole::ScopedWatch
             : scoped_watch_payload_policy::RequestSessionRole::Owner;
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
  if (currentRequestSessionRole() !=
      scoped_watch_payload_policy::RequestSessionRole::Owner) {
    setDestinationPickerStatus(DestinationPickerStatusCode::Failed, generation,
                               token, "Open iPhone to start navigation");
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

bool BLENavigationServer::canRequestWorkoutStart() const {
  return workoutStartRequestPresentation() ==
         WorkoutStartRequestPresentation::StartOnIPhone;
}

WorkoutStartRequestPresentation
BLENavigationServer::workoutStartRequestPresentation() const {
  using PolicyPresentation =
      scoped_watch_payload_policy::OwnerOnlyRequestPresentation;
  switch (scoped_watch_payload_policy::ownerOnlyRequestPresentation(
      connected, bleSessionAuthenticated,
      mapTransferStatusCharacteristic != nullptr,
      currentRequestSessionRole())) {
  case PolicyPresentation::OwnerAction:
    return WorkoutStartRequestPresentation::StartOnIPhone;
  case PolicyPresentation::ScopedWatchAction:
    return WorkoutStartRequestPresentation::StartOnAppleWatch;
  case PolicyPresentation::Unavailable:
    return WorkoutStartRequestPresentation::Unavailable;
  }
  return WorkoutStartRequestPresentation::Unavailable;
}

bool BLENavigationServer::requestWorkoutStart() {
  if (!canRequestWorkoutStart()) {
    Serial.println("BLE Workout: open the authenticated app to start");
    return false;
  }

  static constexpr uint8_t request[] = {'W', 'R', 'E', 'Q'};
  if (!notifyAuthenticatedNavigation(mapTransferStatusCharacteristic, request,
                                     sizeof(request))) {
    Serial.println("BLE Workout: secure start request failed");
    return false;
  }
  Serial.println("BLE Workout: start requested from Ride Stats");
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
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
}

// Route geometry debouncing - skip redundant parses
static uint32_t lastRouteHash = 0;
static size_t lastRouteLen = 0;
enum class PendingMapInputType : uint8_t { Route, Gps, Setting };
static constexpr size_t MAX_PENDING_MAP_INPUT_BYTES = 512;
struct PendingMapInput {
  PendingMapInputType type = PendingMapInputType::Route;
  uint16_t length = 0;
  bool fallback = false;
  bool pending = false;
  uint32_t payloadGeneration = 0;
  uint8_t *data = nullptr;
  gps_input_freshness::ArrivalBatch gpsArrivals{};
};
struct PendingRouteRideDelivery {
  bool pending = false;
  ride_delivery_protocol::CommandType type =
      ride_delivery_protocol::CommandType::NavigationClear;
  uint8_t memberIndex = 0;
  uint8_t memberCount = 0;
  ride_delivery_protocol::CommandId commandId{};
  uint32_t stateGeneration = 0;
  uint32_t leaseGeneration = 0;
  ride_delivery_protocol::Result result =
      ride_delivery_protocol::Result::Success;

  bool sameIdentity(const PendingRouteRideDelivery &other) const {
    return pending && other.pending && type == other.type &&
           commandId == other.commandId &&
           stateGeneration == other.stateGeneration &&
           leaseGeneration == other.leaseGeneration;
  }

  ride_delivery_protocol::CommandMember member() const {
    ride_delivery_protocol::CommandMember value{};
    value.type = type;
    value.memberIndex = memberIndex;
    value.memberCount = memberCount;
    value.commandId = commandId;
    value.stateGeneration = stateGeneration;
    return value;
  }
};
static SemaphoreHandle_t pendingMapInputMutex = nullptr;
static PendingMapInput pendingRouteInput;
static PendingRouteRideDelivery pendingRouteRideDelivery;
static PendingMapInput pendingGpsInput;
static constexpr size_t MAP_SETTING_SLOT_COUNT = 256;
static constexpr size_t MAP_SETTING_MASK_BYTES = MAP_SETTING_SLOT_COUNT / 8;
static PendingMapInput pendingSettingInputs[MAP_SETTING_SLOT_COUNT];
static uint8_t pendingSettingMask[MAP_SETTING_MASK_BYTES] = {0};
static std::atomic<uint16_t> pendingMapInputCount{0};

static void noteRideDeliveryMember(
    const ride_delivery_protocol::CommandMember &member,
    ride_delivery_protocol::Result result,
    uint32_t expectedLeaseGeneration = 0);

static bool pendingRouteDeliveryMatchesCurrentLease(
    const PendingRouteRideDelivery &delivery) {
  return delivery.pending && delivery.leaseGeneration != 0 &&
         delivery.leaseGeneration == rideDeliveryLeaseGenerationSnapshot.load(
                                         std::memory_order_acquire);
}

static void resetRideDeliveryTracking() {
  portENTER_CRITICAL(&rideDeliveryTrackerMux);
  rideDeliveryTracker.reset();
  portEXIT_CRITICAL(&rideDeliveryTrackerMux);
  if (pendingMapInputMutex != nullptr &&
      xSemaphoreTake(pendingMapInputMutex, portMAX_DELAY) == pdTRUE) {
    auto clearInput = [](PendingMapInput &input) {
      free(input.data);
      input = {};
    };
    clearInput(pendingRouteInput);
    clearInput(pendingGpsInput);
    for (PendingMapInput &input : pendingSettingInputs)
      clearInput(input);
    memset(pendingSettingMask, 0, sizeof(pendingSettingMask));
    pendingMapInputCount.store(0, std::memory_order_release);
    pendingRouteRideDelivery = {};
    xSemaphoreGive(pendingMapInputMutex);
  }
}

static void advanceRidePayloadGeneration() {
  uint32_t next = ridePayloadGeneration.fetch_add(
      1, std::memory_order_acq_rel) + 1U;
  if (next == 0) {
    ridePayloadGeneration.store(1, std::memory_order_release);
  }
}

static bool queueMapInput(PendingMapInputType type, const uint8_t *data,
                          size_t len, const char *source,
                          const ride_delivery_protocol::CommandMember
                              *rideDeliveryMember = nullptr,
                          ride_delivery_protocol::Result rideDeliveryResult =
                              ride_delivery_protocol::Result::Success) {
  if (pendingMapInputMutex == nullptr || len > MAX_PENDING_MAP_INPUT_BYTES ||
      (len > 0 && data == nullptr)) {
    Serial.printf("BLE: rejected queued map input type=%u len=%u\n",
                  static_cast<unsigned>(type), static_cast<unsigned>(len));
    return false;
  }
  uint32_t gpsReceivedAtMs = 0;
  if (type == PendingMapInputType::Gps) {
    power_metrics::noteBlePacket(power_metrics::BlePacketClass::Gps);
    if (!gps_input_freshness::acceptsPayload(data, len)) {
      Serial.printf("BLE: Rejected %s GPS position: expected at least 8 bytes\n",
                    source == nullptr ? "unknown" : source);
      return false;
    }
    // Capture transport freshness on the authenticated NimBLE callback task,
    // before allocation or a potentially delayed UI-task mailbox drain.
    gpsReceivedAtMs = millis();
  }
  PendingMapInput input;
  input.type = type;
  input.length = static_cast<uint16_t>(len);
  input.fallback = source != nullptr && strcmp(source, "fallback") == 0;
  input.pending = true;
  input.payloadGeneration =
      ridePayloadGeneration.load(std::memory_order_acquire);
  if (len > 0) {
    input.data = static_cast<uint8_t *>(malloc(len));
    if (input.data == nullptr) {
      Serial.printf("BLE: map input allocation failed type=%u len=%u\n",
                    static_cast<unsigned>(type), static_cast<unsigned>(len));
      return false;
    }
    memcpy(input.data, data, len);
  }
  PendingMapInput *slot = nullptr;
  switch (type) {
  case PendingMapInputType::Route:
    slot = &pendingRouteInput;
    break;
  case PendingMapInputType::Gps:
    slot = &pendingGpsInput;
    break;
  case PendingMapInputType::Setting:
    if (len == 0) {
      Serial.println("BLE: rejected queued map setting without an ID");
      free(input.data);
      return false;
    }
    slot = &pendingSettingInputs[data[0]];
    break;
  }

  if (xSemaphoreTake(pendingMapInputMutex, portMAX_DELAY) != pdTRUE) {
    free(input.data);
    return false;
  }
  PendingMapInput replaced = *slot;
  PendingRouteRideDelivery replacedRouteDelivery{};
  bool rejectedReplacedRouteDelivery = false;
  if (type == PendingMapInputType::Route) {
    replacedRouteDelivery = pendingRouteRideDelivery;
    pendingRouteRideDelivery = {};
    if (rideDeliveryMember != nullptr) {
      pendingRouteRideDelivery.pending = true;
      pendingRouteRideDelivery.type = rideDeliveryMember->type;
      pendingRouteRideDelivery.memberIndex = rideDeliveryMember->memberIndex;
      pendingRouteRideDelivery.memberCount = rideDeliveryMember->memberCount;
      pendingRouteRideDelivery.commandId = rideDeliveryMember->commandId;
      pendingRouteRideDelivery.stateGeneration =
          rideDeliveryMember->stateGeneration;
      pendingRouteRideDelivery.leaseGeneration =
          rideDeliveryLeaseGenerationSnapshot.load(std::memory_order_acquire);
      pendingRouteRideDelivery.result = rideDeliveryResult;
    }
    rejectedReplacedRouteDelivery = replacedRouteDelivery.pending &&
        !replacedRouteDelivery.sameIdentity(pendingRouteRideDelivery);
  }
  if (type == PendingMapInputType::Gps) {
    input.gpsArrivals = replaced.gpsArrivals;
    input.gpsArrivals.observe(gpsReceivedAtMs);
  }
  *slot = input;
  if (!replaced.pending) {
    pendingMapInputCount.fetch_add(1, std::memory_order_release);
  }
  if (type == PendingMapInputType::Setting) {
    const uint8_t settingId = data[0];
    pendingSettingMask[settingId / 8] |=
        static_cast<uint8_t>(1U << (settingId % 8));
  }
  xSemaphoreGive(pendingMapInputMutex);
  // Latest-state mailboxes make periodic GPS and repeated route/settings
  // updates bounded without ever dropping the newest authoritative value.
  free(replaced.data);
  if (rejectedReplacedRouteDelivery &&
      pendingRouteDeliveryMatchesCurrentLease(replacedRouteDelivery)) {
    noteRideDeliveryMember(
        replacedRouteDelivery.member(),
        ride_delivery_protocol::Result::ResourceRejected,
        replacedRouteDelivery.leaseGeneration);
  }
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
  return true;
}
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
  static std::string lastDiagnosticInstruction;
  static uint32_t lastDiagnosticNavigationRecordMs = 0;
  const uint32_t nowMs = millis();
  if (instruction != lastDiagnosticInstruction ||
      static_cast<uint32_t>(nowMs - lastDiagnosticNavigationRecordMs) >=
          30'000U) {
    lastDiagnosticInstruction = instruction;
    lastDiagnosticNavigationRecordMs = nowMs;
    char diagnosticFields[128] = {};
    snprintf(diagnosticFields, sizeof(diagnosticFields),
             "{\"messageBytes\":%u,\"routeLoaded\":true}",
             static_cast<unsigned>(instruction.size()));
    (void)ride_diagnostics::record(
        ride_diagnostics::Level::Info, "navigation", "maneuver_updated",
        diagnosticFields);
  }

#if FIRMWARE_DIAGNOSTICS
  Serial.printf("BLE Nav: Icon=%d, Dist=%dm, Instr=%s\n", currentNavData.iconID,
                currentNavData.distance, currentNavData.instruction);
#endif
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
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
    std::string &payload, const char *payloadName,
    bool *wasScopedWatchSession = nullptr) {
  if (wasScopedWatchSession != nullptr) {
    *wasScopedWatchSession = false;
  }
  if (!deviceOwnershipReady || deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    payload = frame;
    return !deviceOwnershipReady;
  }
  const bool requiresFrame = deviceOwnership.isSessionAuthenticated();
  const bool authenticationStateDiverged =
      bleSessionAuthenticated && !requiresFrame;
  const bool validFrame =
      !authenticationStateDiverged &&
      (!requiresFrame ||
       deviceOwnership.unwrapAuthenticatedPayload(channel, frame, payload));
  const uint32_t nowMs = millis();
  const bool accepted =
      validFrame &&
      (!requiresFrame ||
       channel == device_ownership::AuthenticatedChannel::Auth ||
       deviceOwnership.authorizeRideWrite(channel, nowMs));
  if (accepted && requiresFrame &&
      channel != device_ownership::AuthenticatedChannel::Auth) {
    rideDeliveryLeaseGenerationSnapshot.store(
        deviceOwnership.authenticatedRideLeaseGeneration(nowMs),
        std::memory_order_release);
  }
  if (accepted && wasScopedWatchSession != nullptr) {
    *wasScopedWatchSession = deviceOwnership.isWatchRideSession();
  }
  if (!requiresFrame) {
    payload = frame;
  }
  xSemaphoreGive(deviceOwnershipMutex);
  if (authenticationStateDiverged) {
    bleSessionAuthenticated = false;
    clearAuthenticatedBleGpsRideObservation();
    bleSessionSupportsExplicitInvalidGpsHeading.store(false,
                                                      std::memory_order_release);
    bleSessionSupportsRendererDiagnostics.store(false,
                                                std::memory_order_release);
    bleSessionSupportsRideDiagnostics.store(false,
                                            std::memory_order_release);
    clearRendererWindowRequest();
    bleDebugStats.authenticated = false;
    ownershipDisconnectPending = true;
    Serial.println("BLE: Ownership session was lost; disconnect requested");
  }
  if (!accepted) {
    bleDebugStats.rejectedUnauthenticatedCount++;
    bleDebugStats.lastRejectedUnauthenticatedMs = millis();
    Serial.printf("BLE: Rejected %s: invalid frame, role, or controller lease\n",
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

static bool enqueueDeferredNotification(NimBLECharacteristic *characteristic,
                                         uint16_t connectionHandle,
                                         const uint8_t *data, size_t length) {
  if (characteristic == nullptr || data == nullptr || length == 0 ||
      length > kDeferredNotificationBytes ||
      connectionHandle == BLE_HS_CONN_HANDLE_NONE) {
    return false;
  }
  if (!deferredNotificationEventReady.load(std::memory_order_acquire)) {
    deferredNotificationDrops.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  bool queued = false;
  portENTER_CRITICAL(&deferredNotificationMux);
  if (deferredNotificationCount < kDeferredNotificationCapacity) {
    DeferredNotification &slot =
        deferredNotifications[deferredNotificationTail];
    slot.characteristic = characteristic;
    slot.connectionHandle = connectionHandle;
    slot.length = static_cast<uint16_t>(length);
    memcpy(slot.payload, data, length);
    deferredNotificationTail = static_cast<uint8_t>(
        (deferredNotificationTail + 1) % kDeferredNotificationCapacity);
    deferredNotificationCount++;
    queued = true;
  }
  portEXIT_CRITICAL(&deferredNotificationMux);
  if (queued) {
    deferredNotificationEventPending.store(true, std::memory_order_release);
    // Do not touch NimBLE's event queue from an ATT callback. The callback
    // still runs while NimBLE owns its host lock; enqueueing there can yield
    // or re-enter the queue before the ATT response has been released. The
    // Arduino owner task schedules the event after this callback returns.
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
  } else {
    deferredNotificationDrops.fetch_add(1, std::memory_order_relaxed);
  }
  return queued;
}

static uint8_t deferredNotificationAvailableCapacity() {
  uint8_t available = 0;
  portENTER_CRITICAL(&deferredNotificationMux);
  available = static_cast<uint8_t>(kDeferredNotificationCapacity -
                                   deferredNotificationCount);
  portEXIT_CRITICAL(&deferredNotificationMux);
  return available;
}

static void scheduleDeferredNotificationEvent() {
  if (!deferredNotificationEventReady.load(std::memory_order_acquire) ||
      !deferredNotificationEventPending.load(std::memory_order_acquire)) {
    return;
  }
  bool expected = false;
  if (!deferredNotificationEventScheduled.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel,
          std::memory_order_acquire)) {
    return;
  }
  // This is the only producer-side call into NimBLE's default event queue.
  // It runs on the Arduino/LVGL owner task, after any NimBLE callback that
  // published the deferred frame has returned.
  ble_npl_eventq_put(nimble_port_get_dflt_eventq(),
                     &deferredNotificationEvent);
}

static ble_notification_dispatch_policy::TransportResult
sendWireNotification(NimBLECharacteristic *characteristic,
                     uint16_t connectionHandle, const uint8_t *data,
                     size_t length, const char *label) {
  using ble_notification_dispatch_policy::TransportResult;
  if (characteristic == nullptr || data == nullptr || length == 0 ||
      notificationTransportMutex == nullptr) {
    return TransportResult::Drop;
  }
  if (xSemaphoreTake(notificationTransportMutex, pdMS_TO_TICKS(100)) !=
      pdTRUE) {
    return TransportResult::Retry;
  }
  if (connectionHandle == BLE_HS_CONN_HANDLE_NONE ||
      activeConnHandle != connectionHandle ||
      characteristic->getSubscribedCount() == 0) {
    xSemaphoreGive(notificationTransportMutex);
    return TransportResult::Drop;
  }
  uint16_t peerMtu = 23;
  NimBLEService *service = characteristic->getService();
  NimBLEServer *server = service == nullptr ? nullptr : service->getServer();
  if (server != nullptr) {
    peerMtu = server->getPeerMTU(connectionHandle);
  }
  if (peerMtu < 3 || length > static_cast<size_t>(peerMtu - 3)) {
    Serial.printf("BLE: %s notification needs ATT MTU %u; peer negotiated %u\n",
                  label == nullptr ? "wire" : label,
                  static_cast<unsigned>(length + 3), peerMtu);
    xSemaphoreGive(notificationTransportMutex);
    return TransportResult::Drop;
  }

  os_mbuf *payload =
      ble_hs_mbuf_from_flat(data, static_cast<uint16_t>(length));
  if (payload == nullptr) {
    xSemaphoreGive(notificationTransportMutex);
    return TransportResult::Retry;
  }

  characteristic->setValue(data, length);
  // NimBLE-Arduino 1.4's characteristic notify() API returns void and drops
  // the host result. Use the underlying free-form server notification so a
  // finite ATT/L2CAP buffer condition can preserve and retry this exact frame.
  const int result = ble_gatts_notify_custom(
      connectionHandle, characteristic->getHandle(), payload);
  xSemaphoreGive(notificationTransportMutex);
  if (result == 0) {
    return TransportResult::Sent;
  }
  if (result == BLE_HS_EAGAIN || result == BLE_HS_ENOMEM ||
      result == BLE_HS_EBUSY || result == BLE_HS_ENOMEM_EVT) {
    return TransportResult::Retry;
  }
  Serial.printf("BLE: %s notification dropped by host rc=%d\n",
                label == nullptr ? "wire" : label, result);
  return TransportResult::Drop;
}

static bool isNimbleCallbackContext() {
  return nimbleCallbackTask.load(std::memory_order_acquire) ==
         xTaskGetCurrentTaskHandle();
}

static void processDeferredNotifications() {
  using ble_notification_dispatch_policy::TransportResult;
  const uint32_t dropped =
      deferredNotificationDrops.exchange(0, std::memory_order_acq_rel);
  if (dropped != 0) {
    Serial.printf("BLE: Deferred notification queue dropped=%lu\n",
                  static_cast<unsigned long>(dropped));
  }
  DeferredNotification pending;
  uint8_t queuedBefore = 0;
  portENTER_CRITICAL(&deferredNotificationMux);
  queuedBefore = deferredNotificationCount;
  if (queuedBefore > 0) {
    pending = deferredNotifications[deferredNotificationHead];
  }
  portEXIT_CRITICAL(&deferredNotificationMux);
  if (queuedBefore == 0) {
    return;
  }

  const TransportResult result = sendWireNotification(
      pending.characteristic, pending.connectionHandle, pending.payload,
      pending.length, "deferred");
  const auto decision =
      ble_notification_dispatch_policy::decideAfterAttempt(result,
                                                            queuedBefore);

  bool continueLater = decision.continueLater;
  portENTER_CRITICAL(&deferredNotificationMux);
  if (decision.consumeHead && deferredNotificationCount > 0) {
    deferredNotificationHead = static_cast<uint8_t>(
        (deferredNotificationHead + 1) % kDeferredNotificationCapacity);
    deferredNotificationCount--;
  }
  continueLater = continueLater || deferredNotificationCount > 0;
  portEXIT_CRITICAL(&deferredNotificationMux);

  if (continueLater) {
    deferredNotificationEventPending.store(true, std::memory_order_release);
  }
}

static void deferredNotificationEventHandler(struct ble_npl_event *event) {
  (void)event;
  // Clear the pending hint before draining, but keep the scheduling gate held
  // until the handler is done. A producer that races the drain therefore
  // leaves a pending hint for the owner task without queueing a second copy
  // of this event while it is executing.
  deferredNotificationEventPending.store(false, std::memory_order_release);
  // This callback runs on NimBLE's pinned host task. All transport calls below
  // therefore enter the host mutex only after the incoming ATT callback has
  // returned.
  processDeferredNotifications();
  deferredNotificationEventScheduled.store(false, std::memory_order_release);
  if (deferredNotificationEventPending.load(std::memory_order_acquire) ||
      pendingMapTransferStatusContinuation.load(std::memory_order_acquire)) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
  }
}

static void notifyAuthResponse(const std::string &response) {
  constexpr size_t kMaximumOwnershipNotificationBytes = 182;
  if (authCharacteristic == nullptr || response.empty() ||
      response.size() > kMaximumOwnershipNotificationBytes) {
    if (response.size() > kMaximumOwnershipNotificationBytes) {
      Serial.printf("BLE: Ownership response too large: %u bytes\n",
                    static_cast<unsigned>(response.size()));
    }
    return;
  }
  const uint16_t connectionHandle = activeConnHandle;
  const uint8_t *data = reinterpret_cast<const uint8_t *>(response.data());
  (void)enqueueDeferredNotification(authCharacteristic, connectionHandle, data,
                                     response.size());
}

static void notifyAuthResponse(const char *response) {
  if (response != nullptr) notifyAuthResponse(std::string(response));
}

static void completeBleSessionAuthentication() {
  // Every authentication mechanism opens the same transactional workout
  // replacement boundary. This prevents staged frames from crossing BLE
  // connections and lets a complete current pair replace a retained terminal
  // snapshot even when the 16-bit session token collides.
  workout_telemetry_runtime::beginAuthenticatedResynchronization();
  bleSessionAuthenticated = true;
  bleDebugStats.authenticated = true;
  bleDebugStats.authSuccessCount++;
  bleDebugStats.lastAuthSuccessMs = millis();
  ride_diagnostics::record(ride_diagnostics::Level::Info, "ble",
                           "authenticated", "{}");
  queueOwnershipUiUpdate();
}

static bool notifyAuthenticatedPayload(
    NimBLECharacteristic *characteristic,
    device_ownership::AuthenticatedChannel channel, const uint8_t *data,
    size_t length, const char *label) {
  (void)label;
  if (characteristic == nullptr || data == nullptr ||
      !bleSessionAuthenticated || !deviceOwnershipReady ||
      deviceOwnershipMutex == nullptr || notificationTransportMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex,
                     isNimbleCallbackContext() ? 0 : pdMS_TO_TICKS(100)) !=
          pdTRUE) {
    return false;
  }
  std::string frame;
  const std::string payload(reinterpret_cast<const char *>(data), length);
  const bool protectedPayload = deviceOwnership.protectAuthenticatedPayload(
      channel, payload, frame);
  if (!protectedPayload || activeConnHandle == BLE_HS_CONN_HANDLE_NONE) {
    xSemaphoreGive(deviceOwnershipMutex);
    return false;
  }
  const uint16_t connectionHandle = activeConnHandle;
  const uint8_t *frameData =
      reinterpret_cast<const uint8_t *>(frame.data());
  // Queue before releasing the ownership lock so a callback or UI-side sender
  // cannot publish a later sequence before this frame is visible to the host
  // task. The event queue also serializes every outbound NimBLE call.
  const bool sent = enqueueDeferredNotification(
      characteristic, connectionHandle, frameData, frame.size());
  xSemaphoreGive(deviceOwnershipMutex);
  return sent;
}

static bool notifyAuthenticatedNavigation(NimBLECharacteristic *characteristic,
                                          const uint8_t *data, size_t length) {
  return notifyAuthenticatedPayload(
      characteristic, device_ownership::AuthenticatedChannel::Navigation,
      data, length, "navigation");
}

static uint32_t currentRideLeaseGeneration() {
  return rideDeliveryLeaseGenerationSnapshot.load(std::memory_order_acquire);
}

static void notifyRideDeliveryAcknowledgement(
    const ride_delivery_protocol::Acknowledgement &acknowledgement) {
  uint8_t payload[ride_delivery_protocol::ACK_SIZE]{};
  const size_t length = ride_delivery_protocol::encodeAcknowledgement(
      acknowledgement, payload, sizeof(payload));
  if (length == 0 ||
      !notifyAuthenticatedNavigation(mapTransferStatusCharacteristic, payload,
                                     length)) {
    Serial.println("BLE Ride Delivery: acknowledgement queue failed");
  }
}

static void noteRideDeliveryMember(
    const ride_delivery_protocol::CommandMember &member,
    ride_delivery_protocol::Result result,
    uint32_t expectedLeaseGeneration) {
  ride_delivery_protocol::Acknowledgement acknowledgement{};
  ride_delivery_protocol::TrackingResult tracking =
      ride_delivery_protocol::TrackingResult::Rejected;
  portENTER_CRITICAL(&rideDeliveryTrackerMux);
  const uint32_t leaseGeneration = currentRideLeaseGeneration();
  if (leaseGeneration != 0 &&
      (expectedLeaseGeneration == 0 ||
       expectedLeaseGeneration == leaseGeneration)) {
    tracking = rideDeliveryTracker.note(member, result, leaseGeneration,
                                        acknowledgement);
  }
  portEXIT_CRITICAL(&rideDeliveryTrackerMux);
  if (tracking == ride_delivery_protocol::TrackingResult::Complete ||
      tracking == ride_delivery_protocol::TrackingResult::DuplicateComplete ||
      tracking == ride_delivery_protocol::TrackingResult::Immediate) {
    char fields[160] = {};
    snprintf(fields, sizeof(fields),
             "{\"commandClass\":%u,\"result\":%u,\"members\":%u,"
             "\"leaseGeneration\":%lu,\"outcome\":\"%s\"}",
             static_cast<unsigned>(acknowledgement.type),
             static_cast<unsigned>(acknowledgement.result),
             static_cast<unsigned>(member.memberCount),
             static_cast<unsigned long>(acknowledgement.leaseGeneration),
             tracking == ride_delivery_protocol::TrackingResult::Complete
                 ? "applied"
             : tracking ==
                       ride_delivery_protocol::TrackingResult::DuplicateComplete
                 ? "duplicate"
                 : "rejected");
    (void)ride_diagnostics::record(
        acknowledgement.result == ride_delivery_protocol::Result::Success ||
                acknowledgement.result == ride_delivery_protocol::Result::Stale
            ? ride_diagnostics::Level::Info
            : ride_diagnostics::Level::Warning,
        "ble", "ride_command_acknowledged", fields);
    notifyRideDeliveryAcknowledgement(acknowledgement);
  }
}

enum class RideDeliveryDecodeResult : uint8_t {
  NotWrapped,
  Decoded,
  Rejected,
};

static RideDeliveryDecodeResult decodeRideDeliveryPayload(
    const std::string &value, ride_delivery_protocol::CommandType expectedType,
    ride_delivery_protocol::CommandMember &member) {
  if (value.size() < 4 || std::memcmp(value.data(),
                                     ride_delivery_protocol::COMMAND_PREFIX,
                                     4) != 0)
    return RideDeliveryDecodeResult::NotWrapped;
  if (!bleSessionSupportsRideDeliveryAck.load(std::memory_order_acquire) ||
      !ride_delivery_protocol::decodeCommand(
          reinterpret_cast<const uint8_t *>(value.data()), value.size(),
          member) ||
      member.type != expectedType) {
    Serial.println("BLE Ride Delivery: rejected malformed command envelope");
    return RideDeliveryDecodeResult::Rejected;
  }
  return RideDeliveryDecodeResult::Decoded;
}

bool BLENavigationServer::notifyRideAutomationFrame(const uint8_t *data,
                                                    size_t length) {
  if (data == nullptr || length != ride_automation_protocol::FRAME_SIZE)
    return false;
  const bool native = notifyAuthenticatedPayload(
      pRideAutomationCharacteristic,
      device_ownership::AuthenticatedChannel::RideAutomation, data, length,
      "ride automation");
  if (native)
    return true;
  uint8_t fallback[ride_automation_protocol::FALLBACK_PREFIX_SIZE +
                   ride_automation_protocol::FRAME_SIZE]{};
  std::memcpy(fallback, ride_automation_protocol::FALLBACK_PREFIX,
              ride_automation_protocol::FALLBACK_PREFIX_SIZE);
  std::memcpy(fallback + ride_automation_protocol::FALLBACK_PREFIX_SIZE, data,
              length);
  return notifyAuthenticatedNavigation(mapTransferStatusCharacteristic,
                                       fallback, sizeof(fallback));
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
    bool ownershipLockAcquired = false;
    bool ownershipSessionAuthenticated = false;
    if (deviceOwnershipMutex != nullptr &&
        xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(250)) == pdTRUE) {
      ownershipLockAcquired = true;
      ownershipResult = deviceOwnership.handle(value, millis());
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
      clearAuthenticatedBleGpsRideObservation();
      bleSessionSupportsExplicitInvalidGpsHeading.store(
          false, std::memory_order_release);
      bleSessionSupportsRendererDiagnostics.store(false,
                                                  std::memory_order_release);
      bleSessionSupportsRideDiagnostics.store(false,
                                              std::memory_order_release);
      clearRendererWindowRequest();
      bleDebugStats.authenticated = false;
      ownershipDisconnectPending = true;
      Serial.println("BLE: Ownership command invalidated session; disconnect requested");
    }
    if (ownership_ui_dispatch_policy::dispatchMatchedCommand(
            ownershipResult.matched, ownershipResult.event,
            [](device_ownership::Event event) {
              switch (event) {
              case device_ownership::Event::PairingStarted:
                ownershipPairingActiveSnapshot = true;
                Serial.println("BLE: Secure ownership comparison started");
                break;
              case device_ownership::Event::Paired:
                ownershipPairingActiveSnapshot = false;
                ownershipAdvertisingDirty = true;
                Serial.println("BLE: Device ownership registered");
                break;
              case device_ownership::Event::Authenticated:
                completeBleSessionAuthentication();
                Serial.println("BLE: Scoped controller session authenticated");
                break;
              case device_ownership::Event::WatchControllerStaged:
                Serial.println("BLE: Watch controller enrollment staged");
                break;
              case device_ownership::Event::WatchControllerCommitted:
                Serial.println("BLE: Watch controller enrollment committed");
                break;
              case device_ownership::Event::WatchControllerRevoked:
                Serial.println("BLE: Watch controller credential revoked");
                break;
              case device_ownership::Event::LeaseReleased:
                clearAuthenticatedBleGpsRideObservation();
                Serial.println("BLE: Controller lease released; GPS evidence cleared");
                break;
              case device_ownership::Event::Renamed:
                ownershipAdvertisingDirty = true;
                Serial.println("BLE: Device name updated");
                break;
              case device_ownership::Event::Unpaired:
                bleSessionAuthenticated = false;
                clearAuthenticatedBleGpsRideObservation();
                bleSessionSupportsExplicitInvalidGpsHeading.store(
                    false, std::memory_order_release);
                bleSessionSupportsRendererDiagnostics.store(
                    false, std::memory_order_release);
                clearRendererWindowRequest();
                bleDebugStats.authenticated = false;
                ownershipAdvertisingDirty = true;
                ownershipRestartRequested = true;
                ownershipRestartRequestedMs = millis();
                Serial.println(
                    "BLE: Device ownership removed; restart scheduled");
                break;
              case device_ownership::Event::None:
                break;
              }
            },
            [] {
              // Some matched failure paths clear pairing without a distinct
              // event (invalid/expired confirmation or persistence rollback).
              // Always queue the post-command snapshot so the UI and render
              // gate cannot retain a stale PairingConfirmed presentation.
              queueOwnershipUiUpdate();
            })) {
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
    clearAuthenticatedBleGpsRideObservation();
    bleSessionUsesIndependentMapProfiles = false;
    bleSessionSupportsStreetLabels = false;
    bleSessionSupports3DBuildings = false;
    bleSessionSupportsExplicitInvalidGpsHeading.store(false,
                                                      std::memory_order_release);
    bleSessionSupportsRendererDiagnostics.store(false,
                                                std::memory_order_release);
    bleSessionSupportsRideDiagnostics.store(false,
                                            std::memory_order_release);
    bleSessionSupportsRideDeliveryAck.store(false,
                                             std::memory_order_release);
    rideDeliveryLeaseGenerationSnapshot.store(0,
                                               std::memory_order_release);
    advanceRidePayloadGeneration();
    resetRideDeliveryTracking();
    lastRendererMetricsRequestMs.store(0, std::memory_order_release);
    lastRendererWindowRequestMs.store(0, std::memory_order_release);
    lastRendererWindowRequestProfile.store(
        renderer_diagnostics_ble_protocol::CURRENT_PROFILE,
        std::memory_order_release);
    clearRendererWindowRequest();
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

    completeBleSessionAuthentication();
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
    } else if (static_cast<unsigned char>(c) < 0x20) {
      static constexpr char kHex[] = "0123456789abcdef";
      const unsigned char value = static_cast<unsigned char>(c);
      out += "\\u00";
      out.push_back(kHex[value >> 4]);
      out.push_back(kHex[value & 0x0f]);
    } else {
      out.push_back(c);
    }
  }
  return out;
}

struct ActivePresentationCache {
  bool available = false;
  std::string mapId;
  std::string sessionId;
  std::string root;
  std::string manifestReceipt;
  std::string signedManifestReceipt;
  map_transfer::MapPresentationMetadata presentation;
  map_transfer::MapPresentationRevision revision;

  bool matches(
      const map_transfer::ActiveMapSelection &selection,
      const map_transfer::MapPresentationRevision &sourceRevision) const {
    return available && mapId == selection.mapId &&
           sessionId == selection.sessionId && root == selection.root &&
           manifestReceipt == selection.manifestReceipt &&
           signedManifestReceipt == selection.signedManifestReceipt &&
           revision.bytes == sourceRevision.bytes &&
           revision.modifiedSeconds == sourceRevision.modifiedSeconds &&
           revision.inode == sourceRevision.inode;
  }

  void clear() {
    available = false;
    mapId.clear();
    sessionId.clear();
    root.clear();
    manifestReceipt.clear();
    signedManifestReceipt.clear();
    presentation = map_transfer::MapPresentationMetadata();
    revision = map_transfer::MapPresentationRevision();
  }

  void store(const map_transfer::ActiveMapSelection &selection,
             const map_transfer::MapPresentationMetadata &value,
             const map_transfer::MapPresentationRevision &sourceRevision) {
    available = true;
    mapId = selection.mapId;
    sessionId = selection.sessionId;
    root = selection.root;
    manifestReceipt = selection.manifestReceipt;
    signedManifestReceipt = selection.signedManifestReceipt;
    presentation = value;
    revision = sourceRevision;
  }
};

struct ActiveMapStatusSnapshot {
  bool available = false;
  std::string errorCode;
  map_transfer::ActiveMapSelection activeMap;
  map_transfer::MapPresentationMetadata presentation;
};

// Keep filesystem/manifest work out of the JSON composition frame. The VFS
// stat path is deep enough that combining both phases can consume most of the
// Arduino loop task stack during an iPhone status request.
__attribute__((noinline)) static const ActiveMapStatusSnapshot &
readActiveMapStatusSnapshot() {
  static ActivePresentationCache activePresentationCache;
  static ActiveMapStatusSnapshot snapshot;

  map_transfer::MapTransferInstaller installer("/sdcard");
  map_transfer::ActiveMapSelection activeMap;
  map_transfer::InstallStatus activeStatus =
      installer.readActiveMap(activeMap);
  if (!activeStatus.ok) {
    activePresentationCache.clear();
    snapshot.available = false;
    snapshot.errorCode = activeStatus.code;
    return snapshot;
  }

  map_transfer::MapPresentationMetadata activePresentation;
  map_transfer::InstallStatus activePresentationStatus;
  map_transfer::MapPresentationRevision activePresentationRevision;
  const bool hasPresentationRevision =
      installer.readActiveMapPresentationRevision(
          activeMap, activePresentationRevision);
  if (hasPresentationRevision && activePresentationCache.matches(
                                     activeMap,
                                     activePresentationRevision)) {
    activePresentation = activePresentationCache.presentation;
    activePresentationStatus = {true, "ok", ""};
  } else {
    activePresentationCache.clear();
    snapshot.activeMap = activeMap;
    activePresentationStatus = installer.readActiveMapPresentation(
        activeMap, activePresentation);
    if (activePresentationStatus.ok) {
      map_transfer::MapPresentationRevision presentedRevision;
      if (installer.readActiveMapPresentationRevision(
              activeMap, presentedRevision) &&
          activeMap.mapId == snapshot.activeMap.mapId &&
          activeMap.sessionId == snapshot.activeMap.sessionId &&
          activeMap.root == snapshot.activeMap.root &&
          activeMap.manifestReceipt == snapshot.activeMap.manifestReceipt &&
          activeMap.signedManifestReceipt ==
              snapshot.activeMap.signedManifestReceipt &&
          activePresentationRevision.bytes == presentedRevision.bytes &&
          activePresentationRevision.modifiedSeconds ==
              presentedRevision.modifiedSeconds &&
          activePresentationRevision.inode == presentedRevision.inode) {
        activePresentationCache.store(activeMap, activePresentation,
                                      presentedRevision);
      }
    }
  }

  if (!activePresentationStatus.ok) {
    snapshot.available = false;
    snapshot.errorCode = activePresentationStatus.code;
    return snapshot;
  }

  snapshot.available = true;
  snapshot.errorCode.clear();
  snapshot.activeMap = activeMap;
  snapshot.presentation = activePresentation;
  return snapshot;
}

static void appendActiveMapPresentationStatus(
    std::string &body,
    const map_transfer::MapPresentationMetadata &activePresentation) {
  map_transfer_status_protocol::ActiveMapPresentation presentation;
  presentation.displayName = activePresentation.displayName;
  presentation.boundsE7 = activePresentation.boundsE7;
  presentation.hasBoundsE7 = activePresentation.hasBoundsE7;
  map_transfer_status_protocol::appendActiveMapPresentation(body,
                                                            presentation);
}

// Do not let link-time optimization merge this back into the filesystem phase.
__attribute__((noinline)) static std::string composeMapTransferStatusJson(
    const ActiveMapStatusSnapshot &activeMapStatus) {
  map_transfer::HttpTransferStatus transferStatus = mapTransferHttp.status();
  const map_transfer::ActiveMapSelection &activeMap =
      activeMapStatus.activeMap;
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
                     ",\"protocols\":" +
                     (streamSupported ? "[2]" : "[]") +
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

  body += ",\"transferGeneration\":" +
          std::to_string(transferStatus.transferGeneration) +
          ",\"tls\":{\"identityVersion\":" +
          std::to_string(transferStatus.tlsIdentityVersion) +
          ",\"certificateSha256\":\"" +
          jsonEscape(transferStatus.tlsCertificateSha256) + "\"}" +
          ",\"capabilities\":{\"secureTransferV1\":" +
          (transferStatus.secureTransferV1 ? "true" : "false") +
          ",\"signedMapStreamV1\":" +
          (transferStatus.signedMapStreamV1 ? "true" : "false") +
          ",\"legacyArchivePolicy\":\"" +
          jsonEscape(transferStatus.legacyArchivePolicy) + "\"}";

  if (!transferStatus.baseUrl.empty()) {
    body += ",\"baseUrl\":\"" + jsonEscape(transferStatus.baseUrl) + "\"";
  }

  if (!transferStatus.apSsid.empty()) {
    body += ",\"apSsid\":\"" + jsonEscape(transferStatus.apSsid) + "\"";
  }
  if (!transferStatus.networkTransport.empty()) {
    body += ",\"networkTransport\":\"" +
            jsonEscape(transferStatus.networkTransport) + "\"";
  }
  if (!transferStatus.networkSsid.empty()) {
    body += ",\"networkSsid\":\"" +
            jsonEscape(transferStatus.networkSsid) + "\"";
  }
  if (transferStatus.hotspotFallback) {
    body += ",\"hotspotFallback\":true";
  }
  if (!transferStatus.hotspotFallbackReason.empty()) {
    body += ",\"hotspotFallbackReason\":\"" +
            jsonEscape(transferStatus.hotspotFallbackReason) + "\"";
  }
  if (activeMapStatus.available) {
    body += ",\"activeMapId\":\"" + jsonEscape(activeMap.mapId) + "\"";
    if (!activeMap.sessionId.empty()) {
      body += ",\"activeSessionId\":\"" +
              jsonEscape(activeMap.sessionId) + "\"";
    }
    if (!activeMap.manifestReceipt.empty()) {
      body += ",\"activeManifestReceipt\":\"" +
              jsonEscape(activeMap.manifestReceipt) + "\"";
    }
    appendActiveMapPresentationStatus(body, activeMapStatus.presentation);
    if (activeMap.target.formatVersion != 0) {
      body += ",\"activeRendererFormat\":" +
              std::to_string(activeMap.target.formatVersion) +
              ",\"labelProfileVersion\":" +
              std::to_string(activeMap.target.labelProfileVersion) +
              ",\"labelLanguages\":[";
      for (size_t index = 0; index < activeMap.target.labelLanguages.size();
           ++index) {
        if (index != 0)
          body += ",";
        body +=
            "\"" + jsonEscape(activeMap.target.labelLanguages[index]) + "\"";
      }
      body += "],\"fontAssetHealthy\":";
      body += activeMap.target.formatVersion >= 2 &&
                      mapView.debugStreetLabelFontHealthy()
                  ? "true"
                  : "false";
    }
  } else {
    body += ",\"activeError\":{\"code\":\"" +
            jsonEscape(activeMapStatus.errorCode) +
            "\"}";
  }

  body += ",\"activation\":" + mapTransferHttp.activationStatusJson(true);

  if (!transferStatus.lastErrorCode.empty() &&
      !mapTransferHttp.activationHasError()) {
    body += ",\"lastError\":{\"code\":\"" +
            jsonEscape(transferStatus.lastErrorCode) + "\",\"sequence\":" +
            std::to_string(transferStatus.errorSequence) + "}";
  }

  body += "}";
  return body;
}

static std::string mapTransferStatusJson() {
  return composeMapTransferStatusJson(readActiveMapStatusSnapshot());
}

static std::string genericTransferStatusJson() {
  device_transfer::HttpTransferStatus transferStatus =
      deviceTransferHttp.status();
  std::string body = std::string("{\"configured\":") +
                     (transferStatus.configured ? "true" : "false") +
                     ",\"enabled\":" +
                     (transferStatus.enabled ? "true" : "false") +
                     ",\"port\":" + std::to_string(transferStatus.port) +
                     ",\"mode\":\"" + jsonEscape(transferStatus.mode) + "\"" +
                     ",\"transferGeneration\":" +
                     std::to_string(transferStatus.transferGeneration) +
                     ",\"tls\":{\"identityVersion\":" +
                     std::to_string(transferStatus.tlsIdentityVersion) +
                     ",\"certificateSha256\":\"" +
                     jsonEscape(transferStatus.tlsCertificateSha256) + "\"}" +
                     ",\"capabilities\":{\"secureTransferV1\":" +
                     (transferStatus.secureTransferV1 ? "true" : "false") +
                     ",\"signedMapStreamV1\":" +
                     (transferStatus.signedMapStreamV1 ? "true" : "false") +
                     ",\"legacyArchivePolicy\":\"" +
                     jsonEscape(transferStatus.legacyArchivePolicy) + "\"}";

  if (transferStatus.pendingTlsIdentityVersion != 0 &&
      !transferStatus.pendingTlsCertificateSha256.empty()) {
    body += ",\"pendingTls\":{\"identityVersion\":" +
            std::to_string(transferStatus.pendingTlsIdentityVersion) +
            ",\"certificateSha256\":\"" +
            jsonEscape(transferStatus.pendingTlsCertificateSha256) + "\"}";
  }

  if (!transferStatus.baseUrl.empty()) {
    body += ",\"baseUrl\":\"" + jsonEscape(transferStatus.baseUrl) + "\"";
  }
  if (!transferStatus.apSsid.empty()) {
    body += ",\"apSsid\":\"" + jsonEscape(transferStatus.apSsid) + "\"";
  }
  if (!transferStatus.apPassphrase.empty()) {
    body += ",\"apPassphrase\":\"" +
            jsonEscape(transferStatus.apPassphrase) + "\"";
  }
  if (!transferStatus.networkTransport.empty()) {
    body += ",\"networkTransport\":\"" +
            jsonEscape(transferStatus.networkTransport) + "\"";
  }
  if (!transferStatus.networkSsid.empty()) {
    body += ",\"networkSsid\":\"" +
            jsonEscape(transferStatus.networkSsid) + "\"";
  }
  if (transferStatus.hotspotFallback) {
    body += ",\"hotspotFallback\":true";
  }
  if (!transferStatus.hotspotFallbackReason.empty()) {
    body += ",\"hotspotFallbackReason\":\"" +
            jsonEscape(transferStatus.hotspotFallbackReason) + "\"";
  }
  if (!transferStatus.sessionToken.empty()) {
    body += ",\"sessionToken\":\"" + jsonEscape(transferStatus.sessionToken) +
            "\"";
  }
  if (!transferStatus.lastErrorCode.empty()) {
    body += ",\"lastError\":{\"code\":\"" +
            jsonEscape(transferStatus.lastErrorCode) + "\",\"message\":\"" +
            jsonEscape(transferStatus.lastErrorMessage) +
            "\",\"sequence\":" +
            std::to_string(transferStatus.errorSequence) + "}";
  }
  body += ",\"storage\":{\"backend\":\"" +
          jsonEscape(storage.storageBackendName()) +
          "\",\"powerCycleRequired\":" +
          (storage.storagePowerCycleRequired() ? "true" : "false") + "}";
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
  if (pendingMapTransferStatusChunks.active()) {
    pumpPendingMapTransferStatusChunks();
    return;
  }

  static map_transfer_status_protocol::ChunkSession chunkSession;
  const std::string body = mapTransferStatusJson();
  const std::string legacy = "MSTS" + body;
  const uint16_t peerMtu = activePeerMtu.load(std::memory_order_acquire);
  if (peerMtu >= 25 && legacy.size() <= peerMtu - 25 &&
      notifyAuthenticatedNavigation(
          pChar, reinterpret_cast<const uint8_t *>(legacy.data()),
          legacy.size())) {
    Serial.printf("BLE Map Transfer: status notified (%u bytes, MTU %u)\n",
                  (unsigned)legacy.size(), (unsigned)peerMtu);
    return;
  }
  const size_t chunkBytes =
      map_transfer_status_protocol::chunkPayloadBytes(peerMtu);
  if (chunkBytes == 0) {
    Serial.printf(
        "BLE Map Transfer: MTU %u cannot carry authenticated status chunks\n",
        static_cast<unsigned>(peerMtu));
    return;
  }
  const size_t chunkCount = (body.size() + chunkBytes - 1) / chunkBytes;
  if (chunkCount == 0 || chunkCount > 255) {
    Serial.printf("BLE Map Transfer: status too large (%u bytes)\n",
                  (unsigned)body.size());
    return;
  }
  const uint8_t transferId = chunkSession.transferIdFor(body);
  if (!pendingMapTransferStatusChunks.begin(body, transferId, chunkBytes)) {
    Serial.printf("BLE Map Transfer: status too large (%u bytes)\n",
                  (unsigned)body.size());
    return;
  }
  pendingMapTransferStatusContinuation.store(true,
                                             std::memory_order_release);
  pumpPendingMapTransferStatusChunks();
}

static void pumpPendingMapTransferStatusChunks() {
  if (!pendingMapTransferStatusChunks.active()) {
    pendingMapTransferStatusContinuation.store(false,
                                               std::memory_order_release);
    return;
  }
  if (!bleSessionAuthenticated ||
      activeConnHandle == BLE_HS_CONN_HANDLE_NONE ||
      mapTransferStatusCharacteristic == nullptr) {
    pendingMapTransferStatusChunks.reset();
    pendingMapTransferStatusContinuation.store(false,
                                               std::memory_order_release);
    return;
  }

  const uint8_t available = deferredNotificationAvailableCapacity();
  for (uint8_t slot = 0;
       slot < available && pendingMapTransferStatusChunks.active(); ++slot) {
    const std::string frame = pendingMapTransferStatusChunks.nextFrame();
    if (frame.empty() ||
        !notifyAuthenticatedNavigation(
            mapTransferStatusCharacteristic,
            reinterpret_cast<const uint8_t *>(frame.data()), frame.size())) {
      return;
    }
    pendingMapTransferStatusChunks.advance();
  }

  if (!pendingMapTransferStatusChunks.active()) {
    pendingMapTransferStatusChunks.reset();
    pendingMapTransferStatusContinuation.store(false,
                                               std::memory_order_release);
  }
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

static void notifyRendererDiagnosticsStatus(NimBLECharacteristic *pChar) {
#if FIRMWARE_DIAGNOSTICS
  if (pChar == nullptr) {
    pChar = mapTransferStatusCharacteristic;
  }
  if (pChar == nullptr ||
      !bleSessionSupportsRendererDiagnostics.load(std::memory_order_acquire)) {
    return;
  }

  const std::string body = renderer_diagnostics::toJson(
      renderer_diagnostics::snapshot(millis()));
  if (body.empty()) {
    Serial.println(
        "BLE Renderer Diagnostics: snapshot serialization unavailable");
    return;
  }
  const uint16_t peerMtu = activePeerMtu.load(std::memory_order_acquire);
  if (peerMtu >= 25 &&
      body.size() + renderer_diagnostics_ble_protocol::PREFIX_BYTES <=
          peerMtu - 25) {
    const std::string direct =
        std::string(
            renderer_diagnostics_ble_protocol::METRICS_RESPONSE_PREFIX) +
        body;
    if (notifyAuthenticatedNavigation(
            pChar, reinterpret_cast<const uint8_t *>(direct.data()),
            direct.size())) {
      Serial.printf(
          "BLE Renderer Diagnostics: snapshot notified (%u bytes)\n",
          static_cast<unsigned>(body.size()));
      return;
    }
  }

  const size_t chunkBytes =
      map_transfer_status_protocol::chunkPayloadBytes(peerMtu);
  const size_t chunkCount =
      chunkBytes == 0 ? 0 : (body.size() + chunkBytes - 1) / chunkBytes;
  if (chunkCount == 0 || chunkCount > 255) {
    Serial.printf(
        "BLE Renderer Diagnostics: snapshot cannot fit MTU %u (%u bytes)\n",
        static_cast<unsigned>(peerMtu), static_cast<unsigned>(body.size()));
    return;
  }
  static uint8_t transferId = 0;
  ++transferId;
  for (size_t index = 0; index < chunkCount; ++index) {
    const size_t offset = index * chunkBytes;
    const size_t length = std::min(chunkBytes, body.size() - offset);
    std::string frame =
        renderer_diagnostics_ble_protocol::METRICS_CHUNK_PREFIX;
    frame.push_back(static_cast<char>(transferId));
    frame.push_back(static_cast<char>(index));
    frame.push_back(static_cast<char>(chunkCount));
    frame.append(body.data() + offset, length);
    if (!notifyAuthenticatedNavigation(
            pChar, reinterpret_cast<const uint8_t *>(frame.data()),
            frame.size())) {
      Serial.println(
          "BLE Renderer Diagnostics: protected snapshot chunk failed");
      return;
    }
    delay(2);
  }
  Serial.printf(
      "BLE Renderer Diagnostics: snapshot notified (%u bytes, %u chunks)\n",
      static_cast<unsigned>(body.size()),
      static_cast<unsigned>(chunkCount));
#else
  (void)pChar;
#endif
}

static void queueTransferControl(ble_transfer::Action action,
                                 uint8_t notifications) {
  pendingTransferControl.merge(action, notifications);
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
}

static void queueTlsRotationControl(ble_transfer::Action action,
                                    const std::string &fingerprint = "") {
  portENTER_CRITICAL(&pendingTlsRotationMux);
  std::memset(pendingTlsRotationFingerprint, 0,
              sizeof(pendingTlsRotationFingerprint));
  if (fingerprint.size() ==
      device_transfer::TLS_CERTIFICATE_SHA256_HEX_BYTES) {
    std::memcpy(pendingTlsRotationFingerprint, fingerprint.data(),
                fingerprint.size());
  }
  portEXIT_CRITICAL(&pendingTlsRotationMux);
  queueTransferControl(action, ble_transfer::NotifyGeneric);
}

static std::string pendingTlsRotationFingerprintSnapshot() {
  char fingerprint[sizeof(pendingTlsRotationFingerprint)] = {};
  portENTER_CRITICAL(&pendingTlsRotationMux);
  std::memcpy(fingerprint, pendingTlsRotationFingerprint,
              sizeof(fingerprint));
  portEXIT_CRITICAL(&pendingTlsRotationMux);
  return fingerprint;
}

static bool handleRendererDiagnosticsCommand(const std::string &value,
                                             const char *authLabel) {
  const bool metricsPrefix =
      value.size() >= renderer_diagnostics_ble_protocol::PREFIX_BYTES &&
      std::memcmp(value.data(),
                  renderer_diagnostics_ble_protocol::METRICS_REQUEST_PREFIX,
                  renderer_diagnostics_ble_protocol::PREFIX_BYTES) == 0;
  const bool markerPrefix =
      renderer_diagnostics_ble_protocol::hasRouteMarkerPrefix(
          reinterpret_cast<const uint8_t *>(value.data()), value.size());
  const bool windowPrefix =
      renderer_diagnostics_ble_protocol::hasWindowRequestPrefix(
          reinterpret_cast<const uint8_t *>(value.data()), value.size());
  if (!metricsPrefix && !markerPrefix && !windowPrefix)
    return false;

  power_metrics::noteBlePacket(power_metrics::BlePacketClass::Control);
  if (!requireAuthenticated(authLabel))
    return true;

#if !FIRMWARE_DIAGNOSTICS
  Serial.println("BLE Renderer Diagnostics: unavailable in this build");
  return true;
#else
  if (!bleSessionSupportsRendererDiagnostics.load(std::memory_order_acquire)) {
    Serial.println("BLE Renderer Diagnostics: capability was not negotiated");
    return true;
  }
  if (metricsPrefix) {
    if (!renderer_diagnostics_ble_protocol::isMetricsRequest(
            reinterpret_cast<const uint8_t *>(value.data()), value.size())) {
      Serial.println("BLE Renderer Diagnostics: malformed metrics request");
      return true;
    }
    constexpr uint32_t kMinimumMetricsRequestIntervalMs = 1000;
    const uint32_t nowMs = millis();
    const uint32_t previousMs =
        lastRendererMetricsRequestMs.load(std::memory_order_acquire);
    if (previousMs != 0 &&
        static_cast<uint32_t>(nowMs - previousMs) <
            kMinimumMetricsRequestIntervalMs) {
      Serial.println("BLE Renderer Diagnostics: metrics request rate limited");
      return true;
    }
    lastRendererMetricsRequestMs.store(nowMs, std::memory_order_release);
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyRendererDiagnostics);
    return true;
  }

  if (windowPrefix) {
    renderer_diagnostics_ble_protocol::WindowRequest request;
    if (!renderer_diagnostics_ble_protocol::decodeWindowRequest(
            reinterpret_cast<const uint8_t *>(value.data()), value.size(),
            request)) {
      Serial.println("BLE Renderer Diagnostics: malformed window request");
      return true;
    }
    constexpr uint32_t kMinimumWindowRequestIntervalMs = 1000;
    const uint32_t nowMs = millis();
    const uint32_t previousMs =
        lastRendererWindowRequestMs.load(std::memory_order_acquire);
    const uint8_t previousProfile =
        lastRendererWindowRequestProfile.load(std::memory_order_acquire);
    const bool cleanup =
        renderer_diagnostics_ble_protocol::isCurrentProfileCleanup(
            request, previousProfile);
    if (previousMs != 0 &&
        static_cast<uint32_t>(nowMs - previousMs) <
            kMinimumWindowRequestIntervalMs &&
        !cleanup) {
      Serial.println("BLE Renderer Diagnostics: window request rate limited");
      return true;
    }
    lastRendererWindowRequestMs.store(nowMs, std::memory_order_release);
    lastRendererWindowRequestProfile.store(request.profile,
                                           std::memory_order_release);
    queueRendererWindowRequest(request);
    return true;
  }

  renderer_diagnostics_ble_protocol::RouteMarker marker;
  if (!renderer_diagnostics_ble_protocol::decodeRouteMarker(
          reinterpret_cast<const uint8_t *>(value.data()), value.size(),
          marker)) {
    Serial.println("BLE Renderer Diagnostics: malformed route marker");
    return true;
  }
  const bool accepted = renderer_diagnostics::noteRouteMarker(
      marker.fixtureSha256, sizeof(marker.fixtureSha256), marker.sampleIndex,
      marker.sampleCount, marker.loop, millis());
  if (!accepted)
    Serial.println("BLE Renderer Diagnostics: route marker rejected");
  return true;
#endif
}

static void cancelDiagnosticsSessionStart() {
  if (diagnosticsSessionMutex != nullptr &&
      xSemaphoreTake(diagnosticsSessionMutex, portMAX_DELAY) == pdTRUE) {
    diagnosticsSessionStartGeneration.fetch_add(1, std::memory_order_acq_rel);
    xSemaphoreGive(diagnosticsSessionMutex);
    return;
  }
  diagnosticsSessionStartGeneration.fetch_add(1, std::memory_order_acq_rel);
}

static void diagnosticsSessionStartTask(void *context) {
  const uint32_t generation = static_cast<uint32_t>(
      reinterpret_cast<uintptr_t>(context));
  const ride_diagnostics::transfer_policy::StoragePreparation storageResult =
      storage.prepareDiagnosticsStorage();
  const bool storageReady =
      ride_diagnostics::transfer_policy::storageReady(storageResult);
  const ride_diagnostics::transfer_policy::SealPreparation sealResult =
      storageReady ? ride_diagnostics::sealActiveChunkForTransfer()
                   : ride_diagnostics::transfer_policy::SealPreparation::
                         StorageUnavailable;
  const bool ready = storageReady &&
                     ride_diagnostics::transfer_policy::sealReady(sealResult);

  bool stillCurrent = false;
  if (diagnosticsSessionMutex != nullptr &&
      xSemaphoreTake(diagnosticsSessionMutex, portMAX_DELAY) == pdTRUE) {
    stillCurrent =
        diagnosticsSessionStartGeneration.load(std::memory_order_acquire) ==
            generation &&
        bleNavServer.isConnected() &&
        bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire);
    if (ready && stillCurrent && !deviceTransferHttp.status().enabled) {
      const bool enabled = deviceTransferHttp.setEnabled(true, "diagnostics");
      if (!enabled) {
        deviceTransferHttp.setLastError(
            "diagnostics_start_failed",
            "diagnostics storage was ready but the transfer server did not start");
      }
      (void)ride_diagnostics::record(
          enabled ? ride_diagnostics::Level::Info
                  : ride_diagnostics::Level::Warning,
          "transfer", "diagnostics_transfer_entered",
          enabled
              ? (ride_diagnostics::transfer_policy::usingInternalFallback(
                     storageResult)
                     ? "{\"active\":true,\"mode\":\"diagnostics\",\"storage\":\"internal_ffat\"}"
                     : "{\"active\":true,\"mode\":\"diagnostics\",\"storage\":\"removable_sd\"}")
              : "{\"active\":false,\"mode\":\"diagnostics\",\"code\":\"diagnostics_start_failed\"}");
      Serial.printf(
          "BLE Device Transfer: diagnostics async enter applied, enabled=%d\n",
          enabled);
    } else if (stillCurrent) {
      const ride_diagnostics::transfer_policy::Failure failure =
          storageReady
              ? ride_diagnostics::transfer_policy::sealFailure(sealResult)
              : ride_diagnostics::transfer_policy::storageFailure(
                    storageResult);
      deviceTransferHttp.setLastError(
          ready ? "transfer_busy" : failure.code,
          ready ? "another transfer mode became active" : failure.message);
      Serial.println(
          "BLE Device Transfer: diagnostics async enter failed");
      char fields[192] = {};
      snprintf(fields, sizeof(fields),
               "{\"active\":false,\"mode\":\"diagnostics\",\"code\":\"%s\"}",
               ready ? "transfer_busy" : failure.code);
      (void)ride_diagnostics::record(
          ride_diagnostics::Level::Warning, "transfer",
          "diagnostics_transfer_entered", fields);
    }
    xSemaphoreGive(diagnosticsSessionMutex);
  }
  if (diagnosticsSessionActiveGeneration.load(std::memory_order_acquire) ==
      generation) {
    diagnosticsSessionStartInProgress.store(false,
                                            std::memory_order_release);
  }
  vTaskDelete(nullptr);
}

static bool startDiagnosticsSessionAsync() {
  if (diagnosticsSessionStartInProgress.exchange(
          true, std::memory_order_acq_rel)) {
    return diagnosticsSessionActiveGeneration.load(
               std::memory_order_acquire) ==
           diagnosticsSessionStartGeneration.load(
               std::memory_order_acquire);
  }
  const uint32_t generation =
      diagnosticsSessionStartGeneration.fetch_add(
          1, std::memory_order_acq_rel) +
      1;
  diagnosticsSessionActiveGeneration.store(generation,
                                           std::memory_order_release);
  if (xTaskCreatePinnedToCore(
          diagnosticsSessionStartTask, "diagnostics_start", 6144,
          reinterpret_cast<void *>(static_cast<uintptr_t>(generation)), 1,
          nullptr, 0) != pdPASS) {
    diagnosticsSessionStartInProgress.store(false,
                                            std::memory_order_release);
    diagnosticsSessionActiveGeneration.store(0,
                                              std::memory_order_release);
    return false;
  }
  return true;
}

static uint64_t currentAuthenticatedTransferSessionId() {
  if (!bleSessionAuthenticated || !deviceOwnershipReady ||
      deviceOwnershipMutex == nullptr ||
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    return 0;
  }
  const uint64_t sessionId = deviceOwnership.authenticatedOwnerSessionId();
  xSemaphoreGive(deviceOwnershipMutex);
  return sessionId;
}

static void processPendingTransferControl() {
  const ble_transfer::Request request = pendingTransferControl.take();
  if (request.empty()) {
    return;
  }

  if (request.disconnectCleanup) {
    cancelDiagnosticsSessionStart();
    // Session credentials and request authorization were synchronously revoked
    // by the BLE disconnect callback. Finish mode-specific cleanup here.
    const std::string mode = deviceTransferHttp.status().mode;
    bool disabled = true;
    if (mode == "map") {
      disabled = mapTransferHttp.setEnabled(false);
    } else if (mode == "firmware") {
      disabled = firmwareUpdateHttp.setEnabled(false);
    } else if (mode == "debug" || mode == "diagnostics" ||
               device_debug::frameStore().active()) {
      disabled = stopActiveDeviceTransfer();
    }
    Serial.printf("BLE Device Transfer: disconnect cleanup applied, "
                  "mode=%s disabled=%d\n",
                  mode.c_str(), disabled);
  }

  const bool requiresAuthenticatedTransferBinding =
      request.action == ble_transfer::Action::EnableMap ||
      request.action == ble_transfer::Action::EnableFirmware ||
      request.action == ble_transfer::Action::EnableDebug ||
      request.action == ble_transfer::Action::EnableDiagnostics ||
      request.action == ble_transfer::Action::PrepareTlsIdentity ||
      request.action == ble_transfer::Action::CommitTlsIdentity ||
      request.action == ble_transfer::Action::CancelTlsIdentity;
  if (requiresAuthenticatedTransferBinding &&
      !deviceTransferHttp.bindAuthenticatedBleSession(
          currentAuthenticatedTransferSessionId())) {
    deviceTransferHttp.setLastError(
        "ble_owner_required",
        "device transfer requires the authenticated owner BLE session");
    if (request.notifications & ble_transfer::NotifyMap)
      notifyMapTransferStatus(mapTransferStatusCharacteristic);
    if (request.notifications & ble_transfer::NotifyGeneric)
      notifyGenericTransferStatus(mapTransferStatusCharacteristic);
    Serial.println(
        "BLE Device Transfer: enter rejected, owner session unavailable");
    return;
  }
  if (requiresAuthenticatedTransferBinding &&
      diagnosticsSessionStartInProgress.load(std::memory_order_acquire)) {
    deviceTransferHttp.setLastError(
        "transfer_busy", "device diagnostics are still preparing storage");
    Serial.println(
        "BLE Device Transfer: enter rejected, diagnostics are preparing");
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
    } else {
      const bool transitionReady =
          ride_diagnostics::beginStorageTransition();
      if (!transitionReady) {
        mapTransferHttp.setLastError(
            "sd_unavailable",
            "diagnostic storage could not checkpoint before remounting SD");
        Serial.println(
            "BLE Map Transfer: enter rejected, diagnostics checkpoint failed");
      } else {
        const bool mounted = storage.ensureSdMounted();
        if (!mounted) {
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
          Serial.printf("BLE Map Transfer: enter applied, enabled=%d\n",
                        enabled);
          (void)ride_diagnostics::record(
              enabled ? ride_diagnostics::Level::Info
                      : ride_diagnostics::Level::Warning,
              "map", "transfer_entered",
              enabled ? "{\"active\":true}" : "{\"active\":false}");
        }
        ride_diagnostics::endStorageTransition();
      }
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
      (void)ride_diagnostics::record(
          enabled ? ride_diagnostics::Level::Info
                  : ride_diagnostics::Level::Warning,
          "transfer", "firmware_transfer_entered",
          enabled ? "{\"active\":true,\"mode\":\"firmware\"}"
                  : "{\"active\":false,\"mode\":\"firmware\"}");
    }
    break;
  }
  case ble_transfer::Action::EnableDebug: {
    const device_transfer::HttpTransferStatus transferStatus =
        deviceTransferHttp.status();
    if (transferStatus.enabled && transferStatus.mode != "debug") {
      deviceTransferHttp.setLastError("transfer_busy",
                                      "another transfer mode is active");
      Serial.println(
          "BLE Device Transfer: debug enter rejected, transfer is busy");
    } else if (transferStatus.enabled && transferStatus.mode == "debug") {
      Serial.println("BLE Device Transfer: debug enter already applied");
    } else {
      const bool enabled = startRemoteDeviceDebugSession();
      Serial.printf("BLE Device Transfer: debug enter applied, enabled=%d\n",
                    enabled);
      (void)ride_diagnostics::record(
          enabled ? ride_diagnostics::Level::Info
                  : ride_diagnostics::Level::Warning,
          "transfer", "debug_transfer_entered",
          enabled ? "{\"active\":true,\"mode\":\"debug\"}"
                  : "{\"active\":false,\"mode\":\"debug\"}");
    }
    break;
  }
  case ble_transfer::Action::EnableDiagnostics: {
    const device_transfer::HttpTransferStatus transferStatus =
        deviceTransferHttp.status();
    if (!bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire)) {
      deviceTransferHttp.setLastError(
          "ride_diagnostics_unsupported",
          "this firmware or client has no ride diagnostics capability");
      Serial.println("BLE Device Transfer: diagnostics unsupported");
    } else if (transferStatus.enabled && transferStatus.mode != "diagnostics") {
      deviceTransferHttp.setLastError("transfer_busy",
                                      "another transfer mode is active");
      Serial.println(
          "BLE Device Transfer: diagnostics enter rejected, transfer is busy");
    } else if (transferStatus.enabled && transferStatus.mode == "diagnostics") {
      Serial.println("BLE Device Transfer: diagnostics enter already applied");
    } else if (!startDiagnosticsSessionAsync()) {
      deviceTransferHttp.setLastError(
          "diagnostics_seal_failed",
          "device diagnostics could not start the storage checkpoint task");
      Serial.println(
          "BLE Device Transfer: diagnostics enter rejected, task unavailable");
    } else {
      Serial.println(
          "BLE Device Transfer: diagnostics enter preparing asynchronously");
    }
    break;
  }
  case ble_transfer::Action::PrepareTlsIdentity: {
    const bool prepared = deviceTransferHttp.prepareTlsIdentityRotation();
    if (!prepared) {
      deviceTransferHttp.setLastError(
          "tls_rotation_prepare",
          "TLS identity rotation could not be prepared while transfer is active");
    }
    Serial.printf("BLE Device Transfer: TLS rotation prepare applied=%d\n",
                  prepared);
    break;
  }
  case ble_transfer::Action::CommitTlsIdentity: {
    const std::string fingerprint =
        pendingTlsRotationFingerprintSnapshot();
    const bool committed = deviceTransferHttp.commitTlsIdentityRotation(
        fingerprint);
    if (!committed) {
      deviceTransferHttp.setLastError(
          "tls_rotation_commit",
          "TLS identity rotation fingerprint did not match pending identity");
    }
    Serial.printf("BLE Device Transfer: TLS rotation commit applied=%d\n",
                  committed);
    break;
  }
  case ble_transfer::Action::CancelTlsIdentity: {
    const bool cancelled = deviceTransferHttp.cancelTlsIdentityRotation();
    if (!cancelled) {
      deviceTransferHttp.setLastError(
          "tls_rotation_cancel",
          "TLS identity rotation could not be cancelled");
    }
    Serial.printf("BLE Device Transfer: TLS rotation cancel applied=%d\n",
                  cancelled);
    break;
  }
  case ble_transfer::Action::DisableMap: {
    bool disabled = true;
    if (deviceTransferHttp.status().mode == "map") {
      disabled = mapTransferHttp.setEnabled(false);
    }
    Serial.printf("BLE Map Transfer: exit applied, disabled=%d\n", disabled);
    (void)ride_diagnostics::record(
        disabled ? ride_diagnostics::Level::Info
                 : ride_diagnostics::Level::Warning,
        "map", "transfer_exited",
        disabled ? "{\"active\":false}" : "{\"active\":true}");
    break;
  }
  case ble_transfer::Action::DisableAll: {
    cancelDiagnosticsSessionStart();
    const bool disabled = stopActiveDeviceTransfer();
    Serial.printf("BLE Device Transfer: exit applied, disabled=%d\n",
                  disabled);
    (void)ride_diagnostics::record(
        disabled ? ride_diagnostics::Level::Info
                 : ride_diagnostics::Level::Warning,
        "transfer", "transfer_exited",
        disabled ? "{\"active\":false}" : "{\"active\":true}");
    break;
  }
  case ble_transfer::Action::DisableOnBleDisconnect: {
    // This action is consumed into Request::disconnectCleanup by merge().
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
  if (request.notifications & ble_transfer::NotifyRendererDiagnostics) {
    notifyRendererDiagnosticsStatus(mapTransferStatusCharacteristic);
  }
}

static void notifyDeviceCapabilities(NimBLECharacteristic *pChar,
                                     bool includePowerButtonConfig,
                                     uint8_t clientVersion) {
  if (pChar == nullptr) {
    pChar = mapTransferStatusCharacteristic;
  }
  if (pChar == nullptr) {
    return;
  }

  const bool speakerAvailable = waveshare_board::speaker::isAvailable();
  const bool powerButtonHonkAvailable =
      waveshare_board::speaker::isPowerButtonHonkAvailable();
  uint8_t response[device_capabilities_protocol::CAP2_MAX_BYTES] = {
      'C', 'A', 'P', 'S',
      static_cast<uint8_t>(
          waveshare_board::speaker::capabilityFlags(
              speakerAvailable, powerButtonHonkAvailable,
              powerButtonHonkAvailable) |
          map_profile_protocol::CAPABILITY_MASK |
          CAPABILITY_EXTENDED_MAP_VISIBILITY |
          CAPABILITY_BATTERY_STATUS_SCREEN |
          destination_picker_protocol::CAPABILITY_MASK |
          workout_telemetry_protocol::CAPABILITY_MASK),
  };
  size_t responseSize = 5;
  waveshare_board::speaker::PowerButtonHonkConfig config{};
  uint8_t powerPayload[
      waveshare_board::speaker::POWER_BUTTON_HONK_PAYLOAD_SIZE]{};
  if (includePowerButtonConfig && powerButtonHonkAvailable) {
    if (!waveshare_board::speaker::getPowerButtonHonkConfig(config) ||
        !waveshare_board::speaker::encodePowerButtonHonkPayload(
            config, powerPayload,
            waveshare_board::speaker::POWER_BUTTON_HONK_PAYLOAD_SIZE)) {
      Serial.println("BLE Capabilities: PWR config unavailable; retry required");
      return;
    }
  }
  const bool useCap2 =
      clientVersion >= device_capabilities_protocol::CAP2_CLIENT_VERSION;
  const uint8_t extendedCapabilityFlags =
      map_profile_protocol::extendedCapabilityFlagsForClient(clientVersion);
  if (useCap2) {
    bool scopedWatchControllerReady = false;
    if (deviceOwnershipReady &&
        (deviceOwnershipMutex == nullptr ||
         xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(100)) !=
             pdTRUE)) {
      Serial.println(
          "BLE Capabilities: ownership state unavailable; retry required");
      return;
    }
    if (deviceOwnershipReady) {
      scopedWatchControllerReady =
          deviceOwnership.watchControllerSubsystemReady();
      xSemaphoreGive(deviceOwnershipMutex);
    }
    uint32_t featureFlags =
        static_cast<uint32_t>(response[4]) |
        device_capabilities_protocol::STREET_LABELS_FEATURE |
        device_capabilities_protocol::BIRDS_EYE_MAP_NAVIGATION_FEATURE |
        device_capabilities_protocol::BIRDS_EYE_PERSPECTIVE_FEATURE |
        device_capabilities_protocol::BIRDS_EYE_STRONGER_PERSPECTIVE_FEATURE |
        device_capabilities_protocol::OSM_3D_BUILDINGS_FEATURE;
#ifdef USE_ARDUINO_GFX
    if (clientVersion >= device_capabilities_protocol::
                             AUTOMATIC_DISPLAY_OFF_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::AUTOMATIC_DISPLAY_OFF_FEATURE;
    }
#endif
    if (clientVersion >= device_capabilities_protocol::
                             EXPLICIT_INVALID_GPS_HEADING_CLIENT_VERSION) {
      featureFlags |= device_capabilities_protocol::
          EXPLICIT_INVALID_GPS_HEADING_FEATURE;
    }
    if (scopedWatchControllerReady &&
        clientVersion >= device_capabilities_protocol::
                             SCOPED_WATCH_CONTROLLER_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::SCOPED_WATCH_CONTROLLER_FEATURE;
    }
#if defined(RIDE_AUTOMATION_INTERNAL_CONTROL)
    if (clientVersion >= device_capabilities_protocol::
                             RIDE_AUTOMATION_V2_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::RIDE_AUTOMATION_V2_FEATURE;
    }
#endif
#if DEVICE_REMOTE_DEBUG
    if (deviceDebugHttp.initialized() &&
        clientVersion >= device_capabilities_protocol::
                             REMOTE_DEVICE_DEBUG_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::REMOTE_DEVICE_DEBUG_FEATURE;
    }
#endif
    if (clientVersion >= device_capabilities_protocol::
                             GPS_POSITION_QUALITY_V1_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::GPS_POSITION_QUALITY_V1_FEATURE;
    }
#if FIRMWARE_DIAGNOSTICS
    if (clientVersion >= device_capabilities_protocol::
                             RENDERER_DIAGNOSTICS_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::RENDERER_DIAGNOSTICS_FEATURE;
    }
#endif
#if PERSISTENT_RIDE_DIAGNOSTICS
    if (clientVersion >= device_capabilities_protocol::
                             RIDE_DIAGNOSTICS_CLIENT_VERSION) {
      featureFlags |= device_capabilities_protocol::RIDE_DIAGNOSTICS_FEATURE;
    }
#if defined(RIDE_AUTOMATION_SHADOW)
    if (clientVersion >= device_capabilities_protocol::
                             DETAILED_RIDE_DIAGNOSTICS_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::DETAILED_RIDE_DIAGNOSTICS_FEATURE;
    }
#endif
#endif
    if (clientVersion >= device_capabilities_protocol::
                             RIDE_DELIVERY_ACK_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::RIDE_DELIVERY_ACK_FEATURE;
    }
    responseSize = device_capabilities_protocol::encodeCap2(
        featureFlags, powerPayload,
        includePowerButtonConfig && powerButtonHonkAvailable, response,
        sizeof(response));
    if (responseSize == 0) {
      Serial.println("BLE Capabilities: CAP2 encoding failed");
      return;
    }
  } else {
    if (includePowerButtonConfig && powerButtonHonkAvailable) {
      memcpy(response + responseSize, powerPayload, sizeof(powerPayload));
      responseSize += sizeof(powerPayload);
    }
    if (extendedCapabilityFlags != 0) {
      response[responseSize++] = extendedCapabilityFlags;
    }
  }
  if (!notifyAuthenticatedNavigation(pChar, response, responseSize)) {
    Serial.println("BLE Capabilities: protected notification failed");
    return;
  }
  Serial.printf(
      "BLE Capabilities: notified schema=%s config=%d extended=0x%02X\n",
      useCap2 ? "CAP2" : "CAPS",
      includePowerButtonConfig && powerButtonHonkAvailable ? 1 : 0,
      useCap2 ? 0 : extendedCapabilityFlags);
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
    bleSessionSupportsStreetLabels =
        clientVersion >= device_capabilities_protocol::CAP2_CLIENT_VERSION;
    bleSessionSupports3DBuildings = bleSessionSupportsStreetLabels;
    bleSessionSupportsRideDeliveryAck.store(
        clientVersion >=
            device_capabilities_protocol::RIDE_DELIVERY_ACK_CLIENT_VERSION,
        std::memory_order_release);
    bleSessionSupportsExplicitInvalidGpsHeading.store(
        clientVersion >=
            device_capabilities_protocol::EXPLICIT_INVALID_GPS_HEADING_CLIENT_VERSION,
        std::memory_order_release);
#if FIRMWARE_DIAGNOSTICS
    bleSessionSupportsRendererDiagnostics.store(
        clientVersion >= device_capabilities_protocol::
                             RENDERER_DIAGNOSTICS_CLIENT_VERSION,
        std::memory_order_release);
#else
    bleSessionSupportsRendererDiagnostics.store(false,
                                                std::memory_order_release);
    bleSessionSupportsRideDiagnostics.store(false,
                                            std::memory_order_release);
#endif
#if PERSISTENT_RIDE_DIAGNOSTICS
    bleSessionSupportsRideDiagnostics.store(
        clientVersion >= device_capabilities_protocol::
                          RIDE_DIAGNOSTICS_CLIENT_VERSION,
        std::memory_order_release);
#else
    bleSessionSupportsRideDiagnostics.store(false,
                                            std::memory_order_release);
#endif
    notifyDeviceCapabilities(pChar, includePowerButtonConfig, clientVersion);
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
  ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
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
  device_transfer::LanCredentials lanCredentials;
  device_transfer::LanSessionMode lanMode =
      device_transfer::LanSessionMode::Debug;
  const device_transfer::LanCommandParseResult lanCommand =
      device_transfer::parseTransferLanCommand(data, len, lanMode,
                                               lanCredentials);
  if (lanCommand == device_transfer::LanCommandParseResult::Invalid) {
    deviceTransferHttp.clearPreferredNetwork();
    deviceTransferHttp.setLastError(
        "wifi_credentials",
        "LAN credentials must contain a 1-32 byte SSID and an empty or "
        "8-63 byte password");
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
    Serial.println("BLE Device Transfer: rejected invalid LAN credentials");
    return;
  }
  if (lanCommand == device_transfer::LanCommandParseResult::Valid) {
    if (lanMode == device_transfer::LanSessionMode::Diagnostics) {
#if PERSISTENT_RIDE_DIAGNOSTICS
      if (!bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire)) {
        deviceTransferHttp.setLastError(
            "ride_diagnostics_unsupported",
            "diagnostics capability was not negotiated");
        queueTransferControl(ble_transfer::Action::None,
                             ble_transfer::NotifyGeneric);
      } else if (!deviceTransferHttp.setPreferredNetwork(lanCredentials)) {
        deviceTransferHttp.setLastError(
            "wifi_credentials",
            "LAN credentials could not be applied to this diagnostics session");
        queueTransferControl(ble_transfer::Action::None,
                             ble_transfer::NotifyGeneric);
      } else {
        queueTransferControl(ble_transfer::Action::EnableDiagnostics,
                             ble_transfer::NotifyGeneric);
        Serial.println(
            "BLE Device Transfer: LAN-first diagnostics enter queued");
      }
#else
      deviceTransferHttp.setLastError(
          "ride_diagnostics_unsupported",
          "this firmware has no persistent ride diagnostics");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
#endif
      return;
    }
#if DEVICE_REMOTE_DEBUG
    if (!deviceDebugHttp.initialized()) {
      deviceTransferHttp.setLastError(
          "remote_debug_unavailable",
          "remote debug service did not initialize on this device");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    } else if (!deviceTransferHttp.setPreferredNetwork(lanCredentials)) {
      deviceTransferHttp.setLastError(
          "wifi_credentials",
          "LAN credentials could not be applied to this debug session");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    } else {
      queueTransferControl(ble_transfer::Action::EnableDebug,
                           ble_transfer::NotifyGeneric);
      Serial.println(
          "BLE Device Transfer: LAN-first debug enter queued");
    }
#else
    deviceTransferHttp.setLastError(
        "remote_debug_unsupported",
        "this firmware has no remote debug capability");
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
#endif
    return;
  }

  std::string command;
  if (data != nullptr && len > 0) {
    command.assign(reinterpret_cast<const char *>(data), len);
    command = trimAscii(command);
  }

  if (command == "tls|prepare") {
    queueTlsRotationControl(ble_transfer::Action::PrepareTlsIdentity);
    Serial.println("BLE Device Transfer: TLS rotation prepare queued");
    return;
  }

  constexpr char kTlsCommitPrefix[] = "tls|commit|";
  if (command.rfind(kTlsCommitPrefix, 0) == 0) {
    const std::string fingerprint =
        command.substr(sizeof(kTlsCommitPrefix) - 1);
    if (device_transfer::validTlsCertificateSha256(fingerprint)) {
      queueTlsRotationControl(ble_transfer::Action::CommitTlsIdentity,
                              fingerprint);
      Serial.println("BLE Device Transfer: TLS rotation commit queued");
    } else {
      deviceTransferHttp.setLastError(
          "tls_rotation_fingerprint",
          "TLS rotation commit requires a lowercase SHA-256 fingerprint");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    }
    return;
  }

  if (command == "tls|cancel") {
    queueTlsRotationControl(ble_transfer::Action::CancelTlsIdentity);
    Serial.println("BLE Device Transfer: TLS rotation cancel queued");
    return;
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

  if (command == "enter|debug") {
#if DEVICE_REMOTE_DEBUG
    if (deviceDebugHttp.initialized()) {
      deviceTransferHttp.clearPreferredNetwork();
      queueTransferControl(ble_transfer::Action::EnableDebug,
                           ble_transfer::NotifyGeneric);
      Serial.println("BLE Device Transfer: debug enter queued");
    } else {
      deviceTransferHttp.setLastError(
          "remote_debug_unavailable",
          "remote debug service did not initialize on this device");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    }
#else
    deviceTransferHttp.setLastError(
        "remote_debug_unsupported",
        "this firmware has no remote debug capability");
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
#endif
    return;
  }

  if (command == "enter|diagnostics") {
#if PERSISTENT_RIDE_DIAGNOSTICS
    if (bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire)) {
      deviceTransferHttp.clearPreferredNetwork();
      queueTransferControl(ble_transfer::Action::EnableDiagnostics,
                           ble_transfer::NotifyGeneric);
      Serial.println("BLE Device Transfer: diagnostics enter queued");
    } else {
      deviceTransferHttp.setLastError(
          "ride_diagnostics_unsupported",
          "diagnostics capability was not negotiated");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    }
#else
    deviceTransferHttp.setLastError(
        "ride_diagnostics_unsupported",
        "this firmware has no persistent ride diagnostics");
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
#endif
    return;
  }

  if (command.rfind("capture|", 0) == 0) {
    ride_diagnostics::control::CaptureBinding binding;
    if (!bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire) ||
        !ride_diagnostics::control::parseCaptureBinding(command, binding) ||
        !ride_diagnostics::bindCapture(
            binding.captureId.c_str(),
            binding.mode ==
                ride_diagnostics::control::CaptureMode::Detailed)) {
      deviceTransferHttp.setLastError("capture_rejected",
                                      "capture binding was malformed or unsupported");
    }
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
    return;
  }

  if (command.rfind("mark|", 0) == 0) {
    ride_diagnostics::control::IssueMarker marker;
    if (!bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire) ||
        !ride_diagnostics::control::parseIssueMarker(command, marker) ||
        !ride_diagnostics::markIssue(marker.code.c_str(), marker.sequence)) {
      deviceTransferHttp.setLastError("marker_rejected",
                                      "issue marker was malformed or unsupported");
    }
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
    return;
  }

  if (command == "capture_end") {
    if (bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire))
      ride_diagnostics::clearCapture();
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
    return;
  }

  if (command == "enter|debug|h1|e") {
#if DEVICE_REMOTE_DEBUG
    if (deviceDebugHttp.initialized() &&
        deviceTransferHttp.forceHotspotFallbackAfterEndpointFailure()) {
      queueTransferControl(ble_transfer::Action::EnableDebug,
                           ble_transfer::NotifyGeneric);
      Serial.println(
          "BLE Device Transfer: endpoint-fallback debug enter queued");
    } else {
      deviceTransferHttp.setLastError(
          "remote_debug_unavailable",
          "endpoint-fallback debug session could not be prepared");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    }
#else
    deviceTransferHttp.setLastError(
        "remote_debug_unsupported",
        "this firmware has no remote debug capability");
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
#endif
    return;
  }

  if (command == "enter|diagnostics|h1|e") {
#if PERSISTENT_RIDE_DIAGNOSTICS
    if (bleSessionSupportsRideDiagnostics.load(std::memory_order_acquire) &&
        deviceTransferHttp.forceHotspotFallbackAfterEndpointFailure()) {
      queueTransferControl(ble_transfer::Action::EnableDiagnostics,
                           ble_transfer::NotifyGeneric);
      Serial.println(
          "BLE Device Transfer: endpoint-fallback diagnostics enter queued");
    } else {
      deviceTransferHttp.setLastError(
          "ride_diagnostics_unavailable",
          "endpoint-fallback diagnostics session could not be prepared");
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
    }
#else
    deviceTransferHttp.setLastError(
        "ride_diagnostics_unsupported",
        "this firmware has no persistent ride diagnostics");
    queueTransferControl(ble_transfer::Action::None,
                         ble_transfer::NotifyGeneric);
#endif
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
  power_metrics::noteBlePacket(power_metrics::BlePacketClass::Route);
  if (len == 0) {
    lastRouteHash = 0;
    lastRouteLen = 0;
    Serial.printf("BLE: %s route geometry cleared\n",
                  source == nullptr ? "unknown" : source);
    bleDebugStats.routePacketCount++;
    bleDebugStats.lastRoutePacketMs = millis();
    routeOverlay.clear();
    clearCurrentNavigationData();
    requestMapRender(map_render_policy::Reason::Route);
    return;
  }

  if (data == nullptr) {
    Serial.printf("BLE: Rejected %s route geometry: null payload\n",
                  source == nullptr ? "unknown" : source);
    return;
  }

  if (len >= 8) {
    const bool seedMapStart = !gpsReceivedFromApp;
    int32_t routeStartLat = 0;
    int32_t routeStartLon = 0;
    if (seedMapStart) {
      memcpy(&routeStartLat, data, sizeof(routeStartLat));
      memcpy(&routeStartLon, data + sizeof(routeStartLon),
             sizeof(routeStartLon));
      gps.gpsData.latitude = (double)routeStartLat / 1000000.0;
      gps.gpsData.longitude = (double)routeStartLon / 1000000.0;
    }
    if (noteNavigationInputForMapEntry()) {
      Serial.println(seedMapStart
                         ? "BLE route geometry: seeded map start; "
                           "transitioning to map"
                         : "BLE route geometry: fresh post-pairing route; "
                           "transitioning to map");
    }
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

  const bool hadRoute = routeOverlay.hasRoute();
  routeOverlay.parseRouteData(data, len);
  // Route geometry is a live foreground input, not part of the expensive base
  // frame. Only a transition into or out of usable route geometry forces a
  // base request; ordinary sliding-window replacement is picked up on the next
  // UI tick and must not cancel a long 3D render. The reverse transition also
  // covers a short/malformed replacement without leaving stale course-up
  // semantics behind.
  if (hadRoute != routeOverlay.hasRoute())
    requestMapRender(map_render_policy::Reason::Route);
}

static void handleGpsPayload(
    const uint8_t *data, size_t len, const char *source,
    const gps_input_freshness::ArrivalBatch &arrivals) {
  gps_position_protocol::Packet packet{};
  if (!gps_position_protocol::decodeAndApply(data, len, gps.gpsData,
                                             &packet)) {
    Serial.printf("BLE: Rejected malformed %s GPS position (%u bytes)\n",
                  source == nullptr ? "unknown" : source,
                  static_cast<unsigned>(len));
    return;
  }

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  bool rtcTimestampSynced = false;
  if (packet.hasUnixTime) {
    const uint32_t now = millis();
    const waveshare_board::rtc::Status &rtcStatus =
        waveshare_board::rtc::status();
    if (!rtcStatus.timeValid || lastBleRtcSyncMs == 0 ||
        now - lastBleRtcSyncMs >= BLE_RTC_SYNC_INTERVAL_MS) {
      rtcTimestampSynced = waveshare_board::rtc::syncFromUnixTime(
          static_cast<time_t>(packet.unixTime), "BLE GPS timestamp");
      if (rtcTimestampSynced) {
        lastBleRtcSyncMs = now;
        (void)ride_diagnostics::recordClockAnchor();
      }
    }
  }
#endif

  gpsFreshnessState.accept(arrivals);
  bleDebugStats.gpsPacketCount = gpsFreshnessState.packetCount;
  bleDebugStats.lastGpsPacketMs = gpsFreshnessState.lastPacketMs;
  bleDebugStats.lastGpsPacketGapMs = gpsFreshnessState.lastGapMs;
  bleDebugStats.maximumGpsPacketGapMs = gpsFreshnessState.maximumGapMs;

  const uint32_t nowMs = millis();
  const uint32_t previousDiagnosticGpsLogMs =
      lastRideDiagnosticsGpsLogMs.load(std::memory_order_acquire);
  if (previousDiagnosticGpsLogMs == 0 ||
      static_cast<uint32_t>(nowMs - previousDiagnosticGpsLogMs) >= 30'000U) {
    lastRideDiagnosticsGpsLogMs.store(nowMs, std::memory_order_release);
    char fields[192] = {};
    snprintf(fields, sizeof(fields),
             "{\"fixValid\":%s,\"speedAvailable\":%s,"
             "\"accuracyAvailable\":%s,\"lastGapMs\":%lu,"
             "\"maximumGapMs\":%lu}",
             packet.fixValid ? "true" : "false",
             packet.hasSpeed ? "true" : "false",
             packet.hasHorizontalAccuracy ? "true" : "false",
             static_cast<unsigned long>(bleDebugStats.lastGpsPacketGapMs),
             static_cast<unsigned long>(bleDebugStats.maximumGpsPacketGapMs));
    ride_diagnostics::record(ride_diagnostics::Level::Info, "gps",
                             "quality_checkpoint", fields);
  }

  if (packet.hasRideDetectionQuality && arrivals.packetCount > 0) {
    GpsRideObservation observation{};
    observation.source = RidePositionSource::AuthenticatedBle;
    observation.fixAvailable = true;
    observation.fixValid = packet.fixValid;
    observation.speedAvailable = packet.hasSpeed;
    observation.speedMetersPerSecond =
        static_cast<float>(packet.speedCentimetersPerSecond) / 100.0F;
    observation.locationAvailable = true;
    observation.latitude =
        static_cast<double>(packet.latitudeMicrodegrees) / 1'000'000.0;
    observation.longitude =
        static_cast<double>(packet.longitudeMicrodegrees) / 1'000'000.0;
    observation.horizontalUncertaintyAvailable =
        packet.hasHorizontalAccuracy;
    observation.horizontalUncertaintyMeters =
        static_cast<float>(packet.horizontalAccuracyDecimeters) / 10.0F;
    observation.capturedAtMs = gps_position_protocol::capturedAtMs(
        arrivals.lastPacketMs,
        packet.hasSampleAge ? packet.sampleAgeMs : 0U);
    publishAuthenticatedBleGpsRideObservation(observation);
  }

#if FIRMWARE_DIAGNOSTICS
  Serial.printf("BLE: %s GPS position received: heading=%u rtcSync=%d "
                "gapMs=%lu maxGapMs=%lu\n",
                source == nullptr ? "unknown" : source,
                (unsigned)gps.gpsData.heading,
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
                rtcTimestampSynced,
#else
                0,
#endif
                (unsigned long)bleDebugStats.lastGpsPacketGapMs,
                (unsigned long)bleDebugStats.maximumGpsPacketGapMs
  );
#endif

  if (noteNavigationInputForMapEntry()) {
    Serial.println("BLE GPS: Fresh position received, transitioning to map...");
  }

  // Retain every accepted fix. The LVGL owner updates lightweight telemetry and
  // the position marker immediately, then independently decides whether the
  // vector-map background crossed its time/movement/heading thresholds.
}

static workout_telemetry::ApplyResult
handleWorkoutTelemetryPayload(const uint8_t *data, size_t len,
                              const char *source) {
  power_metrics::noteBlePacket(power_metrics::BlePacketClass::Workout);
  if (!requireAuthenticated("workout telemetry")) {
    return workout_telemetry::ApplyResult::RejectedUnauthenticated;
  }
  const workout_telemetry::ApplyResult result =
      workout_telemetry_runtime::ingestFrame(data, len, millis(), true);
  static int lastDiagnosticWorkoutResult = -1;
  static uint32_t lastDiagnosticWorkoutRecordMs = 0;
  const uint32_t nowMs = millis();
  const int resultValue = static_cast<int>(result);
  if (resultValue != lastDiagnosticWorkoutResult ||
      static_cast<uint32_t>(nowMs - lastDiagnosticWorkoutRecordMs) >=
          30'000U) {
    lastDiagnosticWorkoutResult = resultValue;
    lastDiagnosticWorkoutRecordMs = nowMs;
    char diagnosticFields[128] = {};
    snprintf(diagnosticFields, sizeof(diagnosticFields),
             "{\"result\":\"%s\"}",
             workout_telemetry::applyResultName(result));
    (void)ride_diagnostics::record(
        result == workout_telemetry::ApplyResult::Applied ||
                result == workout_telemetry::ApplyResult::Cleared
            ? ride_diagnostics::Level::Info
            : ride_diagnostics::Level::Warning,
        "workout", "telemetry_boundary", diagnosticFields);
  }
  switch (result) {
  case workout_telemetry::ApplyResult::Applied:
  case workout_telemetry::ApplyResult::Cleared:
    // Health metrics remain RAM-only and are intentionally absent from logs.
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
    return result;
  default:
    Serial.printf("BLE Workout: rejected %s frame (%s)\n",
                  source == nullptr ? "unknown" : source,
                  workout_telemetry::applyResultName(result));
    return result;
  }
}

static void handleMapSetting(uint8_t settingId, int32_t settingValue,
                             const char *source) {
  bleDebugStats.settingsPacketCount++;
  bleDebugStats.lastSettingsPacketMs = millis();
  if (map_profile_protocol::isLabelSetting(settingId) &&
      !bleSessionSupportsStreetLabels) {
    Serial.printf("BLE Settings: ignored unnegotiated label setting %u\n",
                  settingId);
    return;
  }
  if (settingId == map_profile_protocol::MAP_NAVIGATION_3D_BUILDINGS_SETTING_ID &&
      !bleSessionSupports3DBuildings) {
    Serial.println("BLE Settings: ignored unnegotiated 3D buildings setting");
    return;
  }
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
    mapRenderSettings.mapStyle.streetLineWidth = static_cast<uint8_t>(
        map_profile_protocol::absoluteStreetWidthFromLegacyBoost(
            map_profile_protocol::clampValue(settingId, settingValue)));
    if (mirrorLegacyMapProfile) {
      mapRenderSettings.mapNavigationStyle.streetLineWidth =
          mapRenderSettings.mapStyle.streetLineWidth;
    }
    persistMapProfileSetting();
    Serial.printf("BLE Settings: streetLineWidth = %d px (saved)\n",
                  mapRenderSettings.mapStyle.streetLineWidth);
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
  case 12:
#ifdef USE_ARDUINO_GFX
    if (!displayPowerManager.requestUserBrightness(settingValue)) {
      Serial.printf("BLE Settings: brightness persistence failed from %s\n",
                    source == nullptr ? "unknown" : source);
      return;
    }
#ifdef DISPLAY_POWER_DIAGNOSTICS
    Serial.printf("BLE Settings: brightness = %u%% (saved, pending)\n",
                  displayPowerManager.savedBrightnessPercent());
#endif
#else
    Serial.println("BLE Settings: brightness unsupported on this target");
#endif
    return;
  case display_power::kAutomaticDisplayOffSettingID:
    if (!display_power::isBooleanSettingValue(settingValue)) {
      Serial.printf("BLE Settings: rejected automatic display-off value %ld from %s\n",
                    (long)settingValue,
                    source == nullptr ? "unknown" : source);
      return;
    }
#ifdef USE_ARDUINO_GFX
    if (!display_power::applyAutomaticDisplayOffSetting(displayPowerManager,
                                                        settingValue)) {
      Serial.printf("BLE Settings: automatic display-off persistence failed from %s\n",
                    source == nullptr ? "unknown" : source);
      return;
    }
    Serial.printf("BLE Settings: automaticDisplayOff = %s (saved)\n",
                  settingValue == 1 ? "on" : "off");
#else
    Serial.println("BLE Settings: automatic display-off unsupported on this target");
#endif
    return;
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
    return;
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
    mapRenderSettings.mapNavigationStyle.streetLineWidth =
        static_cast<uint8_t>(
            map_profile_protocol::absoluteStreetWidthFromLegacyBoost(
                map_profile_protocol::clampValue(settingId, settingValue)));
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
  case map_profile_protocol::MAP_NAVIGATION_BIRDS_EYE_SETTING_ID:
    mapRenderSettings.mapNavigationBirdsEyeEnabled =
        map_profile_protocol::clampValue(settingId, settingValue) != 0;
    settingsPrefs.begin("mapSettings", false);
    map_profile_persistence::persistBirdsEyeEnabled(
        settingsPrefs, mapRenderSettings.mapNavigationBirdsEyeEnabled);
    settingsPrefs.end();
    Serial.printf("BLE Settings: mapNavigationBirdsEye = %s (saved)\n",
                  mapRenderSettings.mapNavigationBirdsEyeEnabled ? "on"
                                                                  : "off");
    break;
  case map_profile_protocol::MAP_NAVIGATION_BIRDS_EYE_PERSPECTIVE_SETTING_ID:
    mapRenderSettings.mapNavigationBirdsEyePerspective =
        static_cast<uint8_t>(
            map_profile_protocol::clampValue(settingId, settingValue));
    settingsPrefs.begin("mapSettings", false);
    map_profile_persistence::persistBirdsEyePerspective(
        settingsPrefs, mapRenderSettings.mapNavigationBirdsEyePerspective);
    settingsPrefs.end();
    Serial.printf("BLE Settings: mapNavigationBirdsEyePerspective = %u "
                  "(saved)\n",
                  mapRenderSettings.mapNavigationBirdsEyePerspective);
    break;
  case map_profile_protocol::MAP_LABEL_DENSITY_SETTING_ID:
    mapRenderSettings.mapStyle.labelDensity = static_cast<uint8_t>(
        map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_LABEL_LANGUAGE_MODE_SETTING_ID:
    mapRenderSettings.mapStyle.labelLanguageMode = static_cast<uint8_t>(
        map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_LABEL_TEXT_SIZE_SETTING_ID:
    mapRenderSettings.mapStyle.labelTextSize = static_cast<uint8_t>(
        map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_LABEL_ORIENTATION_SETTING_ID:
    mapRenderSettings.mapStyle.labelOrientation = static_cast<uint8_t>(
        map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_NAVIGATION_LABEL_DENSITY_SETTING_ID:
    mapRenderSettings.mapNavigationStyle.labelDensity = static_cast<uint8_t>(
        map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_NAVIGATION_LABEL_LANGUAGE_MODE_SETTING_ID:
    mapRenderSettings.mapNavigationStyle.labelLanguageMode =
        static_cast<uint8_t>(
            map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_NAVIGATION_LABEL_TEXT_SIZE_SETTING_ID:
    mapRenderSettings.mapNavigationStyle.labelTextSize = static_cast<uint8_t>(
        map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_NAVIGATION_LABEL_ORIENTATION_SETTING_ID:
    mapRenderSettings.mapNavigationStyle.labelOrientation =
        static_cast<uint8_t>(
            map_profile_protocol::clampValue(settingId, settingValue));
    persistMapProfileSetting();
    break;
  case map_profile_protocol::MAP_NAVIGATION_3D_BUILDINGS_SETTING_ID:
    mapRenderSettings.mapNavigation3DBuildingsEnabled =
        map_profile_protocol::clampValue(settingId, settingValue) != 0;
    settingsPrefs.begin("mapSettings", false);
    map_profile_persistence::persist3DBuildingsEnabled(
        settingsPrefs, mapRenderSettings.mapNavigation3DBuildingsEnabled);
    settingsPrefs.end();
    break;
  default:
    Serial.printf("BLE Settings: Unknown setting ID %d from %s\n", settingId,
                  source == nullptr ? "unknown" : source);
    return;
  }

  if (map_setting_redraw_policy::invalidatesMap(settingId)) {
    requestMapRender(map_setting_redraw_policy::changesZoom(settingId)
                         ? map_render_policy::Reason::Zoom
                         : map_render_policy::Reason::Style);
  }
}

static void handleMapSettingPayload(const uint8_t *data, size_t len,
                                    const char *source) {
  power_metrics::noteBlePacket(power_metrics::BlePacketClass::Settings);
  map_setting_packet::Packet packet;
  if (!map_setting_packet::decode(data, len, packet)) {
    Serial.printf("BLE: Rejected %s map setting: expected exactly 5 bytes\n",
                  source == nullptr ? "unknown" : source);
    return;
  }

  handleMapSetting(packet.settingId, packet.value, source);
}

static void processPendingMapInputs() {
  if (pendingMapInputMutex == nullptr ||
      pendingMapInputCount.load(std::memory_order_acquire) == 0) {
    return;
  }

  auto takeSlot = [](PendingMapInput &slot) {
    PendingMapInput input{};
    if (xSemaphoreTake(pendingMapInputMutex, portMAX_DELAY) != pdTRUE) {
      return input;
    }
    if (slot.pending) {
      input = slot;
      slot = {};
      pendingMapInputCount.fetch_sub(1, std::memory_order_release);
    }
    xSemaphoreGive(pendingMapInputMutex);
    return input;
  };

  auto processInput = [](PendingMapInput input) {
    if (!input.pending) {
      return false;
    }
    if (input.payloadGeneration !=
        ridePayloadGeneration.load(std::memory_order_acquire)) {
      free(input.data);
      return false;
    }

    const char *source = input.fallback ? "fallback" : "native";
    switch (input.type) {
    case PendingMapInputType::Route:
      handleRouteGeometryPayload(input.data, input.length, source);
      break;
    case PendingMapInputType::Gps:
      handleGpsPayload(input.data, input.length, source, input.gpsArrivals);
      break;
    case PendingMapInputType::Setting:
      handleMapSettingPayload(input.data, input.length, source);
      break;
    }
    free(input.data);
    return true;
  };

  struct PendingRouteWork {
    PendingMapInput input{};
    PendingRouteRideDelivery delivery{};
  };
  auto takeRoute = []() {
    PendingRouteWork work{};
    if (xSemaphoreTake(pendingMapInputMutex, portMAX_DELAY) != pdTRUE) {
      return work;
    }
    if (pendingRouteInput.pending) {
      work.input = pendingRouteInput;
      work.delivery = pendingRouteRideDelivery;
      pendingRouteInput = {};
      pendingRouteRideDelivery = {};
      pendingMapInputCount.fetch_sub(1, std::memory_order_release);
    }
    xSemaphoreGive(pendingMapInputMutex);
    return work;
  };

  const PendingRouteWork route = takeRoute();
  const bool routeApplied = processInput(route.input);
  if (routeApplied &&
      pendingRouteDeliveryMatchesCurrentLease(route.delivery)) {
    noteRideDeliveryMember(route.delivery.member(), route.delivery.result,
                           route.delivery.leaseGeneration);
  }
  processInput(takeSlot(pendingGpsInput));
  while (true) {
    PendingMapInput input{};
    if (xSemaphoreTake(pendingMapInputMutex, portMAX_DELAY) != pdTRUE) {
      break;
    }
    int16_t pendingSettingId = -1;
    for (size_t byteIndex = 0; byteIndex < MAP_SETTING_MASK_BYTES;
         ++byteIndex) {
      const uint8_t bits = pendingSettingMask[byteIndex];
      if (bits == 0) {
        continue;
      }
      for (uint8_t bit = 0; bit < 8; ++bit) {
        if ((bits & static_cast<uint8_t>(1U << bit)) != 0) {
          pendingSettingId =
              static_cast<int16_t>(byteIndex * 8 + bit);
          pendingSettingMask[byteIndex] &=
              static_cast<uint8_t>(~(1U << bit));
          break;
        }
      }
      if (pendingSettingId >= 0) {
        break;
      }
    }
    if (pendingSettingId >= 0) {
      PendingMapInput &slot = pendingSettingInputs[pendingSettingId];
      input = slot;
      slot = {};
      pendingMapInputCount.fetch_sub(1, std::memory_order_release);
    }
    xSemaphoreGive(pendingMapInputMutex);
    if (pendingSettingId < 0) {
      break;
    }
    processInput(input);
  }
}

// ============================================================================
// NimBLE Callbacks
// ============================================================================

class ScopedNimbleCallback {
public:
  TaskHandle_t previousTask = nullptr;

  ScopedNimbleCallback() {
    previousTask = nimbleCallbackTask.exchange(
        xTaskGetCurrentTaskHandle(), std::memory_order_acq_rel);
    const uint16_t connectionHandle = activeConnHandle;
    NimBLEServer *server = NimBLEDevice::getServer();
    if (connectionHandle != BLE_HS_CONN_HANDLE_NONE && server != nullptr) {
      const uint16_t peerMtu = server->getPeerMTU(connectionHandle);
      if (peerMtu >= 23) {
        activePeerMtu.store(peerMtu, std::memory_order_release);
      }
    }
  }
  ~ScopedNimbleCallback() {
    nimbleCallbackTask.store(previousTask, std::memory_order_release);
  }
};

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
    radioConnectionHandle.store(desc->conn_handle, std::memory_order_release);
    activePeerMtu.store(23, std::memory_order_release);
#if BLE_RADIO_CHARACTERIZATION
    radioRequestedConnectionProfile.store(
        static_cast<uint8_t>(ble_radio_policy::ConnectionProfile::Unset),
        std::memory_order_release);
    portENTER_CRITICAL(&radioDebugMux);
    radioDebugSnapshot.requestedConnectionProfile =
        ble_radio_policy::ConnectionProfile::Unset;
    portEXIT_CRITICAL(&radioDebugMux);
#endif
    recordConnectionParameters(*desc, millis());
    acceptConnection();
  }

  void onMTUChange(uint16_t mtu, ble_gap_conn_desc *desc) override {
    if (desc != nullptr && desc->conn_handle == activeConnHandle && mtu >= 23) {
      activePeerMtu.store(mtu, std::memory_order_release);
    }
  }

  void acceptConnection() {
    clearAuthenticatedBleGpsRideObservation();
    server->connected = true;
    bleSessionAuthenticated = false;
    bleSessionUsesIndependentMapProfiles = false;
    bleSessionSupportsStreetLabels = false;
    bleSessionSupports3DBuildings = false;
    bleSessionSupportsExplicitInvalidGpsHeading.store(false,
                                                      std::memory_order_release);
    bleSessionSupportsRendererDiagnostics.store(false,
                                                std::memory_order_release);
    bleSessionSupportsRideDiagnostics.store(false,
                                            std::memory_order_release);
    bleSessionSupportsRideDeliveryAck.store(false,
                                             std::memory_order_release);
    rideDeliveryLeaseGenerationSnapshot.store(0,
                                               std::memory_order_release);
    advanceRidePayloadGeneration();
    resetRideDeliveryTracking();
    lastRendererMetricsRequestMs.store(0, std::memory_order_release);
    lastRendererWindowRequestMs.store(0, std::memory_order_release);
    lastRendererWindowRequestProfile.store(
        renderer_diagnostics_ble_protocol::CURRENT_PROFILE,
        std::memory_order_release);
    clearRendererWindowRequest();
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
    ride_diagnostics::record(ride_diagnostics::Level::Info, "ble",
                             "connected", "{}");
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
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
    radioConnectionHandle.store(BLE_HS_CONN_HANDLE_NONE,
                                std::memory_order_release);
    activePeerMtu.store(23, std::memory_order_release);
    portENTER_CRITICAL(&radioDebugMux);
    radioDebugSnapshot.connectionParametersValid = false;
    portEXIT_CRITICAL(&radioDebugMux);
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
    // Revoke the session token, hotspot secret, and request generation on
    // NimBLE's serialized host callback before a reconnect can authenticate.
    deviceTransferHttp.clearAuthenticatedBleSession();
    queueTransferControl(ble_transfer::Action::DisableOnBleDisconnect,
                         ble_transfer::NotifyNone);
    server->connected = false;
    bleSessionAuthenticated = false;
    bleSessionUsesIndependentMapProfiles = false;
    bleSessionSupportsStreetLabels = false;
    bleSessionSupports3DBuildings = false;
    bleSessionSupportsExplicitInvalidGpsHeading.store(false,
                                                      std::memory_order_release);
    bleSessionSupportsRendererDiagnostics.store(false,
                                                std::memory_order_release);
    bleSessionSupportsRideDiagnostics.store(false,
                                            std::memory_order_release);
    bleSessionSupportsRideDeliveryAck.store(false,
                                             std::memory_order_release);
    rideDeliveryLeaseGenerationSnapshot.store(0,
                                               std::memory_order_release);
    advanceRidePayloadGeneration();
    resetRideDeliveryTracking();
    lastRendererMetricsRequestMs.store(0, std::memory_order_release);
    lastRendererWindowRequestMs.store(0, std::memory_order_release);
    lastRendererWindowRequestProfile.store(
        renderer_diagnostics_ble_protocol::CURRENT_PROFILE,
        std::memory_order_release);
    clearRendererWindowRequest();
    clearAuthenticatedBleGpsRideObservation();
    phoneBatteryLevelPercent = -1;
    phoneBatteryCharging = false;
    unauthTimeoutDisconnectRequested = false;
    ownershipDisconnectPending = false;
    bleDebugStats.connected = false;
    bleDebugStats.authenticated = false;
    ride_diagnostics::record(ride_diagnostics::Level::Info, "ble",
                             "disconnected", "{}");
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
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
#if BLE_RADIO_CHARACTERIZATION
    radioRequestedConnectionProfile.store(
        static_cast<uint8_t>(ble_radio_policy::ConnectionProfile::Unset),
        std::memory_order_release);
    portENTER_CRITICAL(&radioDebugMux);
    radioDebugSnapshot.requestedConnectionProfile =
        ble_radio_policy::ConnectionProfile::Unset;
    portEXIT_CRITICAL(&radioDebugMux);
    applyCharacterizationAdvertisingMode(
        ble_radio_policy::AdvertisingMode::Fast, false);
#endif
    NimBLEDevice::startAdvertising();
  }
};

class MyNavCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    const std::string frame = pChar->getValue();
    if (frame.empty()) {
      return;
    }
    std::string value;
    bool scopedWatchSession = false;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Navigation, frame, value,
            "navigation characteristic", &scopedWatchSession)) {
      return;
    }

    ride_delivery_protocol::CommandMember deliveryMember{};
    const RideDeliveryDecodeResult deliveryDecode = decodeRideDeliveryPayload(
        value, ride_delivery_protocol::CommandType::NavigationClear,
        deliveryMember);
    if (deliveryDecode == RideDeliveryDecodeResult::Rejected)
      return;
    const bool hasDeliveryMember =
        deliveryDecode == RideDeliveryDecodeResult::Decoded;
    if (hasDeliveryMember) {
      static constexpr char kNavigationIdle[] = "1|0|Navigation idle";
      if (deliveryMember.memberCount != 2 ||
          deliveryMember.memberIndex != 1 ||
          deliveryMember.payloadLength != sizeof(kNavigationIdle) - 1 ||
          std::memcmp(deliveryMember.payload, kNavigationIdle,
                      sizeof(kNavigationIdle) - 1) != 0) {
        noteRideDeliveryMember(
            deliveryMember, ride_delivery_protocol::Result::Malformed);
        return;
      }
      value.assign(reinterpret_cast<const char *>(deliveryMember.payload),
                   deliveryMember.payloadLength);
    }

    if (scopedWatchSession &&
        !scoped_watch_payload_policy::allowsNavigationPayload(
            reinterpret_cast<const uint8_t *>(value.data()), value.size())) {
      bleDebugStats.rejectedUnauthenticatedCount++;
      bleDebugStats.lastRejectedUnauthenticatedMs = millis();
      Serial.println(
          "BLE: Rejected privileged multiplexed command from scoped Watch");
      return;
    }

    if (handleDestinationPickerPayload(value, "destination picker")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Control);
      return;
    }

    if (handleRendererDiagnosticsCommand(
            value, "renderer diagnostics fallback")) {
      return;
    }

    if (value.size() == ride_automation_protocol::FALLBACK_PREFIX_SIZE +
                            ride_automation_protocol::FRAME_SIZE &&
        std::memcmp(value.data(), ride_automation_protocol::FALLBACK_PREFIX,
                    ride_automation_protocol::FALLBACK_PREFIX_SIZE) == 0) {
      if (!ride_automation_runtime::ingestTransportFrame(
              reinterpret_cast<const uint8_t *>(value.data()) +
                  ride_automation_protocol::FALLBACK_PREFIX_SIZE,
              ride_automation_protocol::FRAME_SIZE, millis()))
        Serial.println("BLE Ride Automation: rejected navigation fallback frame");
      return;
    }

    if (hasPrefix(value, workout_telemetry_protocol::FALLBACK_PREFIX)) {
      handleWorkoutTelemetryPayload(
          reinterpret_cast<const uint8_t *>(value.data()) +
              workout_telemetry_protocol::FALLBACK_PREFIX_SIZE,
          value.length() - workout_telemetry_protocol::FALLBACK_PREFIX_SIZE,
          "fallback");
      return;
    }

    if (hasPrefix(value, "MAPR")) {
      if (!requireAuthenticated("fallback route geometry")) {
        power_metrics::noteBlePacket(power_metrics::BlePacketClass::Route);
        return;
      }
      queueMapInput(PendingMapInputType::Route,
                    (const uint8_t *)value.data() + 4, value.length() - 4,
                    "fallback");
      return;
    }

    if (hasPrefix(value, "GPSP")) {
      if (!requireAuthenticated("fallback GPS position")) {
        power_metrics::noteBlePacket(power_metrics::BlePacketClass::Gps);
        return;
      }
      queueMapInput(PendingMapInputType::Gps,
                    (const uint8_t *)value.data() + 4, value.length() - 4,
                    "fallback");
      return;
    }

    if (hasPrefix(value, "MSET")) {
      if (!requireAuthenticated("fallback map setting")) {
        power_metrics::noteBlePacket(power_metrics::BlePacketClass::Settings);
        return;
      }
      queueMapInput(PendingMapInputType::Setting,
                    (const uint8_t *)value.data() + 4, value.length() - 4,
                    "fallback");
      return;
    }

    if (hasPrefix(value, "MTRN")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("map transfer control")) {
        return;
      }
      handleMapTransferControlPayload((const uint8_t *)value.data() + 4,
                                      value.length() - 4, pChar);
      return;
    }

    if (hasPrefix(value, "MSTS")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("map transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyMap);
      return;
    }

    if (hasPrefix(value, "DTRN")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("device transfer control")) {
        return;
      }
      handleGenericTransferControlPayload((const uint8_t *)value.data() + 4,
                                          value.length() - 4, pChar);
      return;
    }

    if (handleDeviceCapabilitiesCommand(value, pChar,
                                        "device capabilities")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Control);
      return;
    }

    if (hasPrefix(value, "DSTS")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("device transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
      return;
    }

    if (handleSoundPlayCommand(value, "sound playback", "fallback")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Audio);
      return;
    }

    if (handlePowerButtonHonkCommand(value, "PWR honk configuration",
                                     "fallback", pChar)) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Audio);
      return;
    }

    power_metrics::noteBlePacket(power_metrics::BlePacketClass::Navigation);
    if (!requireAuthenticated("navigation instruction")) {
      return;
    }

#if FIRMWARE_DIAGNOSTICS
    Serial.printf("BLE Nav received: %u bytes\n", (unsigned)value.length());
#endif
    bleDebugStats.navPacketCount++;
    bleDebugStats.lastNavPacketMs = millis();
    parseNavigationData(value);
    if (hasDeliveryMember) {
      noteRideDeliveryMember(deliveryMember,
                             ride_delivery_protocol::Result::Success);
    }
  }
};

class MyRouteCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Route, frame, value,
            "route characteristic")) {
      return;
    }
    if (!requireAuthenticated("route geometry")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Route);
      return;
    }
    ride_delivery_protocol::CommandMember deliveryMember{};
    const RideDeliveryDecodeResult deliveryDecode = decodeRideDeliveryPayload(
        value, ride_delivery_protocol::CommandType::NavigationClear,
        deliveryMember);
    if (deliveryDecode == RideDeliveryDecodeResult::Rejected)
      return;
    const bool hasDeliveryMember =
        deliveryDecode == RideDeliveryDecodeResult::Decoded;
    if (hasDeliveryMember &&
        ((deliveryMember.memberCount != 1 &&
          deliveryMember.memberCount != 2) ||
         deliveryMember.memberIndex != 0 ||
         deliveryMember.payloadLength != 0)) {
      noteRideDeliveryMember(deliveryMember,
                             ride_delivery_protocol::Result::Malformed);
      return;
    }

    const uint8_t *payload = hasDeliveryMember
                                 ? deliveryMember.payload
                                 : reinterpret_cast<const uint8_t *>(
                                       value.data());
    const size_t payloadLength = hasDeliveryMember
                                     ? deliveryMember.payloadLength
                                     : value.length();
    const bool accepted = queueMapInput(
        PendingMapInputType::Route, payload, payloadLength, "native",
        hasDeliveryMember ? &deliveryMember : nullptr);
    if (hasDeliveryMember && !accepted) {
      noteRideDeliveryMember(
          deliveryMember, ride_delivery_protocol::Result::ResourceRejected);
    }
  }
};

class MyGPSCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Gps, frame, value,
            "GPS characteristic")) {
      return;
    }
    if (!requireAuthenticated("GPS position")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Gps);
      return;
    }

    queueMapInput(PendingMapInputType::Gps, (const uint8_t *)value.data(),
                  value.length(), "native");
  }
};

class MyWorkoutTelemetryCharacteristicCallbacks
    : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    const std::string frame = pChar->getValue();
    workout_telemetry_transport::dispatchAuthenticatedNativeFrame(
        frame,
        [](const std::string &protectedFrame, std::string &payload) {
          return unwrapOwnerAuthenticatedPayload(
              device_ownership::AuthenticatedChannel::Workout,
              protectedFrame, payload, "workout telemetry characteristic");
        },
        [](const uint8_t *payload, std::size_t length) {
          std::string value(reinterpret_cast<const char *>(payload), length);
          ride_delivery_protocol::CommandMember deliveryMember{};
          const RideDeliveryDecodeResult deliveryDecode =
              decodeRideDeliveryPayload(
                  value, ride_delivery_protocol::CommandType::WorkoutState,
                  deliveryMember);
          if (deliveryDecode == RideDeliveryDecodeResult::Rejected)
            return;
          const bool hasDeliveryMember =
              deliveryDecode == RideDeliveryDecodeResult::Decoded;
          if (hasDeliveryMember) {
            const bool canonicalMember =
                deliveryMember.payloadLength > 0 &&
                deliveryMember.memberCount <= 3 &&
                deliveryMember.memberIndex < deliveryMember.memberCount &&
                deliveryMember.payload[0] ==
                    static_cast<uint8_t>(deliveryMember.memberIndex + 1);
            if (!canonicalMember) {
              noteRideDeliveryMember(
                  deliveryMember, ride_delivery_protocol::Result::Malformed);
              return;
            }
            payload = deliveryMember.payload;
            length = deliveryMember.payloadLength;
          }
          const workout_telemetry::ApplyResult result =
              handleWorkoutTelemetryPayload(payload, length, "native");
          if (!hasDeliveryMember)
            return;
          using ApplyResult = workout_telemetry::ApplyResult;
          ride_delivery_protocol::Result deliveryResult =
              ride_delivery_protocol::Result::ResourceRejected;
          switch (result) {
          case ApplyResult::Applied:
          case ApplyResult::Cleared:
            deliveryResult = ride_delivery_protocol::Result::Success;
            break;
          case ApplyResult::IgnoredToken:
          case ApplyResult::IgnoredPair:
          case ApplyResult::IgnoredStateRegression:
            deliveryResult = ride_delivery_protocol::Result::Stale;
            break;
          case ApplyResult::RejectedUnauthenticated:
            deliveryResult = ride_delivery_protocol::Result::Unauthorized;
            break;
          case ApplyResult::RejectedLength:
          case ApplyResult::RejectedKind:
          case ApplyResult::RejectedState:
          case ApplyResult::RejectedToken:
          case ApplyResult::RejectedFlags:
          case ApplyResult::RejectedMetric:
            deliveryResult = ride_delivery_protocol::Result::Malformed;
            break;
          }
          noteRideDeliveryMember(deliveryMember, deliveryResult);
        });
  }
};

class MyRideAutomationCharacteristicCallbacks
    : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    const std::string frame = pChar->getValue();
    std::string payload;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::RideAutomation, frame,
            payload, "ride automation characteristic") ||
        !requireAuthenticated("ride automation"))
      return;
    if (!ride_automation_runtime::ingestTransportFrame(
            reinterpret_cast<const uint8_t *>(payload.data()), payload.size(),
            millis()))
      Serial.println("BLE Ride Automation: rejected native frame");
  }
};

/**
 * @brief Settings characteristic callback - receives runtime config from iOS
 * app Format: [settingId:1][value:4] = 5 bytes Setting IDs: 1=minPolygonSize,
 * 2=detailLevel, 3=routeLineWidth, 9=streetLineWidth,
 * 10=positionMarkerScale
 */
class MySettingsCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    const std::string frame = pChar->getValue();
    std::string value;
    if (!unwrapOwnerAuthenticatedPayload(
            device_ownership::AuthenticatedChannel::Settings, frame, value,
            "settings characteristic")) {
      return;
    }

    if (value.size() == ride_automation_protocol::FALLBACK_PREFIX_SIZE +
                            ride_automation_protocol::FRAME_SIZE &&
        std::memcmp(value.data(), ride_automation_protocol::FALLBACK_PREFIX,
                    ride_automation_protocol::FALLBACK_PREFIX_SIZE) == 0) {
      if (!ride_automation_runtime::ingestTransportFrame(
              reinterpret_cast<const uint8_t *>(value.data()) +
                  ride_automation_protocol::FALLBACK_PREFIX_SIZE,
              ride_automation_protocol::FRAME_SIZE, millis()))
        Serial.println("BLE Ride Automation: rejected fallback frame");
      return;
    }

    if (handleDestinationPickerPayload(value, "native destination picker")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Control);
      return;
    }

    if (handleRendererDiagnosticsCommand(value,
                                         "native renderer diagnostics")) {
      return;
    }

    if (hasPrefix(value, "MTRN")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("native map transfer control")) {
        return;
      }
      handleMapTransferControlPayload((const uint8_t *)value.data() + 4,
                                      value.length() - 4,
                                      mapTransferStatusCharacteristic);
      return;
    }

    if (hasPrefix(value, "MSTS")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("native map transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyMap);
      return;
    }

    if (hasPrefix(value, "DTRN")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
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
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Control);
      return;
    }

    if (hasPrefix(value, "DSTS")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Transfer);
      if (!requireAuthenticated("native device transfer status")) {
        return;
      }
      queueTransferControl(ble_transfer::Action::None,
                           ble_transfer::NotifyGeneric);
      return;
    }

    if (handleSoundPlayCommand(value, "native sound playback", "native")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Audio);
      return;
    }

    if (handlePowerButtonHonkCommand(value, "native PWR honk configuration",
                                     "native",
                                     mapTransferStatusCharacteristic)) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Audio);
      return;
    }

    if (!requireAuthenticated("map setting")) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Settings);
      return;
    }

    queueMapInput(PendingMapInputType::Setting,
                  (const uint8_t *)value.data(), value.length(), "native");
  }
};

class MyAuthCharacteristicCallbacks : public NimBLECharacteristicCallbacks {
public:
  void onWrite(NimBLECharacteristic *pChar) override {
    ScopedNimbleCallback callbackScope;
    std::string value = pChar->getValue();
    if (!value.empty()) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Auth);
      handleAuthPayload(value);
      ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
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
  mapRenderSettings.mapNavigationBirdsEyeEnabled =
      map_profile_persistence::loadBirdsEyeEnabled(prefs);
  mapRenderSettings.mapNavigationBirdsEyePerspective =
      map_profile_persistence::loadBirdsEyePerspective(prefs);
  mapRenderSettings.mapNavigation3DBuildingsEnabled =
      map_profile_persistence::load3DBuildingsEnabled(prefs);
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
                "detailLevel=%d, routeWidth=%d, streetWidth=%d, "
                "markerScale=%d, navBirdEye=%d, navBirdTilt=%d, tapSwitch=%d, "
                "screenMask=0x%02X, defaultScreen=%d, discSleepSec=%lu\n",
                mapRenderSettings.mapStyle.minPolygonSize,
                mapRenderSettings.mapStyle.detailLevel,
                mapRenderSettings.mapStyle.routeLineWidth,
                mapRenderSettings.mapStyle.streetLineWidth,
                mapRenderSettings.mapStyle.positionMarkerScale,
                mapRenderSettings.mapNavigationBirdsEyeEnabled ? 1 : 0,
                mapRenderSettings.mapNavigationBirdsEyePerspective,
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

  if (pendingMapInputMutex == nullptr) {
    pendingMapInputMutex = xSemaphoreCreateMutex();
    if (pendingMapInputMutex == nullptr) {
      Serial.println("BLE: failed to create serialized map input mailbox");
    }
  }

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

  if (diagnosticsSessionMutex == nullptr) {
    diagnosticsSessionMutex =
        xSemaphoreCreateMutexStatic(&diagnosticsSessionMutexStorage);
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
    ownershipUiConnected = false;
    ownershipUiAuthenticated = false;
    ownershipUiPairingActive = false;
    ownershipUiPairingConfirmedOnDevice = false;
    ownershipUiPairingCode = 0;
    ownershipUiPairingGeneration = 0;
    ownershipUiUpdatePending = true;
    portEXIT_CRITICAL(&ownershipUiMux);
    ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
    Serial.println("BLE: Ownership storage unavailable; authentication locked");
  }

  initBleIdentityAndSecurity(effectiveDeviceName.c_str());
  if (!deferredNotificationEventReady.load(std::memory_order_acquire)) {
    ble_npl_event_init(&deferredNotificationEvent,
                       deferredNotificationEventHandler, nullptr);
    deferredNotificationEventPending.store(false, std::memory_order_release);
    deferredNotificationEventScheduled.store(false,
                                             std::memory_order_release);
    deferredNotificationEventReady.store(true, std::memory_order_release);
  }
  NimBLEDevice::setPower(configuredTxPowerLevel());
  NimBLEDevice::setMTU(512); // Increase MTU for route geometry

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

  // Workout frames are accepted only after the same local authentication
  // handshake as navigation traffic and remain in RAM-only telemetry state.
  pWorkoutTelemetryCharacteristic = pService->createCharacteristic(
      WORKOUT_TELEMETRY_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  pWorkoutTelemetryCharacteristic->setCallbacks(
      new MyWorkoutTelemetryCharacteristicCallbacks());

  pRideAutomationCharacteristic = pService->createCharacteristic(
      RIDE_AUTOMATION_CHAR_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
          NIMBLE_PROPERTY::NOTIFY);
  pRideAutomationCharacteristic->setCallbacks(
      new MyRideAutomationCharacteristicCallbacks());

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
#if BLE_RADIO_CHARACTERIZATION
  applyCharacterizationAdvertisingMode(
      ble_radio_policy::AdvertisingMode::Fast, false);
#endif
  pAdvertising->start();

  initialized = true;
  bleDebugStats.initialized = true;
  bleDebugStats.connected = connected;
  bleDebugStats.authenticated = bleSessionAuthenticated;
  Serial.printf("BLE: Server started, advertising as '%s'\n",
                effectiveDeviceName.c_str());
}

void BLENavigationServer::process() {
  scheduleDeferredNotificationEvent();
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
  }
  // A storage failure deliberately queues a fail-closed claimed snapshot even
  // though ownership processing itself is disabled. Apply it on the UI task so
  // a locked device never advertises the add-device Welcome experience.
  applyPendingOwnershipUiUpdate();
  // NimBLE callbacks run on the host task. Apply ownership presentation first
  // so a PAIRED/auth result queued in the same interval unblocks the first
  // post-pairing GPS fix or one-shot route. Then apply the latest
  // renderer-visible route, GPS, and per-setting state on the UI task so a
  // synchronous rolling build sees one stable generation throughout.
  processPendingMapInputs();
  if (ownershipRestartRequested &&
      static_cast<uint32_t>(millis() - ownershipRestartRequestedMs) >= 500) {
    Serial.println("BLE: Restarting after ownership removal");
    Serial.flush();
    ESP.restart();
  }
  processPendingTransferControl();
  pumpPendingMapTransferStatusChunks();
  scheduleDeferredNotificationEvent();
  const uint32_t nowMs = millis();
#if BLE_RADIO_CHARACTERIZATION
  processRadioCharacterization(nowMs, pServer);
#endif
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
  constexpr uint32_t kConnectionParameterSamplePeriodMs = 5000;
  const uint32_t lastSampleMs =
      lastConnectionParameterSampleMs.load(std::memory_order_acquire);
  const uint16_t connectionHandle =
      radioConnectionHandle.load(std::memory_order_acquire);
  if (connectionHandle != BLE_HS_CONN_HANDLE_NONE &&
      nowMs - lastSampleMs >= kConnectionParameterSamplePeriodMs) {
    ble_gap_conn_desc description{};
    if (ble_gap_conn_find(connectionHandle, &description) == 0) {
      recordConnectionParameters(description, nowMs);
    } else {
      lastConnectionParameterSampleMs.store(nowMs, std::memory_order_release);
    }
  }
#endif
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

#if FIRMWARE_DIAGNOSTICS
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

    const device_ownership::CryptoResourceDiagnostics cryptoResources =
        device_ownership::cryptoResourceDiagnostics();
    Serial.printf("BLE Debug: up=%lus init=%d conn=%d auth=%d connects=%lu "
                  "disconnects=%lu authOK=%lu nav=%lu route=%lu gps=%lu "
                  "settings=%lu rejectAuth=%lu lastMs[c=%lu a=%lu n=%lu r=%lu "
                  "g=%lu s=%lu rej=%lu] gpsGapMs[last=%lu max=%lu] "
                  "cryptoDma[free=%lu largest=%lu minFree=%lu minLargest=%lu "
                  "rejected=%lu failed=%lu]\n",
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
                  bleDebugStats.lastRejectedUnauthenticatedMs,
                  bleDebugStats.lastGpsPacketGapMs,
                  bleDebugStats.maximumGpsPacketGapMs,
                  static_cast<unsigned long>(cryptoResources.current.dmaFree),
                  static_cast<unsigned long>(
                      cryptoResources.current.dmaLargest),
                  static_cast<unsigned long>(cryptoResources.minimumDmaFree),
                  static_cast<unsigned long>(
                      cryptoResources.minimumDmaLargest),
                  static_cast<unsigned long>(
                      cryptoResources.headroomRejections),
                  static_cast<unsigned long>(
                      cryptoResources.operationFailures));
  }
#else
  (void)lastLog;
#endif
}

void BLENavigationServer::noteUserWake() {
#if BLE_RADIO_CHARACTERIZATION
  radioUserWakePending.store(true, std::memory_order_release);
#endif
}

void BLENavigationServer::setNavigationActivity(bool active) {
#if BLE_RADIO_CHARACTERIZATION
  radioNavigationActive.store(active, std::memory_order_release);
#else
  (void)active;
#endif
}

BLEDebugStats BLENavigationServer::getDebugStats() const {
  BLEDebugStats stats = bleDebugStats;
  stats.initialized = initialized;
  stats.connected = connected;
  stats.authenticated = bleSessionAuthenticated;
  portENTER_CRITICAL(&radioDebugMux);
  stats.connectionParametersValid =
      radioDebugSnapshot.connectionParametersValid;
  stats.connectionIntervalUnits = radioDebugSnapshot.connectionIntervalUnits;
  stats.connectionLatency = radioDebugSnapshot.connectionLatency;
  stats.supervisionTimeoutUnits =
      radioDebugSnapshot.supervisionTimeoutUnits;
  stats.connectionParameterSampleCount =
      radioDebugSnapshot.connectionParameterSampleCount;
  stats.lastConnectionParameterSampleMs =
      radioDebugSnapshot.lastConnectionParameterSampleMs;
  stats.advertisingMode = radioDebugSnapshot.advertisingMode;
  stats.requestedConnectionProfile =
      radioDebugSnapshot.requestedConnectionProfile;
  portEXIT_CRITICAL(&radioDebugMux);
  return stats;
}

bool BLENavigationServer::supportsExplicitInvalidGpsHeading() const {
  return bleSessionSupportsExplicitInvalidGpsHeading.load(
      std::memory_order_acquire);
}

bool BLENavigationServer::takeRendererBenchmarkWindowRequest(
    renderer_diagnostics_ble_protocol::WindowRequest &request) {
  bool available = false;
  portENTER_CRITICAL(&rendererWindowRequestMux);
  if (rendererWindowRequestPending) {
    request = pendingRendererWindowRequest;
    pendingRendererWindowRequest = {};
    rendererWindowRequestPending = false;
    available = true;
  }
  portEXIT_CRITICAL(&rendererWindowRequestMux);
  return available && bleSessionAuthenticated &&
         bleSessionSupportsRendererDiagnostics.load(std::memory_order_acquire);
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
  bleSessionSupportsExplicitInvalidGpsHeading.store(false,
                                                    std::memory_order_release);
  bleSessionSupportsRendererDiagnostics.store(false,
                                              std::memory_order_release);
  bleSessionSupportsRideDiagnostics.store(false,
                                          std::memory_order_release);
  lastRendererMetricsRequestMs.store(0, std::memory_order_release);
  lastRendererWindowRequestMs.store(0, std::memory_order_release);
  lastRendererWindowRequestProfile.store(
      renderer_diagnostics_ble_protocol::CURRENT_PROFILE,
      std::memory_order_release);
  clearRendererWindowRequest();
  clearAuthenticatedBleGpsRideObservation();
  bleDebugStats.authenticated = false;
  // Physical owner recovery is an immediate authorization boundary. Revoke
  // the token before the scheduled restart rather than relying on that later
  // restart to eventually tear the session down.
  stopActiveDeviceTransfer();
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
  std::string stableDeviceId;
  if (deviceOwnershipReady && deviceOwnershipMutex != nullptr &&
      xSemaphoreTake(deviceOwnershipMutex, pdMS_TO_TICKS(250)) == pdTRUE) {
    confirmed = deviceOwnership.confirmPairingOnDevice();
    if (confirmed) {
      stableDeviceId = deviceOwnership.deviceIdHex();
    }
    xSemaphoreGive(deviceOwnershipMutex);
  }
  if (!confirmed) {
    return false;
  }
  const std::string response = "PAIR_READY|" + stableDeviceId;
  notifyAuthResponse(response.c_str());
  queueOwnershipUiUpdate();
  Serial.println("BLE: Ownership pairing confirmed with physical button press");
  return true;
}

// ============================================================================
// Map Redraw Trigger (weak symbol - can be overridden by main app)
// ============================================================================

__attribute__((weak)) void requestMapRender(map_render_policy::Reason reason) {
  (void)reason;
  // Default implementation - will be overridden by mainScr.cpp
  Serial.println("BLE: requestMapRender called (default - no map linked)");
}

__attribute__((weak)) void applyDeviceScreenSettings() {
  // Default implementation - will be overridden by mainScr.cpp
}
