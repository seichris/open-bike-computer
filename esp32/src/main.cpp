/**
 * @file main.cpp
 * @author Jordi Gauchía (jgauchia@jgauchia.com)
 * @brief  ICENAV - ESP32 GPS Navigator main code
 * @version 0.2.2
 * @date 2025-05
 */

#include <Arduino.h>

#include <algorithm>
#include <cstdio>

#ifndef FIRMWARE_DIAGNOSTICS
#define FIRMWARE_DIAGNOSTICS 1
#endif
#if DEVICE_REMOTE_DEBUG && !FIRMWARE_DIAGNOSTICS
#error "remote renderer debugging requires firmware diagnostics"
#endif
#include <SPI.h>
#include <WiFi.h>
#include <Wire.h>
#include <esp_bt.h>
#include <esp_log.h>
#include <esp_system.h>
#include <esp_wifi.h>
#include <stdint.h>
#ifndef DISABLE_WEB_SERVER
#include <AsyncTCP.h>
#include <ESPAsyncWebServer.h>
#endif
#include <SolarCalculator.h>

// Hardware includes
#include "gps.hpp"
#include "hal.hpp"
#include "storage.hpp"
#include "tft.hpp"

#ifdef HMC5883L
#include "compass.hpp"
#endif

#ifdef QMC5883
#include "compass.hpp"
#endif

#ifdef IMU_MPU9250
#include "compass.hpp"
#endif

#ifdef BME280
#include "bme.hpp"
#endif

#ifdef MPU6050
#include "imu.hpp"
#endif

#ifdef HAS_HARDWARE_GPS
extern xSemaphoreHandle gpsMutex;
#endif

#ifndef DISABLE_WEB_SERVER
#include "webpage.h"
#include "webserver.h"
#endif

#include "battery.hpp"
#include "gpxParser.hpp"
#include "power.hpp"

#include "maps.hpp"
#include "device_transfer_http.hpp"
#include "device_debug_http.hpp"
#include "firmware_update_http.hpp"
#include "firmware_metadata.hpp"
#include "map_transfer.hpp"
#include "map_transfer_http.hpp"
#include "renderer_diagnostics.hpp"

// BLE Navigation for iOS route overlay
#include "ble_navigation.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "boot_diagnostics.hpp"
#include "display_inactivity_policy.hpp"
#include "display_power.hpp"
#endif
#include "disconnected_shutdown_policy.hpp"
#include "ownership_button_policy.hpp"
#include "power_metrics.hpp"
#include "guiLayout.hpp"
#include "mainScr.hpp"
#include "power_management.hpp"
#include "route_overlay.hpp"
#include "ride_automation_runtime.hpp"
#include "ui_scheduler.hpp"
#include "waitingScr.hpp"
#include "workout_telemetry_runtime.hpp"
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
#include "WAVESHARE_AMOLED_175.hpp"
#include "axp2101.hpp"
#include "i2c_bus.hpp"
#include "pcf85063.hpp"
#include "qmi8658.hpp"
#include "speaker.hpp"
#include "waveshare_board.hpp"
#endif

extern Storage storage;
extern Battery battery;
extern Power power;
extern Maps mapView;
device_transfer::HttpTransferServer deviceTransferHttp;
map_transfer::MapTransferHttpServer mapTransferHttp;
firmware_update::FirmwareUpdateHttpServer firmwareUpdateHttp;
device_debug::DeviceDebugHttp deviceDebugHttp;

static lv_obj_t *mapActivationProgressPanel = nullptr;
static lv_obj_t *mapActivationProgressLabel = nullptr;
static lv_obj_t *mapActivationProgressBar = nullptr;

static void updateMapActivationProgressOverlay() {
  static uint32_t lastUpdateMs = 0;
  const uint32_t now = millis();
  if (now - lastUpdateMs < 250)
    return;
  lastUpdateMs = now;

  const map_transfer::MapActivationSnapshot activation =
      mapTransferHttp.activationSnapshot();
  if (!activation.running) {
    if (mapActivationProgressPanel != nullptr)
      lv_obj_add_flag(mapActivationProgressPanel, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  if (mapActivationProgressPanel == nullptr) {
    mapActivationProgressPanel = lv_obj_create(lv_layer_top());
    lv_obj_set_size(mapActivationProgressPanel, TFT_WIDTH - 32, 120);
    lv_obj_align(mapActivationProgressPanel, LV_ALIGN_BOTTOM_MID, 0, -24);
    lv_obj_set_style_bg_color(mapActivationProgressPanel,
                              lv_color_hex(0x101010), 0);
    lv_obj_set_style_bg_opa(mapActivationProgressPanel, 235, 0);
    lv_obj_set_style_border_color(mapActivationProgressPanel,
                                  lv_color_hex(0x4A90E2), 0);
    lv_obj_set_style_border_width(mapActivationProgressPanel, 2, 0);
    lv_obj_set_style_radius(mapActivationProgressPanel, 14, 0);
    lv_obj_set_style_pad_all(mapActivationProgressPanel, 14, 0);
    lv_obj_clear_flag(mapActivationProgressPanel, LV_OBJ_FLAG_SCROLLABLE);

    mapActivationProgressLabel = lv_label_create(mapActivationProgressPanel);
    lv_obj_set_style_text_font(mapActivationProgressLabel,
                               &lv_font_montserrat_24, 0);
    lv_obj_set_style_text_color(mapActivationProgressLabel,
                                lv_color_white(), 0);
    lv_obj_set_width(mapActivationProgressLabel, LV_PCT(100));
    lv_obj_set_style_text_align(mapActivationProgressLabel,
                                LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(mapActivationProgressLabel, LV_ALIGN_TOP_MID, 0, -2);

    mapActivationProgressBar = lv_bar_create(mapActivationProgressPanel);
    lv_obj_set_size(mapActivationProgressBar, LV_PCT(100), 12);
    lv_obj_align(mapActivationProgressBar, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_bar_set_range(mapActivationProgressBar, 0, 100);
    lv_obj_set_style_bg_color(mapActivationProgressBar,
                              lv_color_hex(0x303030), LV_PART_MAIN);
    lv_obj_set_style_bg_color(mapActivationProgressBar,
                              lv_color_hex(0x4A90E2), LV_PART_INDICATOR);
  }

  lv_label_set_text_fmt(mapActivationProgressLabel,
                        "Map Upload Progress:\nStep %u - %u%%",
                        static_cast<unsigned>(activation.step),
                        static_cast<unsigned>(activation.progress));
  lv_bar_set_value(mapActivationProgressBar, activation.progress, LV_ANIM_OFF);
  lv_obj_clear_flag(mapActivationProgressPanel, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(mapActivationProgressPanel);
}

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
volatile bool waveshareBootScreenCyclePending = false;
static portMUX_TYPE waveshareBootButtonMux = portMUX_INITIALIZER_UNLOCKED;
static ownership_button_policy::FreshBootButtonGate waveshareBootPairingGate;
static bool waveshareBootWaitingForRelease = false;
static bool waveshareBootHandledPairingConfirmation = false;
static uint32_t waveshareBootReleaseStartMs = 0;
static uint32_t waveshareBootPressStartMs = 0;
static ownership_button_policy::FreshPowerButtonGate
    wavesharePowerPairingGate;
static uint32_t wavesharePowerPairingGeneration = 0;

// Called by the panel driver only after a frame has reached the display. This
// keeps physical confirmation disabled until the comparison code is visible.
void appDisplayFlushCompleted() {
  if (isWaitingPairingComparisonVisible()) {
    bleNavServer.noteOwnershipDisplayFlushCompleted();
  }
}

static void IRAM_ATTR latchWaveshareBootScreenCycle() {
  portENTER_CRITICAL_ISR(&waveshareBootButtonMux);
  waveshareBootScreenCyclePending = true;
  portEXIT_CRITICAL_ISR(&waveshareBootButtonMux);
  ui_scheduler::notifyFromIsr(ui_scheduler::WakeReason::Boot);
}

static bool takeWaveshareBootScreenCycle() {
  portENTER_CRITICAL(&waveshareBootButtonMux);
  const bool pending = waveshareBootScreenCyclePending;
  waveshareBootScreenCyclePending = false;
  portEXIT_CRITICAL(&waveshareBootButtonMux);
  return pending;
}

static bool processWaveshareBootButton() {
  constexpr uint32_t DEBOUNCE_MS = 50;

  const uint32_t now = millis();
  const bool pressed = digitalRead(BOARD_BOOT_PIN) == LOW;
  const bool physicalLatchedPress = takeWaveshareBootScreenCycle();
  const bool hadInput = physicalLatchedPress || pressed ||
                        deviceDebugHttp.bootPressRequested();

  if (waveshareBootPairingGate.blocksInput(pressed, now, DEBOUNCE_MS)) {
    return hadInput;
  }

  // Keep a remote press queued until the prior physical or remote press has
  // completed its debounced release. Once consumed, it follows the exact same
  // pairing, screen-cycle, and release-debounce path as a GPIO0 short press.
  const bool remotePress = !waveshareBootWaitingForRelease &&
                           deviceDebugHttp.takeBootPressRequest();
  const bool latchedPress = physicalLatchedPress || remotePress;

  if (!waveshareBootWaitingForRelease) {
    if (!latchedPress && !pressed) {
      return false;
    }

    waveshareBootWaitingForRelease = true;
    waveshareBootHandledPairingConfirmation = false;
    waveshareBootReleaseStartMs = 0;
    waveshareBootPressStartMs = now;
    waveshareBootHandledPairingConfirmation =
        ownership_button_policy::handleShortPress(
            [] { return bleNavServer.confirmOwnershipPairing(); },
            [] {
              if (!bleNavServer.hasOwnershipPairingCode()) {
                toggleNavigationScreen();
              }
            });
    if (waveshareBootHandledPairingConfirmation) {
      log_i("Waveshare BOOT pressed; handled ownership pairing");
    } else if (bleNavServer.hasOwnershipPairingCode()) {
      log_i("Waveshare BOOT press ignored until comparison is ready");
    } else {
      log_i("Waveshare BOOT pressed; handling forward action");
    }
    return true;
  }

  if (pressed) {
    waveshareBootReleaseStartMs = 0;
    return true;
  }

  if (waveshareBootReleaseStartMs == 0) {
    waveshareBootReleaseStartMs = now;
    return false;
  }

  if (now - waveshareBootReleaseStartMs < DEBOUNCE_MS) {
    return false;
  }

  waveshareBootWaitingForRelease = false;
  const uint32_t pressDurationMs = now - waveshareBootPressStartMs;
  log_i("Waveshare BOOT released after %lu ms",
        static_cast<unsigned long>(pressDurationMs));
  if (ownership_button_policy::shouldRecoverOwner(
          pressDurationMs, waveshareBootHandledPairingConfirmation)) {
    if (bleNavServer.forgetOwner()) {
      log_i("Waveshare BOOT long press cleared the registered iPhone");
    } else {
      log_i("Waveshare BOOT long press: no registered iPhone to clear");
    }
  }
  return false;
}

static bool processWavesharePowerButton() {
  waveshare_board::axp2101::PowerButtonEvents events;
  if (!waveshare_board::axp2101::readAndClearPowerButtonEvents(events)) {
    return false;
  }
  const bool hadInput =
      events.negativeEdge || events.positiveEdge || events.shortPress;

  if (bleNavServer.hasOwnershipPairingCode()) {
    if (wavesharePowerPairingGate.acceptEvents(
            wavesharePowerPairingGeneration, events.negativeEdge,
            events.positiveEdge, events.shortPress) &&
        bleNavServer.confirmOwnershipPairing()) {
      log_i("Waveshare PWR pressed; handled ownership pairing");
    }
    // Never honk while a pairing comparison is active, including before the
    // screen has flushed and the fresh-edge gate has been armed.
    return hadInput;
  }

  wavesharePowerPairingGate.cancel();
  wavesharePowerPairingGeneration = 0;
  if (events.shortPress) {
    waveshare_board::speaker::handlePowerButtonHonkPress();
  }
  return hadInput;
}

#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT &&                                      \
    (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206))
static void notifyAutomaticLightSleepGpioWake(uint64_t gpioMask) {
  const uint32_t reasons =
      ui_scheduler::gpioWakeReasons(gpioMask, TCH_I2C_INT, BOARD_BOOT_PIN);
  if (ui_scheduler::hasReason(reasons, ui_scheduler::WakeReason::Touch)) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Touch);
  }
  if (ui_scheduler::hasReason(reasons, ui_scheduler::WakeReason::Boot)) {
    ui_scheduler::notify(ui_scheduler::WakeReason::Boot);
  }
}
#endif

static void armOwnershipPairingAfterRenderedComparison() {
  uint32_t pairingGeneration = 0;
  if (!bleNavServer.ownershipPairingRenderedRequest(pairingGeneration)) {
    return;
  }

  // A registration can only consume input generated after this comparison
  // screen was rendered. Discard both hardware latches and require BOOT to be
  // observed released before its next press.
  (void)takeWaveshareBootScreenCycle();
  waveshareBootPairingGate.arm();
  waveshareBootWaitingForRelease = false;
  waveshareBootHandledPairingConfirmation = false;
  waveshareBootReleaseStartMs = 0;
  waveshareBootPressStartMs = 0;
  waveshare_board::axp2101::PowerButtonEvents stalePowerButtonEvents;
  if (!waveshare_board::axp2101::readAndClearPowerButtonEvents(
          stalePowerButtonEvents)) {
    return;
  }

  wavesharePowerPairingGate.arm(pairingGeneration);
  wavesharePowerPairingGeneration = pairingGeneration;
  if (bleNavServer.armOwnershipPairingConfirmation(pairingGeneration)) {
    log_i("Ownership pairing buttons armed after comparison render");
  } else {
    wavesharePowerPairingGate.cancel();
    wavesharePowerPairingGeneration = 0;
  }
}
#endif
extern Gps gps;
#ifdef ENABLE_COMPASS
Compass compass;
#endif

std::vector<wayPoint> trackData;

/**
 * @brief Sunrise and Sunset
 *
 */
static double transit, sunrise, sunset;
static uint32_t loopCount = 0;
static uint32_t lastLoopMs = 0;
static uint32_t maxLoopGapMs = 0;
static uint32_t lvglHandlerCount = 0;
static uint32_t lastLvglHandlerMs = 0;
static uint32_t lastLvglHandlerDurationUs = 0;
static uint32_t maxLvglHandlerDurationUs = 0;
static uint32_t nextLvglDelayMs = 0;
static uint32_t pendingUiWakeReasons = 0;
static uint32_t lastBleHousekeepingMs = 0;
static uint32_t lastShutdownHousekeepingMs = 0;
static uint32_t lastTransferHousekeepingMs = 0;
enum class PendingMapRendererActivationSource : uint8_t {
  None,
  Transfer,
  LabelRollback,
};
struct PendingMapRendererActivation {
  PendingMapRendererActivationSource source =
      PendingMapRendererActivationSource::None;
  std::string rendererRoot;
  std::string transferRoot;
  std::string labelFailure;
  std::string rollbackCode;
  bool rendererQueued = false;
  uint32_t queueAttemptStartedMs = 0;
};
static PendingMapRendererActivation pendingMapRendererActivation;
static constexpr uint32_t kMapRendererActivationQueueTimeoutMs = 10000U;
#if FIRMWARE_DIAGNOSTICS
static bool ordinaryRendererSessionActive = false;
static uint32_t ordinaryRendererWindowSequence = 0;
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
static display_inactivity::Policy displayInactivityPolicy;
static display_inactivity::Mode currentDisplayMode =
    display_inactivity::Mode::Active;
static uint32_t lastPowerButtonHousekeepingMs = 0;
#endif

static const char *remoteDebugStartErrorCode(
    device_debug::FrameStoreStartResult result) {
  switch (result) {
  case device_debug::FrameStoreStartResult::Started:
    return "";
  case device_debug::FrameStoreStartResult::UnsupportedBuild:
    return "remote_debug_unsupported";
  case device_debug::FrameStoreStartResult::InvalidGeometry:
    return "remote_debug_geometry";
  case device_debug::FrameStoreStartResult::FullFrameUnavailable:
    return "remote_debug_full_frame_unavailable";
  case device_debug::FrameStoreStartResult::MutexAllocationFailed:
    return "remote_debug_runtime_allocation";
  case device_debug::FrameStoreStartResult::InsufficientPsram:
    return "remote_debug_insufficient_psram";
  }
  return "remote_debug_setup";
}

bool startRemoteDeviceDebugSession() {
#if !DEVICE_REMOTE_DEBUG
  deviceTransferHttp.setLastError("remote_debug_unsupported",
                                  "this firmware has no remote debug service");
  return false;
#else
  const device_transfer::HttpTransferStatus status = deviceTransferHttp.status();
  if (status.enabled)
    return status.mode == "debug";
  if (!deviceTransferHttp.waitUntilStopped(2000)) {
    deviceTransferHttp.clearPreferredNetwork();
    deviceTransferHttp.setLastError("transfer_stopping",
                                    "previous transfer worker is still stopping");
    return false;
  }
  if (device_debug::frameStore().active()) {
    // Complete any deferred cleanup from a prior slow client before a fresh
    // transfer generation allocates session state.
    deviceDebugHttp.cancelSession();
    deviceDebugHttp.finishSessionTeardown();
  }
  const device_debug::FrameStoreStartResult started =
      deviceDebugHttp.beginSession(hasFullScreenRgb565Buffer());
  if (started != device_debug::FrameStoreStartResult::Started) {
    deviceTransferHttp.clearPreferredNetwork();
    deviceTransferHttp.setLastError(remoteDebugStartErrorCode(started),
                                    "remote debug session could not start");
    return false;
  }
  mapView.setRendererTuningProfile(renderer_tuning::Profile::Current,
                                   millis());
  renderer_diagnostics::beginSession(true, millis());
#if FIRMWARE_DIAGNOSTICS
  ordinaryRendererSessionActive = false;
#endif
  if (!deviceTransferHttp.setEnabled(true, "debug")) {
    deviceTransferHttp.clearPreferredNetwork();
    mapView.setRendererTuningProfile(renderer_tuning::Profile::Current,
                                     millis());
    renderer_diagnostics::endSession(millis());
    deviceDebugHttp.cancelSession();
    deviceDebugHttp.finishSessionTeardown();
    return false;
  }
  device_debug::frameStore().requestNextFrame();
  if (lv_screen_active() != nullptr)
    lv_obj_invalidate(lv_screen_active());
  return true;
#endif
}

bool stopActiveDeviceTransfer() {
  const device_transfer::HttpTransferStatus status = deviceTransferHttp.status();
  if (status.mode == "map")
    return mapTransferHttp.setEnabled(false);
  if (status.mode == "firmware")
    return firmwareUpdateHttp.setEnabled(false);
  if (status.mode == "debug" || device_debug::frameStore().active()) {
    // setEnabled(false) revokes the authorization generation before the debug
    // state and snapshot are reclaimed.
    const bool revoked = deviceTransferHttp.setEnabled(false);
    deviceDebugHttp.cancelSession();
    mapView.setRendererTuningProfile(renderer_tuning::Profile::Current,
                                     millis());
    renderer_diagnostics::endSession(millis());
#if FIRMWARE_DIAGNOSTICS
    ordinaryRendererSessionActive = false;
#endif
    const bool stopped = deviceTransferHttp.waitUntilStopped(5500);
    if (stopped) {
      // A handler that passed authorization immediately before revocation can
      // publish a request after the first clear. Once the worker has stopped,
      // clear session-scoped input again before reclaiming the frame store.
      deviceDebugHttp.cancelSession();
      deviceDebugHttp.finishSessionTeardown();
    } else
      deviceTransferHttp.setLastError(
          "remote_debug_worker_stopping",
          "remote debug HTTP worker did not stop before cleanup deadline");
    return revoked && stopped;
  }
  return deviceTransferHttp.setEnabled(false);
}

#if FIRMWARE_DIAGNOSTICS
static bool readActiveRendererMap(
    map_transfer::ActiveMapSelection &active) {
  map_transfer::MapTransferInstaller installer("/sdcard");
  const map_transfer::InstallStatus status = installer.readActiveMap(active);
  if (!status.ok) {
    Serial.printf(
        "RENDERER_DIAGNOSTICS: rejected map fixture active_status=%s\n",
        status.code.c_str());
    return false;
  }
  return true;
}

static bool populateOrdinaryRendererIdentity(
    const renderer_diagnostics_ble_protocol::WindowRequest &request,
    renderer_diagnostics::RunIdentity &identity) {
  map_transfer::ActiveMapSelection active;
  if (!readActiveRendererMap(active) || active.manifestReceipt.empty())
    return false;
  char runId[renderer_diagnostics::kIdentityTextBytes] = {};
  std::snprintf(runId, sizeof(runId), "ble-%016llx",
                static_cast<unsigned long long>(request.runNonce));
  char routeHash[renderer_diagnostics::kSha256TextBytes] = {};
  static constexpr char kHex[] = "0123456789abcdef";
  for (size_t index = 0;
       index < renderer_diagnostics_ble_protocol::SHA256_BYTES; ++index) {
    routeHash[index * 2] = kHex[request.routeFixtureSha256[index] >> 4U];
    routeHash[index * 2 + 1] =
        kHex[request.routeFixtureSha256[index] & 0x0fU];
  }
  const bool copied = identity.runId.assign(runId) &&
                      identity.mapFixtureId.assign(active.mapId.c_str()) &&
                      identity.mapFixtureSha256.assign(
                          active.manifestReceipt.c_str()) &&
                      identity.routeFixtureId.assign(request.routeFixtureId) &&
                      identity.routeFixtureSha256.assign(routeHash) &&
                      identity.routeMode.assign("ordinary-ble-1hz");
  identity.repeat = request.repeat;
  if (!copied) {
    Serial.println(
        "RENDERER_DIAGNOSTICS: active map or route identity is too long");
  }
  return copied;
}
#endif

#if DEVICE_REMOTE_DEBUG
static bool rendererRequestMatchesActiveMap(
    const renderer_diagnostics::RunIdentity &identity) {
  map_transfer::ActiveMapSelection active;
  if (!readActiveRendererMap(active))
    return false;
  const bool matches =
      active.mapId == identity.mapFixtureId.c_str() &&
      !active.manifestReceipt.empty() &&
      active.manifestReceipt == identity.mapFixtureSha256.c_str();
  if (!matches) {
    Serial.printf(
        "RENDERER_DIAGNOSTICS: rejected map fixture requested=%s/%.*s "
        "active=%s/%.*s\n",
        identity.mapFixtureId.c_str(), 12,
        identity.mapFixtureSha256.c_str(), active.mapId.c_str(), 12,
        active.manifestReceipt.c_str());
  }
  return matches;
}
#endif

void appRemoteDebugPointerActivity() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  displayInactivityPolicy.noteMeaningfulActivity(millis());
#endif
}

#include "lvglSetup.hpp"
#include "settings.hpp"
#include "tasks.hpp"
#include "timezone.c"

/**
 * @brief Calculate Sunrise and Sunset
 *        Must be a global function
 *
 */
void calculateSun() {
  calcSunriseSunset(2000 + fix.dateTime.year, fix.dateTime.month,
                    fix.dateTime.date, gps.gpsData.latitude,
                    gps.gpsData.longitude, transit, sunrise, sunset);
  int hours = (int)sunrise + gps.gpsData.UTC;
  int minutes = (int)round(((sunrise + gps.gpsData.UTC) - hours) * 60);
  snprintf(gps.gpsData.sunriseHour, 6, "%02d:%02d", hours, minutes);
  hours = (int)sunset + gps.gpsData.UTC;
  minutes = (int)round(((sunset + gps.gpsData.UTC) - hours) * 60);
  snprintf(gps.gpsData.sunsetHour, 6, "%02d:%02d", hours, minutes);
  log_i("Sunrise: %s", gps.gpsData.sunriseHour);
  log_i("Sunset: %s", gps.gpsData.sunsetHour);
}

static const char *debugTileName(uint8_t tile) {
  switch (tile) {
  case COMPASS:
    return "COMPASS";
  case MAP:
    return "MAP";
  case MAP_GUIDANCE:
    return "MAP_GUIDANCE";
  case NAV:
    return "NAV";
  case SATTRACK:
    return "SATTRACK";
  case RIDESTATS:
    return "RIDESTATS";
  case BATTERY_STATUS:
    return "BATTERY_STATUS";
  default:
    return "UNKNOWN";
  }
}

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
static const char *displayInactivityModeName(display_inactivity::Mode mode) {
  switch (mode) {
  case display_inactivity::Mode::Active:
    return "active";
  case display_inactivity::Mode::Dimmed:
    return "dimmed";
  case display_inactivity::Mode::DisplayOff:
    return "off";
  case display_inactivity::Mode::Transfer:
    return "transfer";
  }
  return "unknown";
}

static bool processTransferInactivityTimeout(uint32_t nowMs) {
  static uint32_t lastCheckMs = 0;
  constexpr uint32_t kCheckPeriodMs = 1'000;
  if (lastCheckMs != 0 && nowMs - lastCheckMs < kCheckPeriodMs) {
    return false;
  }
  lastCheckMs = nowMs;

  const device_transfer::HttpTransferStatus transferStatus =
      deviceTransferHttp.status();
  if (!transferStatus.enabled ||
      !display_inactivity::transferInactivityElapsed(
          nowMs, transferStatus.lastUsefulTrafficMs,
          display_inactivity::kTransferInactivityTimeoutMs,
          transferStatus.authorizedRequestInProgress)) {
    return false;
  }

  // Map activation continues after its initiating HTTP request. Do not revoke
  // the AP while that transactional install is still using it.
  if (mapTransferHttp.activationSnapshot().running) {
    return false;
  }

  const bool disabled = stopActiveDeviceTransfer();
  Serial.printf(
      "DEVICE_TRANSFER_HTTP: inactivity timeout mode=%s disabled=%d\n",
      transferStatus.mode.empty() ? "unknown" : transferStatus.mode.c_str(),
      disabled);
  return disabled;
}

static display_inactivity::Update updateDisplayInactivityPolicy(
    uint32_t nowMs, bool touchWake, bool &observedTouchActivity) {
  struct Signals {
    bool initialized = false;
    lv_obj_t *screen = nullptr;
    uint8_t tile = 0;
    uint32_t connectCount = 0;
    uint32_t authSuccessCount = 0;
    uint32_t navPacketCount = 0;
    uint32_t routeRevision = 0;
    uint8_t maneuverIcon = 0;
    uint16_t maneuverDistance = 0;
    std::string maneuverInstruction;
    bool pairing = false;
    uint32_t lastPairingPollMs = 0;
    bool transferEnabled = false;
    std::string transferMode;
    uint32_t transferErrorSequence = 0;
    uint32_t activationSequence = 0;
    uint8_t activationProgress = 0;
    bool activationRunning = false;
    uint32_t lastTransferPollMs = 0;
    bool audioActive = false;
    bool rideAutomationAttention = false;
    bool touchPending = false;
    uint32_t touchActivityGeneration = 0;
  };
  static Signals signals;

  const BLEDebugStats bleStats = bleNavServer.getDebugStats();
  const bool audioActive = waveshare_board::speaker::isPlaying();
  const bool rideAutomationAttention =
      ride_automation_runtime::needsAttention(nowMs);
  const bool touchPending = hasUnattemptedTouchInterrupt();
  const uint32_t touchActivityGeneration = getTouchActivityGeneration();
  lv_obj_t *const activeScreen = lv_screen_active();
  const uint32_t routeRevision = routeOverlay.revision();

  observedTouchActivity = touchWake;
  bool meaningfulActivity = touchWake;
  if (!signals.initialized) {
    signals.initialized = true;
    signals.screen = activeScreen;
    signals.tile = activeTile;
    signals.connectCount = bleStats.connectCount;
    signals.authSuccessCount = bleStats.authSuccessCount;
    signals.navPacketCount = bleStats.navPacketCount;
    signals.routeRevision = routeRevision;
    const NavigationData maneuver = getCurrentNavigationData();
    signals.maneuverIcon = maneuver.iconID;
    signals.maneuverDistance = maneuver.distance;
    signals.maneuverInstruction = maneuver.instruction;
    signals.pairing = bleNavServer.hasOwnershipPairingCode();
    signals.lastPairingPollMs = nowMs;
    const device_transfer::HttpTransferStatus transferStatus =
        deviceTransferHttp.status();
    signals.transferEnabled = transferStatus.enabled;
    signals.transferMode = transferStatus.mode;
    signals.transferErrorSequence = transferStatus.errorSequence;
    const map_transfer::MapActivationSnapshot activation =
        mapTransferHttp.activationSnapshot();
    signals.activationSequence = activation.sequence;
    signals.activationProgress = activation.progress;
    signals.activationRunning = activation.running;
    signals.lastTransferPollMs = nowMs;
    signals.audioActive = audioActive;
    signals.rideAutomationAttention = rideAutomationAttention;
    signals.touchPending = touchPending;
    signals.touchActivityGeneration = touchActivityGeneration;
  } else {
    const bool decodedTouchActivity =
        display_inactivity::touchActivityAdvanced(
            touchActivityGeneration, signals.touchActivityGeneration);
    observedTouchActivity =
        observedTouchActivity || decodedTouchActivity;
    meaningfulActivity =
        meaningfulActivity || activeScreen != signals.screen ||
        activeTile != signals.tile ||
        bleStats.connectCount != signals.connectCount ||
        bleStats.authSuccessCount != signals.authSuccessCount ||
        routeRevision != signals.routeRevision ||
        audioActive != signals.audioActive ||
        rideAutomationAttention != signals.rideAutomationAttention ||
        (touchPending && !signals.touchPending) || decodedTouchActivity;
    signals.screen = activeScreen;
    signals.tile = activeTile;
    signals.connectCount = bleStats.connectCount;
    signals.authSuccessCount = bleStats.authSuccessCount;
    signals.routeRevision = routeRevision;
    signals.audioActive = audioActive;
    signals.rideAutomationAttention = rideAutomationAttention;
    signals.touchPending = touchPending;
    signals.touchActivityGeneration = touchActivityGeneration;

    if (bleStats.navPacketCount != signals.navPacketCount) {
      signals.navPacketCount = bleStats.navPacketCount;
      const NavigationData maneuver = getCurrentNavigationData();
      const std::string instruction = maneuver.instruction;
      meaningfulActivity =
          meaningfulActivity || maneuver.iconID != signals.maneuverIcon ||
          instruction != signals.maneuverInstruction ||
          display_inactivity::maneuverDataBecameActive(
              signals.maneuverDistance,
              !signals.maneuverInstruction.empty(), maneuver.distance,
              !instruction.empty()) ||
          display_inactivity::crossedCloserManeuverDistanceThreshold(
              signals.maneuverDistance, maneuver.distance);
      signals.maneuverIcon = maneuver.iconID;
      signals.maneuverDistance = maneuver.distance;
      signals.maneuverInstruction = instruction;
    }

    constexpr uint32_t kPairingPollPeriodMs = 100;
    if (nowMs - signals.lastPairingPollMs >= kPairingPollPeriodMs) {
      signals.lastPairingPollMs = nowMs;
      const bool pairing = bleNavServer.hasOwnershipPairingCode();
      meaningfulActivity = meaningfulActivity || pairing != signals.pairing;
      signals.pairing = pairing;
    }

    constexpr uint32_t kTransferPollPeriodMs = 250;
    if (nowMs - signals.lastTransferPollMs >= kTransferPollPeriodMs) {
      signals.lastTransferPollMs = nowMs;
      const device_transfer::HttpTransferStatus transferStatus =
          deviceTransferHttp.status();
      const map_transfer::MapActivationSnapshot activation =
          mapTransferHttp.activationSnapshot();
      meaningfulActivity =
          meaningfulActivity ||
          transferStatus.enabled != signals.transferEnabled ||
          transferStatus.mode != signals.transferMode ||
          (!transferStatus.lastErrorCode.empty() &&
           transferStatus.errorSequence != signals.transferErrorSequence) ||
          activation.sequence != signals.activationSequence ||
          (activation.running &&
           (activation.progress != signals.activationProgress ||
            !signals.activationRunning));
      signals.transferEnabled = transferStatus.enabled;
      signals.transferMode = transferStatus.mode;
      signals.transferErrorSequence = transferStatus.errorSequence;
      signals.activationSequence = activation.sequence;
      signals.activationProgress = activation.progress;
      signals.activationRunning = activation.running;
    }
  }

  if (meaningfulActivity) {
    displayInactivityPolicy.noteMeaningfulActivity(nowMs);
  }

  display_inactivity::Context context;
  context.navigating =
      bleStats.connected && bleStats.authenticated &&
      (routeOverlay.hasRoute() || hasCurrentNavigationData());
  context.workoutActive =
      bleStats.connected && bleStats.authenticated &&
      workout_telemetry_runtime::isWorkoutActive();
  context.transferActive =
      (signals.transferEnabled && signals.transferMode != "debug") ||
      signals.activationRunning;
  context.attentionActive =
      signals.pairing || audioActive || rideAutomationAttention;
  const display_inactivity::Update update =
      displayInactivityPolicy.update(nowMs, context);
  currentDisplayMode = update.current;
  if (!update.changed) {
    return update;
  }

  const bool displayOff =
      update.current == display_inactivity::Mode::DisplayOff;
  const bool dimmed = update.current == display_inactivity::Mode::Dimmed;
  displayPowerManager.requestState(
      displayOff ? display_power::State::Off
                 : (dimmed ? display_power::State::Dimmed
                            : display_power::State::Active));

  if (mainTimer != nullptr) {
    if (displayOff) {
      lv_timer_pause(mainTimer);
    } else if (isMainScreen) {
      lv_timer_set_period(mainTimer,
                          dimmed ? 250 : UPDATE_MAINSCR_PERIOD);
      lv_timer_resume(mainTimer);
      if (update.displayWakeRequired) {
        lv_timer_ready(mainTimer);
      }
    }
  }

  Serial.printf("DisplayPower: mode %s -> %s idleMs=%lu\n",
                displayInactivityModeName(update.previous),
                displayInactivityModeName(update.current),
                static_cast<unsigned long>(display_inactivity::elapsedMs(
                    nowMs,
                    displayInactivityPolicy.lastMeaningfulActivityMs())));
  return update;
}
#endif

static void logSystemDebugHeartbeat() {
#if !FIRMWARE_DIAGNOSTICS
  return;
#else
  static uint32_t lastLogMs = 0;
  uint32_t now = millis();
  if (now - lastLogMs < 5000) {
    return;
  }
  lastLogMs = now;

  BLEDebugStats bleStats = bleNavServer.getDebugStats();
  const uint32_t gpsAgeMs =
      bleStats.gpsPacketCount != 0 ? now - bleStats.lastGpsPacketMs : 0U;
#if (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)) &&       \
    defined(WAVESHARE_IMU_DIAGNOSTICS)
  const waveshare_board::i2c::Stats &i2cStats = waveshare_board::i2c::stats();
  const waveshare_board::rtc::Status &rtcStatus =
      waveshare_board::rtc::status();
  const waveshare_board::imu::Status &imuStatus =
      waveshare_board::imu::status();
  const waveshare_board::imu::Sample &imuSample =
      waveshare_board::imu::lastSample();
#elif defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const waveshare_board::i2c::Stats &i2cStats = waveshare_board::i2c::stats();
  const waveshare_board::rtc::Status &rtcStatus =
      waveshare_board::rtc::status();
#endif
  const char *screenName = "unknown";
  lv_obj_t *activeScreen = lv_scr_act();
  if (activeScreen == waitingScreen) {
    screenName = "waiting";
  } else if (isMainScreen) {
    screenName = "main";
  }

#if (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)) &&       \
    defined(WAVESHARE_IMU_DIAGNOSTICS)
  Serial.printf("IMU: p=%d cfg=%d valid=%d addr=0x%02X n=%lu zero=%lu fail=%lu "
                "a=%.0f,%.0f,%.0f g=%.1f,%.1f,%.1f mag=%.0f vib=%.1f "
                "orient=%s moving=%d\n",
                imuStatus.present, imuStatus.configured, imuStatus.dataValid,
                imuStatus.address,
                (unsigned long)imuStatus.sampleCount,
                (unsigned long)imuStatus.zeroSamples,
                (unsigned long)imuStatus.failedReads, imuSample.accelMg[0],
                imuSample.accelMg[1], imuSample.accelMg[2],
                imuSample.gyroDps[0], imuSample.gyroDps[1],
                imuSample.gyroDps[2], imuStatus.accelMagnitudeMg,
                imuStatus.vibrationDps,
                waveshare_board::imu::orientationName(imuStatus.orientation),
                imuStatus.moving);
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  Serial.printf("SYS: up=%lus heap=%lu psram=%lu screen=%s tile=%s "
                "displayMode=%s "
                "waitRefresh=%d gpsFromApp=%d pendingMap=%d "
                "gps[fix=%u heading=%u] routePts=%u mapFound=%d mapBlocks=%u "
                "mapFlags[pos=%d redraw=%d follow=%d vector=%d zoom=%u] "
                "ui[loop=%lu maxGapMs=%lu lvgl=%lu lastLvglMs=%lu "
                "lvglUs=%lu/%lu flush=%lu lastFlushMs=%lu flushUs=%lu/%lu] "
                "pose[gpsAgeMs=%lu predictionAgeMs=%lu grace=%d "
                "exhausted=%d exhaustions=%lu lastExhaustedMs=%lu] "
                "ble[conn=%d auth=%d nav=%lu route=%lu gps=%lu settings=%lu "
                "gpsGapMs=%lu/%lu] "
                "i2c[fail=%lu recover=%lu recovered=%lu missing=%lu] "
                "rtc[present=%d valid=%d source=%s unix=%lld]\n",
                (unsigned long)(now / 1000),
                (unsigned long)ESP.getFreeHeap(),
                (unsigned long)ESP.getFreePsram(), screenName,
                debugTileName(activeTile),
                displayInactivityModeName(currentDisplayMode),
                waitScreenRefresh,
                gpsReceivedFromApp, pendingTransitionToMap,
                (unsigned)gps.gpsData.fixMode,
                (unsigned)gps.gpsData.heading,
                (unsigned)routeOverlay.getPointCount(),
                mapView.debugIsMapFound(),
                (unsigned)mapView.debugCachedBlockCount(), mapView.isPosMoved,
                mapView.redrawMap, mapView.followGps, mapSet.vectorMap, zoom,
                (unsigned long)loopCount, (unsigned long)maxLoopGapMs,
                (unsigned long)lvglHandlerCount,
                (unsigned long)lastLvglHandlerMs,
                (unsigned long)lastLvglHandlerDurationUs,
                (unsigned long)maxLvglHandlerDurationUs,
                (unsigned long)displayFlushCount,
                (unsigned long)lastDisplayFlushMs,
                (unsigned long)lastDisplayFlushDurationUs,
                (unsigned long)maxDisplayFlushDurationUs,
                (unsigned long)gpsAgeMs,
                (unsigned long)mapView.debugPredictionAgeMs(),
                mapView.debugPredictionGraceActive(),
                mapView.debugPredictionExhausted(),
                (unsigned long)mapView.debugPredictionExhaustionCount(),
                (unsigned long)mapView.debugLastPredictionExhaustedMs(),
                bleStats.connected, bleStats.authenticated,
                (unsigned long)bleStats.navPacketCount,
                (unsigned long)bleStats.routePacketCount,
                (unsigned long)bleStats.gpsPacketCount,
                (unsigned long)bleStats.settingsPacketCount,
                (unsigned long)bleStats.lastGpsPacketGapMs,
                (unsigned long)bleStats.maximumGpsPacketGapMs,
                (unsigned long)i2cStats.failedTransactions,
                (unsigned long)i2cStats.recoveryAttempts,
                (unsigned long)i2cStats.recoveredTransactions,
                (unsigned long)i2cStats.missingDevices, rtcStatus.present,
                rtcStatus.timeValid,
                waveshare_board::rtc::sourceName(rtcStatus.source),
                static_cast<long long>(rtcStatus.unixTime));
#else
  Serial.printf("SYS: up=%lus heap=%lu psram=%lu screen=%s tile=%s "
                "waitRefresh=%d gpsFromApp=%d pendingMap=%d "
                "gps[fix=%u heading=%u] routePts=%u mapFound=%d mapBlocks=%u "
                "mapFlags[pos=%d redraw=%d follow=%d vector=%d zoom=%u] "
                "ui[loop=%lu maxGapMs=%lu lvgl=%lu lastLvglMs=%lu "
                "lvglUs=%lu/%lu flush=%lu lastFlushMs=%lu flushUs=%lu/%lu] "
                "pose[gpsAgeMs=%lu predictionAgeMs=%lu grace=%d "
                "exhausted=%d exhaustions=%lu lastExhaustedMs=%lu] "
                "ble[conn=%d auth=%d nav=%lu route=%lu gps=%lu settings=%lu "
                "gpsGapMs=%lu/%lu]\n",
                (unsigned long)(now / 1000),
                (unsigned long)ESP.getFreeHeap(),
                (unsigned long)ESP.getFreePsram(), screenName,
                debugTileName(activeTile), waitScreenRefresh,
                gpsReceivedFromApp, pendingTransitionToMap,
                (unsigned)gps.gpsData.fixMode,
                (unsigned)gps.gpsData.heading,
                (unsigned)routeOverlay.getPointCount(),
                mapView.debugIsMapFound(),
                (unsigned)mapView.debugCachedBlockCount(), mapView.isPosMoved,
                mapView.redrawMap, mapView.followGps, mapSet.vectorMap, zoom,
                (unsigned long)loopCount, (unsigned long)maxLoopGapMs,
                (unsigned long)lvglHandlerCount,
                (unsigned long)lastLvglHandlerMs,
                (unsigned long)lastLvglHandlerDurationUs,
                (unsigned long)maxLvglHandlerDurationUs, 0UL, 0UL, 0UL, 0UL,
                (unsigned long)gpsAgeMs,
                (unsigned long)mapView.debugPredictionAgeMs(),
                mapView.debugPredictionGraceActive(),
                mapView.debugPredictionExhausted(),
                (unsigned long)mapView.debugPredictionExhaustionCount(),
                (unsigned long)mapView.debugLastPredictionExhaustedMs(),
                bleStats.connected, bleStats.authenticated,
                (unsigned long)bleStats.navPacketCount,
                (unsigned long)bleStats.routePacketCount,
                (unsigned long)bleStats.gpsPacketCount,
                (unsigned long)bleStats.settingsPacketCount,
                (unsigned long)bleStats.lastGpsPacketGapMs,
                (unsigned long)bleStats.maximumGpsPacketGapMs);
#endif
#endif
}

static const char *powerMetricsDisplayStateName(
    power_metrics::DisplayState state) {
  switch (state) {
  case power_metrics::DisplayState::On:
    return "on";
  case power_metrics::DisplayState::Off:
    return "off";
  case power_metrics::DisplayState::Unknown:
  default:
    return "unknown";
  }
}

static void logPowerMetricsReport() {
#if POWER_METRICS
  constexpr size_t kReportBufferSize = 2048;
  static char report[kReportBufferSize];
  static uint32_t lastReportMs = 0;
  const uint32_t now = millis();
  if (now - lastReportMs < 10000) {
    return;
  }
  const uint32_t intervalMs = now - lastReportMs;
  lastReportMs = now;

  const power_metrics::RuntimeSnapshot snapshot =
      power_metrics::snapshotAndReset();
  const power_metrics::IntervalData &metrics = snapshot.interval;
  const BLEDebugStats bleStats = bleNavServer.getDebugStats();
  const device_transfer::HttpTransferStatus transferStatus =
      deviceTransferHttp.status();
  const power_management::RuntimeStatus powerManagementStatus =
      power_management::status();

  const char *screenName = "unknown";
  const lv_obj_t *activeScreen = lv_scr_act();
  if (activeScreen == waitingScreen) {
    screenName = "waiting";
  } else if (isMainScreen) {
    screenName = "main";
  }

  bool audioActive = false;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const char *powerMode = displayInactivityModeName(currentDisplayMode);
#else
  const char *powerMode = "unsupported";
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  audioActive = waveshare_board::speaker::isPlaying();
#endif

  const auto bleCount = [&](power_metrics::BlePacketClass packetClass) {
    return metrics.blePacketCounts[static_cast<size_t>(packetClass)];
  };

  const int reportLength = snprintf(
      report, sizeof(report),
      "PWRMET v=%u intervalMs=%lu screen=%s tile=%s display=%s "
      "brightness[requested=%u effective=%u] "
      "loop[wakes=%llu maxGapMs=%lu] "
      "lvgl[count=%lu totalUs=%llu maxUs=%lu] "
      "flush[count=%lu rotationUs=%llu/%lu qspiUs=%llu/%lu "
      "totalUs=%llu/%lu] "
      "map[count=%lu completed=%lu interrupted=%lu totalUs=%llu/%lu "
      "blocksUs=%llu/%lu drawUs=%llu/%lu routeUs=%llu/%lu "
      "reasons=position:%lu,route:%lu,style:%lu,heading:%lu,zoom:%lu,"
      "screen:%lu,recovery:%lu,other:%lu] "
      "ble[connected=%d authenticated=%d "
      "logical=nav:%lu,route:%lu,gps:%lu,settings:%lu,workout:%lu,"
      "transfer:%lu,audio:%lu,control:%lu,auth:%lu "
      "appQueue=ios-diagnostic "
      "radio=txDbm:%d,advMode:%u,requestedProfile:%u,valid:%d,"
      "intervalUnits:%u,latency:%u,timeoutUnits:%u,samples:%lu] "
      "system[powerMode=%s wifiMode=%d transfer=%d transferMode=%s "
      "audio=%d cpuMHz=%u dfs=%d pmError=%d minCpuMHz=%u maxCpuMHz=%u "
      "lightSleep=%d "
      "appPmLocks=%lu peakPmLocks=%lu pmLockFailures=%lu "
      "ext1WakeMask=0x%llX gpioWakeMask=0x%llX "
      "gpioWakeLast=0x%llX gpioWakeEvents=%lu "
      "wakeCapture=%d wakeNotifier=%d pmWakeFailures=%lu "
      "startupComplete=%d]\n",
      power_metrics::kSchemaVersion, (unsigned long)intervalMs, screenName,
      debugTileName(activeTile),
      powerMetricsDisplayStateName(snapshot.displayState),
      snapshot.requestedBrightness, snapshot.effectiveBrightness,
      static_cast<unsigned long long>(metrics.loopWakeCount),
      (unsigned long)metrics.maxLoopGapMs, (unsigned long)metrics.lvgl.count,
      static_cast<unsigned long long>(metrics.lvgl.totalUs),
      (unsigned long)metrics.lvgl.maxUs,
      (unsigned long)metrics.displayFlush.count,
      static_cast<unsigned long long>(metrics.displayRotation.totalUs),
      (unsigned long)metrics.displayRotation.maxUs,
      static_cast<unsigned long long>(metrics.displayQspi.totalUs),
      (unsigned long)metrics.displayQspi.maxUs,
      static_cast<unsigned long long>(metrics.displayFlush.totalUs),
      (unsigned long)metrics.displayFlush.maxUs,
      (unsigned long)metrics.mapRender.count,
      (unsigned long)metrics.mapRenderCompleted,
      (unsigned long)metrics.mapRenderInterrupted,
      static_cast<unsigned long long>(metrics.mapRender.totalUs),
      (unsigned long)metrics.mapRender.maxUs,
      static_cast<unsigned long long>(metrics.mapBlocks.totalUs),
      (unsigned long)metrics.mapBlocks.maxUs,
      static_cast<unsigned long long>(metrics.mapDraw.totalUs),
      (unsigned long)metrics.mapDraw.maxUs,
      static_cast<unsigned long long>(metrics.mapRoute.totalUs),
      (unsigned long)metrics.mapRoute.maxUs,
      (unsigned long)metrics.mapReasonCounts[0],
      (unsigned long)metrics.mapReasonCounts[1],
      (unsigned long)metrics.mapReasonCounts[2],
      (unsigned long)metrics.mapReasonCounts[3],
      (unsigned long)metrics.mapReasonCounts[4],
      (unsigned long)metrics.mapReasonCounts[5],
      (unsigned long)metrics.mapReasonCounts[6],
      (unsigned long)metrics.mapReasonCounts[7],
      bleStats.connected, bleStats.authenticated,
      (unsigned long)bleCount(power_metrics::BlePacketClass::Navigation),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Route),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Gps),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Settings),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Workout),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Transfer),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Audio),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Control),
      (unsigned long)bleCount(power_metrics::BlePacketClass::Auth),
      static_cast<int>(bleStats.txPowerDbm),
      static_cast<unsigned>(bleStats.advertisingMode),
      static_cast<unsigned>(bleStats.requestedConnectionProfile),
      bleStats.connectionParametersValid, bleStats.connectionIntervalUnits,
      bleStats.connectionLatency, bleStats.supervisionTimeoutUnits,
      (unsigned long)bleStats.connectionParameterSampleCount,
      powerMode, static_cast<int>(WiFi.getMode()), transferStatus.enabled,
      transferStatus.mode.empty() ? "none" : transferStatus.mode.c_str(),
      audioActive, getCpuFrequencyMhz(), powerManagementStatus.enabled,
      powerManagementStatus.errorCode,
      powerManagementStatus.effective.minimumCpuMhz,
      powerManagementStatus.effective.maximumCpuMhz,
      powerManagementStatus.effective.automaticLightSleep,
      (unsigned long)powerManagementStatus.activeLockCount,
      (unsigned long)powerManagementStatus.peakLockCount,
      (unsigned long)powerManagementStatus.lockFailureCount,
      static_cast<unsigned long long>(powerManagementStatus.ext1WakeMask),
      static_cast<unsigned long long>(powerManagementStatus.gpioWakeMask),
      static_cast<unsigned long long>(
          powerManagementStatus.lastGpioWakeMask),
      (unsigned long)powerManagementStatus.gpioWakeEventCount,
      powerManagementStatus.wakeCaptureReady,
      powerManagementStatus.wakeNotifierReady,
      (unsigned long)powerManagementStatus.wakeSourceFailureCount,
      powerManagementStatus.startupComplete);
  if (reportLength < 0 ||
      static_cast<size_t>(reportLength) >= sizeof(report)) {
    Serial.printf("PWRMET_ERROR formatLength=%d capacity=%u\n", reportLength,
                  static_cast<unsigned>(sizeof(report)));
    return;
  }

  const size_t written = Serial.write(
      reinterpret_cast<const uint8_t *>(report),
      static_cast<size_t>(reportLength));
  if (written != static_cast<size_t>(reportLength)) {
    Serial.printf("PWRMET_ERROR serialWrite=%u/%u\n",
                  static_cast<unsigned>(written),
                  static_cast<unsigned>(reportLength));
  }
#endif
}

static void processDisconnectedShutdown() {
  static disconnected_shutdown_policy::Tracker shutdownTracker;
  const bool connected = bleNavServer.isConnected();
  const bool ownershipClaimed = bleNavServer.isOwnershipClaimed();
  const disconnected_shutdown_policy::UpdateResult result =
      shutdownTracker.update(
          millis(), connected,
          mapRenderSettings.disconnectedSleepTimeoutSeconds,
          ownershipClaimed);

  if (result.action ==
      disconnected_shutdown_policy::Action::CountdownStarted) {
    Serial.printf(
        "Power: app not connected; shutdown in %lu seconds if still "
        "disconnected%s\n",
        (unsigned long)result.timeoutSeconds,
        result.waitingForRegistration ? " (registration grace)" : "");
    return;
  }

  if (result.action != disconnected_shutdown_policy::Action::ShutdownDue &&
      result.action != disconnected_shutdown_policy::Action::ShutdownRetry) {
    return;
  }

  if (result.action == disconnected_shutdown_policy::Action::ShutdownDue) {
    Serial.printf("Power: app was disconnected for %lu seconds; entering deep "
                  "sleep\n",
                  (unsigned long)result.timeoutSeconds);
    Serial.println("Power: press BOOT to wake the device");
    Serial.flush();
  }

  power.deviceShutdown();
}

/**
 * @brief Setup
 *
 */
void setup() {
#ifdef HAS_HARDWARE_GPS
  gpsMutex = xSemaphoreCreateMutex();
#endif
#if FIRMWARE_DIAGNOSTICS
  esp_log_level_set("*", ESP_LOG_DEBUG);
  esp_log_level_set("storage", ESP_LOG_DEBUG);
#else
  esp_log_level_set("*", ESP_LOG_NONE);
#endif
#if FIRMWARE_DIAGNOSTICS
  char rendererDeviceId[17] = {};
  std::snprintf(rendererDeviceId, sizeof(rendererDeviceId), "%016llx",
                static_cast<unsigned long long>(ESP.getEfuseMac()));
  renderer_diagnostics::configureBuildIdentity(
      rendererDeviceId, firmware_metadata::gitSha(),
      firmware_metadata::target(), firmware_metadata::buildProfile(),
      esp_random(), static_cast<uint32_t>(esp_reset_reason()));
#endif

  // Initialize Serial for debug. BOOT_PREVIOUS and complete PWRMET reports are
  // larger than the default 256-byte HWCDC queue. Reserve enough room before
  // opening USB CDC so the host-attach window cannot truncate their tails.
#if POWER_METRICS ||                                                         \
    (FIRMWARE_DIAGNOSTICS &&                                                \
     (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)))
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  constexpr size_t kSerialTxBufferSize =
      boot_diagnostics::kStructuredSerialTxBufferSize;
#else
  constexpr size_t kSerialTxBufferSize = 4096;
#endif
  const size_t configuredSerialTxBufferSize =
      Serial.setTxBufferSize(kSerialTxBufferSize);
#endif
#if FIRMWARE_DIAGNOSTICS || POWER_METRICS
  Serial.begin(115200);
  // HWCDC uses this value as both a timeout and a retry counter. Zero
  // underflows that counter when the USB host stops reading and stalls the UI.
  Serial.setTxTimeoutMs(1);
#endif
#if POWER_METRICS
  if (configuredSerialTxBufferSize != kSerialTxBufferSize) {
    Serial.printf("PWRMET_ERROR txBuffer=%u/%u\n",
                  static_cast<unsigned>(configuredSerialTxBufferSize),
                  static_cast<unsigned>(kSerialTxBufferSize));
  }
#elif FIRMWARE_DIAGNOSTICS &&                                               \
    (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206))
  if (configuredSerialTxBufferSize != kSerialTxBufferSize) {
    Serial.printf("BOOT_DIAGNOSTICS_ERROR schema=1 operation=serial_buffer "
                  "configured=%u required=%u\n",
                  static_cast<unsigned>(configuredSerialTxBufferSize),
                  static_cast<unsigned>(kSerialTxBufferSize));
  }
#endif
#if FIRMWARE_DIAGNOSTICS
  // Delay before the first structured marker so a post-flash USB CDC monitor
  // can attach without missing firmware identity or the first boot stage.
  delay(2000);
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::begin();
  if (boot_diagnostics::safeModeActive()) {
    // setup() returns into a deliberately inert loop. No I2C, PMIC, display,
    // storage, speaker, radio, or charging-control initialization is attempted.
    return;
  }
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Startup);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::CoreServices);
#endif
  power_metrics::begin();
  power.begin();
  power_management::begin();
  // Arduino setup() and loop() share the same FreeRTOS task. Bind it before
  // enabling BLE, touch, BOOT, audio, or transfer publishers.
  ui_scheduler::bindCurrentTask();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::CoreServices);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::WakeConfiguration);
#endif
#if AUTOMATIC_LIGHT_SLEEP_EXPERIMENT &&                                      \
    (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206))
  power_management::setGpioWakeNotifier(notifyAutomaticLightSleepGpioWake);
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  displayPowerManager.begin();
#endif
  log_i("Starting Setup...");

#ifdef WAVESHARE_AMOLED_175
  // Configure Wire directly below; do not preemptively bit-bang the shared bus.
#endif
#if defined(POWER_SAVE) || defined(WAVESHARE_AMOLED_175) ||                   \
    defined(WAVESHARE_AMOLED_206)
  pinMode(BOARD_BOOT_PIN, INPUT_PULLUP);
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  attachInterrupt(digitalPinToInterrupt(BOARD_BOOT_PIN),
                  latchWaveshareBootScreenCycle, FALLING);
  uint64_t ext1WakeMask = 1ULL << BOARD_BOOT_PIN;
#ifdef WAVESHARE_AMOLED_175
  ext1WakeMask |= 1ULL << TCH_I2C_INT;
#endif
  power_management::configureExt1Wakeup(ext1WakeMask);
  configureTouchWakeInterrupt();
#endif
#ifdef POWER_SAVE
#ifdef ICENAV_BOARD
  gpio_hold_dis(GPIO_NUM_46);
  gpio_hold_dis((gpio_num_t)BOARD_BOOT_PIN);
  gpio_deep_sleep_hold_dis();
#endif
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(
      boot_diagnostics::Stage::WakeConfiguration);
#endif

#ifdef TDECK_ESP32S3
  pinMode(BOARD_POWERON, OUTPUT);
  digitalWrite(BOARD_POWERON, HIGH);
  pinMode(GPIO_NUM_16, INPUT);
  pinMode(SD_CS, OUTPUT);
  pinMode(RADIO_CS_PIN, OUTPUT);
  pinMode(TFT_SPI_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
  digitalWrite(RADIO_CS_PIN, HIGH);
  digitalWrite(TFT_SPI_CS, HIGH);
  pinMode(SPI_MISO, INPUT_PULLUP);
#endif

#ifdef ICENAV_BOARD
  // Initialize SD card CS pin
  pinMode(SD_CS, OUTPUT);
  digitalWrite(SD_CS, HIGH);
#endif

#ifdef WAVESHARE_AMOLED_206
  // Recover the shared bus before PMIC inspection on the 2.06-inch board.
  // PMIC inspection may set only the established display-enable bit for
  // compatibility with older images; every other output bit remains intact.
  boot_diagnostics::enterStage(boot_diagnostics::Stage::I2cBus);
  waveshare_board::recoverI2CBus();
  waveshare_board::i2c::configureBus();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::I2cBus);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::PmicInspection);
  waveshare_board::initializePowerManagement();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::PmicInspection);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Display);
  initTFT();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Display);
#ifdef WAVESHARE_DISPLAY_PROBE
  boot_diagnostics::markDiagnosticHold();
  Serial.println("Waveshare 2.06 display probe complete; holding before RTC/IMU/SD/LVGL/BLE/touch init");
  while (true) {
    delay(1000);
  }
#endif
#endif

#if defined(WAVESHARE_AMOLED_175)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::I2cBus);
  waveshare_board::i2c::configureBus();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::I2cBus);
#elif !defined(WAVESHARE_AMOLED_206)
  Wire.setPins(I2C_SDA_PIN, I2C_SCL_PIN);
  Wire.begin();
#endif

#if defined(WAVESHARE_AMOLED_175)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::PmicInspection);
  waveshare_board::initializePowerManagement();
  boot_diagnostics::completeStage(boot_diagnostics::Stage::PmicInspection);
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::ClockAndSensors);
#ifdef WAVESHARE_DISPLAY_PROBE
  Serial.println("Waveshare display probe: skipping RTC and IMU init");
#else
  waveshare_board::rtc::restoreSystemTimeFromRtc();
#if defined(WAVESHARE_IMU_DIAGNOSTICS) || defined(RIDE_AUTOMATION_SHADOW)
  waveshare_board::imu::begin();
#else
  waveshare_board::imu::disable();
#endif
  ride_automation_runtime::beginFirmwareShadow();
#endif
#endif

#ifdef BME280
  initBME();
#endif

#ifdef ENABLE_COMPASS
  compass.init();
#endif

#ifdef ENABLE_IMU
  initIMU();
#endif

  battery.initADC();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(
      boot_diagnostics::Stage::ClockAndSensors);
#endif

  // IMPORTANT: Initialize TFT BEFORE SD card!
  // The QSPI display init can disrupt SPI bus settings.
  // By initializing display first, the SPI buses are settled
  // before we configure the SD card.
#ifndef WAVESHARE_AMOLED_206
#if defined(WAVESHARE_AMOLED_175)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Display);
#endif
  initTFT();
#if defined(WAVESHARE_AMOLED_175)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Display);
#endif

#ifdef WAVESHARE_DISPLAY_PROBE
  boot_diagnostics::markDiagnosticHold();
  Serial.println("Waveshare display probe complete; holding before SD/LVGL/BLE/touch init");
  while (true) {
    delay(1000);
  }
#endif
#endif

  // Now initialize SD card after display is fully configured
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Storage);
#endif
  esp_err_t sdResult = storage.initSD();
  if (sdResult != ESP_OK) {
    // SD card failed - fall back to internal FFat storage
    Serial.println("SD Card failed, falling back to FFat...");
    storage.initSPIFFS();
  }
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Storage);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::MapRecovery);
#endif

  {
    map_transfer::MapTransferInstaller mapInstaller("/sdcard");
    map_transfer::InstallStatus recoveryStatus =
        mapInstaller.recoverInterruptedActivation();
    if (!recoveryStatus.ok) {
      Serial.printf("MAP_TRANSFER: recovery failed code=%s message=%s\n",
                    recoveryStatus.code.c_str(), recoveryStatus.message.c_str());
    } else if (recoveryStatus.code != "ok") {
      Serial.printf("MAP_TRANSFER: %s\n", recoveryStatus.message.c_str());
    }
    map_transfer::ActiveMapSelection activeMap;
    map_transfer::InstallStatus activeStatus =
        mapInstaller.readActiveMap(activeMap);
    if (activeStatus.ok) {
      const auto loadSelection =
          [&](const map_transfer::ActiveMapSelection &selection) {
            const std::string root = std::string("/sdcard") + selection.root;
            return mapView.probeVectorMapFolder(root) &&
                   mapView.setVectorMapFolder(root);
          };
      if (loadSelection(activeMap)) {
        Serial.printf("MAP_TRANSFER: activeMapId=%s root=%s\n",
                      activeMap.mapId.c_str(), activeMap.root.c_str());
      } else if (!activeMap.sessionId.empty()) {
        const map_transfer::InstallStatus rollback =
            mapInstaller.rollbackActiveMap(activeMap.sessionId);
        map_transfer::ActiveMapSelection restored;
        const map_transfer::InstallStatus restoredStatus =
            mapInstaller.readActiveMap(restored);
        const bool restoredLoaded =
            rollback.ok && restoredStatus.ok && loadSelection(restored);
        Serial.printf("MAP_TRANSFER: boot renderer probe failed session=%s "
                      "rollback=%s restored=%d\n",
                      activeMap.sessionId.c_str(), rollback.code.c_str(),
                      restoredLoaded);
      } else {
        Serial.printf("MAP_TRANSFER: legacy renderer probe failed root=%s\n",
                      activeMap.root.c_str());
      }
    } else {
      Serial.printf("MAP_TRANSFER: activeMap unavailable code=%s message=%s\n",
                    activeStatus.code.c_str(), activeStatus.message.c_str());
    }
  }
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::MapRecovery);
  boot_diagnostics::enterStage(
      boot_diagnostics::Stage::ApplicationServices);
#endif
  deviceTransferHttp.configure(8080, "BikeComputer-Transfer");
  mapTransferHttp.configure("/sdcard", 8080, &deviceTransferHttp);
  mapTransferHttp.setStreamStorageProbe(
      [] { return storage.getSdLoaded(); });
  mapTransferHttp.setStreamStorageAvailable(sdResult == ESP_OK &&
                                            storage.getSdLoaded());
  firmwareUpdateHttp.configure(&deviceTransferHttp);
  deviceDebugHttp.configure(&deviceTransferHttp);

  createGpxFolders();

  mapView.initMap(gui_layout::mapViewportHeight(TFT_HEIGHT), TFT_WIDTH,
                  TFT_HEIGHT);

  loadPreferences();
#ifdef HAS_HARDWARE_GPS
  gps.init();
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(
      boot_diagnostics::Stage::ApplicationServices);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::UserInterface);
#endif
  initLVGL();
  log_i("Checkpoint A: LVGL Init Done");

  // Get init Latitude and Longitude
  gps.gpsData.latitude = gps.getLat();
  gps.gpsData.longitude = gps.getLon();
  log_i("Checkpoint B: Position Data Initialized");

#ifdef HAS_HARDWARE_GPS
  initGpsTask();
  log_i("Checkpoint C: GPS Task Init Done");
#endif

#ifndef DISABLE_CLI
  initCLI();
  log_i("Checkpoint D: CLI Init Done");
  initCLITask();
  log_i("Checkpoint E: CLI Task Init Done");
#endif

#ifndef DISABLE_WEB_SERVER
  if (WiFi.status() == WL_CONNECTED) {
    if (!MDNS.begin(hostname))
      log_e("nDNS init error");

    log_i("mDNS initialized");
  }
#endif

#ifndef DISABLE_WEB_SERVER
  if (WiFi.status() == WL_CONNECTED && enableWeb) {
    configureWebServer();
    server.begin();
  }
#endif

  if (WiFi.getMode() == WIFI_OFF)
    ESP_ERROR_CHECK(esp_event_loop_create_default());

  log_i("Loading Splash Screen...");
  splashScreen();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::UserInterface);
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Speaker);
  waveshare_board::speaker::begin();
  if (!waveshare_board::axp2101::setPowerButtonEventMonitoring(true)) {
    Serial.println("AXP2101: PWR button-event monitoring unavailable");
  }
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Speaker);
#endif

  // Initialize BLE early so device is discoverable while showing waiting screen
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Ble);
#endif
  bleNavServer.init("BikeComputer");
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Ble);
  boot_diagnostics::enterStage(boot_diagnostics::Stage::Finalization);
#endif

  // Set default coordinates as fallback (will be overwritten by BLE GPS)
#if defined(DEFAULT_LAT) && defined(DEFAULT_LON)
  gps.gpsData.latitude = DEFAULT_LAT;
  gps.gpsData.longitude = DEFAULT_LON;
  gps.gpsData.satellites = 0;
  gps.gpsData.fixMode = 0;
  log_i("Default map center set while waiting for app GPS");
#endif

  // Show waiting screen - will transition to map when GPS is received via BLE
  log_i("Loading Waiting Screen...");
  lv_screen_load(waitingScreen);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  displayInactivityPolicy.begin(millis());
#endif

  log_i("Setup Complete");
  firmwareUpdateHttp.markRunningAppValid();
  mapTransferHttp.resumePendingActivations();
  power_management::completeStartup();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  boot_diagnostics::completeStage(boot_diagnostics::Stage::Finalization);
  boot_diagnostics::markReady();
#endif
}

/**
 * @brief Main Loop
 *
 */
void loop() {
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  if (boot_diagnostics::safeModeActive()) {
    delay(1000);
    return;
  }
#endif
  uint32_t now = millis();
  const uint32_t wakeReasons =
      pendingUiWakeReasons | ui_scheduler::wait(0);
  pendingUiWakeReasons = 0;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  if (ui_scheduler::hasReason(wakeReasons,
                              ui_scheduler::WakeReason::RemoteDebug)) {
    displayInactivityPolicy.noteMeaningfulActivity(now);
  }
#endif
#if BLE_RADIO_CHARACTERIZATION
  if (ui_scheduler::hasReason(wakeReasons,
                              ui_scheduler::WakeReason::Touch) ||
      ui_scheduler::hasReason(wakeReasons, ui_scheduler::WakeReason::Boot)) {
    bleNavServer.noteUserWake();
  }
#endif
  power_metrics::noteLoop(now);
#if FIRMWARE_DIAGNOSTICS
  uint32_t rendererLoopGapMs = 0;
#endif
  if (lastLoopMs != 0) {
    uint32_t gap = now - lastLoopMs;
#if FIRMWARE_DIAGNOSTICS
    rendererLoopGapMs = gap;
#endif
    if (gap > maxLoopGapMs) {
      maxLoopGapMs = gap;
    }
  }
#if FIRMWARE_DIAGNOSTICS
  renderer_diagnostics::noteLoop(now, rendererLoopGapMs);
#endif
  lastLoopMs = now;
  loopCount++;

#if DEVICE_REMOTE_DEBUG
  device_debug::RendererRunRequest rendererRunRequest;
  if (deviceDebugHttp.takeRendererRunRequest(rendererRunRequest)) {
    const device_transfer::HttpTransferStatus rendererTransferStatus =
        deviceTransferHttp.status();
    if (rendererTransferStatus.enabled &&
        rendererTransferStatus.mode == "debug" &&
        rendererRequestMatchesActiveMap(rendererRunRequest.identity)) {
      const renderer_diagnostics::JobCounters currentJobs =
          mapView.rendererDiagnosticsJobCounters();
      const uint32_t currentGpsPacketSequence =
          bleNavServer.getDebugStats().gpsPacketCount;
      if (!renderer_diagnostics::beginWindow(
              rendererRunRequest.requestId, rendererRunRequest.identity,
              rendererRunRequest.profile, now, currentJobs,
              currentGpsPacketSequence)) {
        Serial.println(
            "RENDERER_DIAGNOSTICS: rejected inactive remote-debug window");
      } else {
        mapView.setRendererTuningProfile(rendererRunRequest.profile, now);
        device_debug::frameStore().requestNextFrame();
        if (lv_screen_active() != nullptr)
          lv_obj_invalidate(lv_screen_active());
        Serial.printf(
            "RENDERER_DIAGNOSTICS: window=%lu profile=%s repeat=%u\n",
            static_cast<unsigned long>(rendererRunRequest.requestId),
            renderer_tuning::name(rendererRunRequest.profile),
            static_cast<unsigned>(rendererRunRequest.identity.repeat));
      }
    }
  }
#endif

  constexpr uint32_t kStaticHousekeepingPeriodMs =
      ui_scheduler::kStaticMaximumWaitMs;
  const bool transferHousekeepingDue =
      ui_scheduler::shouldRunForReason(
          wakeReasons, ui_scheduler::WakeReason::Transfer, now,
          lastTransferHousekeepingMs, kStaticHousekeepingPeriodMs);
  if (transferHousekeepingDue) {
    lastTransferHousekeepingMs = now;
    Maps::VectorMapActivationResult rendererResult;
    if (mapView.takeVectorMapFolderActivationResult(rendererResult)) {
      const bool matchesPending =
          pendingMapRendererActivation.source !=
              PendingMapRendererActivationSource::None &&
          pendingMapRendererActivation.rendererQueued &&
          rendererResult.folder == pendingMapRendererActivation.rendererRoot;
      const bool loaded = matchesPending && rendererResult.loaded;
      if (pendingMapRendererActivation.source ==
          PendingMapRendererActivationSource::Transfer) {
        mapTransferHttp.acknowledgeActivatedMapRoot(
            pendingMapRendererActivation.transferRoot, loaded);
      } else if (pendingMapRendererActivation.source ==
                 PendingMapRendererActivationSource::LabelRollback) {
        Serial.printf("MAP_TRANSFER: runtime label failure=%s rollback=%s "
                      "restored=%d\n",
                      pendingMapRendererActivation.labelFailure.c_str(),
                      pendingMapRendererActivation.rollbackCode.c_str(),
                      loaded);
      } else {
        Serial.printf("MAP_TRANSFER: unexpected renderer activation result "
                      "root=%s loaded=%d\n",
                      rendererResult.folder.c_str(), rendererResult.loaded);
      }
      pendingMapRendererActivation = {};
    }

    if (pendingMapRendererActivation.source ==
        PendingMapRendererActivationSource::None) {
      std::string activatedMapRoot;
      if (mapTransferHttp.takeActivatedMapRoot(activatedMapRoot)) {
        const std::string rendererRoot =
            std::string("/sdcard") + activatedMapRoot;
        pendingMapRendererActivation = {
            PendingMapRendererActivationSource::Transfer, rendererRoot,
            activatedMapRoot, {}, {}, false, now};
      }
    }

    std::string labelRuntimeFailure;
    if (pendingMapRendererActivation.source ==
            PendingMapRendererActivationSource::None &&
        mapView.takeStreetLabelRuntimeFailure(labelRuntimeFailure)) {
      map_transfer::MapTransferInstaller mapInstaller("/sdcard");
      map_transfer::ActiveMapSelection failedSelection;
      const map_transfer::InstallStatus activeStatus =
          mapInstaller.readActiveMap(failedSelection);
      map_transfer::InstallStatus rollbackStatus{
          false, "active_rollback_unavailable", "active map is unavailable"};
      bool restorationAvailable = false;
      std::string restoredRoot;
      if (activeStatus.ok && !failedSelection.sessionId.empty()) {
        rollbackStatus =
            mapInstaller.rollbackActiveMap(failedSelection.sessionId);
        map_transfer::ActiveMapSelection restored;
        if (rollbackStatus.ok && mapInstaller.readActiveMap(restored).ok) {
          restoredRoot = std::string("/sdcard") + restored.root;
          restorationAvailable = true;
          pendingMapRendererActivation = {
              PendingMapRendererActivationSource::LabelRollback,
              restoredRoot, {}, labelRuntimeFailure, rollbackStatus.code,
              false, now};
        }
      }
      if (!restorationAvailable) {
        Serial.printf("MAP_TRANSFER: runtime label failure=%s rollback=%s "
                      "restored=0\n",
                      labelRuntimeFailure.c_str(), rollbackStatus.code.c_str());
      }
    }

    // A worker restart handoff or a briefly-held render mutex can make the
    // non-blocking enqueue fail. Keep ownership of the activation and retry on
    // subsequent transfer ticks; a transient 5 ms miss must not falsely mark a
    // successfully installed map as unusable.
    if (pendingMapRendererActivation.source !=
            PendingMapRendererActivationSource::None &&
        !pendingMapRendererActivation.rendererQueued) {
      if (mapView.requestVectorMapFolderActivation(
              pendingMapRendererActivation.rendererRoot)) {
        pendingMapRendererActivation.rendererQueued = true;
      } else if (static_cast<uint32_t>(
                     now - pendingMapRendererActivation.queueAttemptStartedMs) >=
                 kMapRendererActivationQueueTimeoutMs) {
        if (pendingMapRendererActivation.source ==
            PendingMapRendererActivationSource::Transfer) {
          mapTransferHttp.acknowledgeActivatedMapRoot(
              pendingMapRendererActivation.transferRoot, false);
        } else {
          Serial.printf("MAP_TRANSFER: runtime label failure=%s rollback=%s "
                        "restored=0 queue_timeout=1\n",
                        pendingMapRendererActivation.labelFailure.c_str(),
                        pendingMapRendererActivation.rollbackCode.c_str());
        }
        pendingMapRendererActivation = {};
      }
    }
    if (mapTransferHttp.takeAutomaticExitRequest()) {
      const bool disabled = mapTransferHttp.setEnabled(false);
      Serial.printf("MAP_TRANSFER_HTTP: automatic exit applied disabled=%d\n",
                    disabled);
    }
#if DEVICE_REMOTE_DEBUG
    if (deviceDebugHttp.takeWakeRequest()) {
      device_debug::frameStore().requestNextFrame();
      if (lv_screen_active() != nullptr)
        lv_obj_invalidate(lv_screen_active());
    }
    if (deviceDebugHttp.takeAutomaticExitRequest()) {
      const bool disabled = stopActiveDeviceTransfer();
      Serial.printf("REMOTE_DEBUG_HTTP: automatic exit applied disabled=%d\n",
                    disabled);
    }
    // A slow browser can outlive the synchronous teardown deadline. Reclaim
    // the session as soon as the single HTTP worker has actually stopped.
    if (device_debug::frameStore().active() &&
        deviceTransferHttp.status().mode.empty() &&
        deviceTransferHttp.waitUntilStopped(0)) {
      deviceDebugHttp.cancelSession();
      deviceDebugHttp.finishSessionTeardown();
    }
    if (device_debug::frameStore().uiRefreshDue(now) &&
        displayPowerManager.state() != display_power::State::Off &&
        lv_screen_active() != nullptr) {
      // Frame polling may request a redraw of an active/dimmed panel, but it
      // never records meaningful activity and therefore cannot wake an off
      // display or extend its inactivity policy.
      lv_obj_invalidate(lv_screen_active());
    }
#endif
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    processTransferInactivityTimeout(now);
#endif
    updateMapActivationProgressOverlay();
    deviceTransferHttp.process();
  }

  const BLEDebugStats bleStatsBeforeWork = bleNavServer.getDebugStats();
#if FIRMWARE_DIAGNOSTICS
  renderer_diagnostics::noteGpsPacket(
      bleStatsBeforeWork.gpsPacketCount,
      bleStatsBeforeWork.lastGpsPacketGapMs);
  renderer_diagnostics::notePrediction(
      mapView.debugPredictionGraceActive(),
      mapView.debugPredictionExhausted());
#endif
  const bool navigatingBeforeBleWork =
      bleStatsBeforeWork.connected && bleStatsBeforeWork.authenticated &&
      (routeOverlay.hasRoute() || hasCurrentNavigationData());
  const uint32_t bleHousekeepingPeriodMs =
      navigatingBeforeBleWork
          ? ui_scheduler::kConnectedNavigationMaximumWaitMs
          : ui_scheduler::kStaticMaximumWaitMs;
#if BLE_RADIO_CHARACTERIZATION
  bleNavServer.setNavigationActivity(navigatingBeforeBleWork);
#endif
  if (ui_scheduler::shouldRunForReason(
          wakeReasons, ui_scheduler::WakeReason::Ble, now,
          lastBleHousekeepingMs, bleHousekeepingPeriodMs)) {
    lastBleHousekeepingMs = now;
    bleNavServer.process();
  }

#if FIRMWARE_DIAGNOSTICS
  renderer_diagnostics_ble_protocol::WindowRequest ordinaryWindowRequest;
  if (bleNavServer.takeRendererBenchmarkWindowRequest(
          ordinaryWindowRequest)) {
    if (deviceTransferHttp.status().mode == "debug") {
      Serial.println(
          "RENDERER_DIAGNOSTICS: ordinary BLE window rejected during remote debug");
    } else {
      renderer_diagnostics::RunIdentity identity;
      if (populateOrdinaryRendererIdentity(ordinaryWindowRequest, identity)) {
        if (!ordinaryRendererSessionActive)
          renderer_diagnostics::beginSession(false, now);
        const renderer_tuning::Profile profile =
            static_cast<renderer_tuning::Profile>(
                ordinaryWindowRequest.profile);
        const renderer_diagnostics::JobCounters currentJobs =
            mapView.rendererDiagnosticsJobCounters();
        const uint32_t currentGpsPacketSequence =
            bleNavServer.getDebugStats().gpsPacketCount;
        ordinaryRendererWindowSequence =
            (ordinaryRendererWindowSequence + 1U) & 0x7fffffffU;
        if (ordinaryRendererWindowSequence == 0)
          ordinaryRendererWindowSequence = 1;
        const uint32_t windowId =
            ordinaryRendererWindowSequence | 0x80000000U;
        if (renderer_diagnostics::beginWindow(
                windowId, identity, profile, now, currentJobs,
                currentGpsPacketSequence)) {
          mapView.setRendererTuningProfile(profile, now);
          ordinaryRendererSessionActive = true;
          Serial.printf(
              "RENDERER_DIAGNOSTICS: ordinary window=%lu profile=%s repeat=%u\n",
              static_cast<unsigned long>(windowId),
              renderer_tuning::name(profile),
              static_cast<unsigned>(identity.repeat));
        }
      }
    }
  }
  const BLEDebugStats rendererSessionBleStats = bleNavServer.getDebugStats();
  if (ordinaryRendererSessionActive &&
      (!rendererSessionBleStats.connected ||
       !rendererSessionBleStats.authenticated)) {
    mapView.setRendererTuningProfile(renderer_tuning::Profile::Current, now);
    renderer_diagnostics::endSession(now);
    ordinaryRendererSessionActive = false;
  }
#endif

  if (ui_scheduler::isDue(now, lastShutdownHousekeepingMs,
                          kStaticHousekeepingPeriodMs)) {
    lastShutdownHousekeepingMs = now;
    processDisconnectedShutdown();
  }

  // Process app-provided GPS transitions before any periodic work that can
  // briefly block on display, sensor, BLE, or debug output.
  checkPendingMapTransition();

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  // Sample the screen-cycle button before LVGL can start a synchronous vector
  // redraw. updateMainScreen() also defers while the raw input is active.
  if (processWaveshareBootButton()) {
    displayInactivityPolicy.noteMeaningfulActivity(now);
  }
  if (ui_scheduler::isDue(now, lastPowerButtonHousekeepingMs,
                          kStaticHousekeepingPeriodMs)) {
    lastPowerButtonHousekeepingMs = now;
    if (processWavesharePowerButton()) {
      displayInactivityPolicy.noteMeaningfulActivity(now);
    }
  }
#endif

#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  const display_inactivity::Mode displayModeBeforeUpdate = currentDisplayMode;
#ifdef WAVESHARE_AMOLED_175
  constexpr bool kDecodedTouchPollingRequired = true;
  if (display_inactivity::shouldPollTouchWhileDisplayInactive(
          displayModeBeforeUpdate, kDecodedTouchPollingRequired)) {
    // LVGL is throttled while dimmed and paused while off. Keep only the
    // proven, PM-locked controller reader alive so a decoded frame can restore
    // the UI. Tickless builds may light-sleep between these throttled polls.
    readTouch();
  }
#endif
  bool touchWake = ui_scheduler::hasReason(
      wakeReasons, ui_scheduler::WakeReason::Touch);
#ifdef WAVESHARE_AMOLED_175
  // GPIO21 is only a transient CST9217 hint on the tested board. Preserve its
  // low-level state as a supplemental wake signal; decoded-frame activity from
  // the throttled reader remains authoritative.
  touchWake = display_inactivity::touchWakeRequested(
      currentDisplayMode, touchWake, isTouchWakeSourceActive());
#endif
  bool observedTouchActivity = false;
  const display_inactivity::Update displayUpdate =
      updateDisplayInactivityPolicy(now, touchWake, observedTouchActivity);
  if (display_inactivity::isTouchWakeDisplayMode(displayModeBeforeUpdate) &&
      displayUpdate.current != displayModeBeforeUpdate &&
      observedTouchActivity) {
    // The first contact only restores the display. Releasing it clears this
    // suppression before a subsequent intentional UI gesture.
    suppressPrimaryTouchUntilReleaseForDisplayWake();
  }
  displayPowerManager.applyPendingPanelChange();
  if (displayPowerManager.takeFullRefreshRequired()) {
    lv_obj_invalidate(lv_screen_active());
  }
#endif

  bool runLvglHandler = !waitScreenRefresh;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  constexpr uint32_t kDimmedLvglCadenceMs = 100;
  if (currentDisplayMode == display_inactivity::Mode::DisplayOff) {
    runLvglHandler = false;
  } else if (currentDisplayMode == display_inactivity::Mode::Dimmed &&
             now - lastLvglHandlerMs < kDimmedLvglCadenceMs) {
    runLvglHandler = false;
  }
#endif
  if (runLvglHandler) {
    uint32_t startUs = micros();
    nextLvglDelayMs = lv_timer_handler();
    lastLvglHandlerDurationUs = micros() - startUs;
    power_metrics::noteLvgl(lastLvglHandlerDurationUs);
    if (lastLvglHandlerDurationUs > maxLvglHandlerDurationUs) {
      maxLvglHandlerDurationUs = lastLvglHandlerDurationUs;
    }
    lvglHandlerCount++;
    lastLvglHandlerMs = millis();
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
    armOwnershipPairingAfterRenderedComparison();
#endif
  }

#if (defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)) &&       \
    (defined(WAVESHARE_IMU_DIAGNOSTICS) || defined(RIDE_AUTOMATION_SHADOW))
  waveshare_board::imu::process();
#endif
  ride_automation_runtime::processFirmwareShadow(now);

  logSystemDebugHeartbeat();
  logPowerMetricsReport();

#ifndef DISABLE_WEB_SERVER
  // Deleting recursive directories in webfile server
  if (enableWeb && deleteDir) {
    deleteDir = false;
    if (deleteDirRecursive(deletePath.c_str())) {
      updateList = true;
      eventRefresh.send("refresh", nullptr, millis());
      eventRefresh.send("Folder deleted", "updateStatus", millis());
    }
  }
#endif

  const uint32_t schedulerNow = millis();
  const BLEDebugStats schedulerBleStats = bleNavServer.getDebugStats();
  const bool connectedNavigation =
      schedulerBleStats.connected && schedulerBleStats.authenticated &&
      (routeOverlay.hasRoute() || hasCurrentNavigationData());
  const uint32_t nextBleHousekeepingMs = ui_scheduler::remainingUntil(
      schedulerNow, lastBleHousekeepingMs,
      connectedNavigation
          ? ui_scheduler::kConnectedNavigationMaximumWaitMs
          : ui_scheduler::kStaticMaximumWaitMs);
  uint32_t nextHousekeepingMs = std::min(
      ui_scheduler::remainingUntil(schedulerNow,
                                   lastTransferHousekeepingMs,
                                   kStaticHousekeepingPeriodMs),
      ui_scheduler::remainingUntil(schedulerNow,
                                   lastShutdownHousekeepingMs,
                                   kStaticHousekeepingPeriodMs));
  nextHousekeepingMs = std::min(nextHousekeepingMs, nextBleHousekeepingMs);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  nextHousekeepingMs = std::min(
      nextHousekeepingMs,
      ui_scheduler::remainingUntil(schedulerNow,
                                   lastPowerButtonHousekeepingMs,
                                   kStaticHousekeepingPeriodMs));
#endif

  uint32_t effectiveLvglDelayMs = ui_scheduler::remainingUntil(
      schedulerNow, lastLvglHandlerMs, nextLvglDelayMs);
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  if (currentDisplayMode == display_inactivity::Mode::Dimmed) {
    effectiveLvglDelayMs =
        std::max(effectiveLvglDelayMs,
                 ui_scheduler::remainingUntil(schedulerNow,
                                              lastLvglHandlerMs, 100));
  }
#endif
  ui_scheduler::DeadlineContext deadline;
  deadline.lvglDelayMs = effectiveLvglDelayMs;
  deadline.housekeepingDelayMs = nextHousekeepingMs;
  deadline.connectedNavigation = connectedNavigation;
  deadline.lvglBlocked = waitScreenRefresh;
#if defined(WAVESHARE_AMOLED_175) || defined(WAVESHARE_AMOLED_206)
  deadline.displayOff =
      currentDisplayMode == display_inactivity::Mode::DisplayOff;
#endif
  pendingUiWakeReasons =
      ui_scheduler::wait(ui_scheduler::nextWaitMs(deadline));
}
