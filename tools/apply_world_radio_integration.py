#!/usr/bin/env python3
"""Apply the cross-platform World Radio integration to a branch checkout."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one anchor, found {count}: {old[:100]!r}")
    write(path, text.replace(old, new, 1))


def replace_regex_once(path: str, pattern: str, replacement: str) -> None:
    text = read(path)
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError(f"{path}: regex anchor count {count}: {pattern[:120]!r}")
    write(path, updated)


def insert_after_all(path: str, anchor: str, insertion: str) -> None:
    text = read(path)
    if insertion.strip() in text:
        return
    count = text.count(anchor)
    if count == 0:
        raise RuntimeError(f"{path}: missing repeated anchor {anchor!r}")
    write(path, text.replace(anchor, anchor + insertion))


def patch_contract() -> None:
    path = ROOT / "protocol/ride-ble-contract-v1.json"
    contract = json.loads(path.read_text(encoding="utf-8"))
    contract["capabilities"]["current_client_version"] = 21
    contract["capabilities"]["features"]["world_radio"] = {
        "bit": 23,
        "minimum_client_version": 21,
    }
    contract["device_requests"]["world_radio_request_magic"] = "WRQ1"
    contract["device_requests"]["world_radio_status_magic"] = "WRS1"
    path.write_text(json.dumps(contract, indent=2) + "\n", encoding="utf-8")

    replace_once(
        "tools/generate_ride_ble_contract.py",
        """    delivery = contract[\"application_delivery\"]
    for key in (\"command_magic\", \"ack_magic\"):
        if len(delivery[key].encode(\"ascii\")) != 4:
            raise SystemExit(f\"{key} must be exactly four ASCII bytes\")
""",
        """    requests = contract[\"device_requests\"]
    for key, value in requests.items():
        if len(value.encode(\"ascii\")) != 4:
            raise SystemExit(f\"{key} must be exactly four ASCII bytes\")
    delivery = contract[\"application_delivery\"]
    for key in (\"command_magic\", \"ack_magic\"):
        if len(delivery[key].encode(\"ascii\")) != 4:
            raise SystemExit(f\"{key} must be exactly four ASCII bytes\")
""",
    )
    replace_once(
        "tools/generate_ride_ble_contract.py",
        """            f'    static let workoutStartRequestMagic = \"{requests[\"workout_start_magic\"]}\"',
            f'    static let destinationRequestMagic = \"{requests[\"destination_magic\"]}\"',
            f'    static let applicationCommandMagic = \"{delivery[\"command_magic\"]}\"',
""",
        """            f'    static let workoutStartRequestMagic = \"{requests[\"workout_start_magic\"]}\"',
            f'    static let destinationRequestMagic = \"{requests[\"destination_magic\"]}\"',
            f'    static let worldRadioRequestMagic = \"{requests[\"world_radio_request_magic\"]}\"',
            f'    static let worldRadioStatusMagic = \"{requests[\"world_radio_status_magic\"]}\"',
            f'    static let applicationCommandMagic = \"{delivery[\"command_magic\"]}\"',
""",
    )
    replace_once(
        "tools/generate_ride_ble_contract.py",
        """    lines.extend(
        [
            f'inline constexpr char APPLICATION_COMMAND_MAGIC[] = \"{delivery[\"command_magic\"]}\";',
""",
        """    requests = contract[\"device_requests\"]
    lines.extend(
        [
            f'inline constexpr char WORKOUT_START_REQUEST_MAGIC[] = \"{requests[\"workout_start_magic\"]}\";',
            f'inline constexpr char DESTINATION_REQUEST_MAGIC[] = \"{requests[\"destination_magic\"]}\";',
            f'inline constexpr char WORLD_RADIO_REQUEST_MAGIC[] = \"{requests[\"world_radio_request_magic\"]}\";',
            f'inline constexpr char WORLD_RADIO_STATUS_MAGIC[] = \"{requests[\"world_radio_status_magic\"]}\";',
            f'inline constexpr char APPLICATION_COMMAND_MAGIC[] = \"{delivery[\"command_magic\"]}\";',
""",
    )


def patch_device_screen_contract() -> None:
    write(
        "esp32/lib/ble_navigation/device_screen_protocol.hpp",
        """#pragma once

#include <cstdint>

namespace device_screen_protocol {

// Bit 7 marks the current protocol. Unmarked values predate extension screens;
// preserve the firmware's current extension selection when those clients send
// their four-screen mask.
constexpr uint8_t CURRENT_MASK_MARKER = 0x80;
constexpr uint8_t BATTERY_STATUS_BIT = 1 << 4;
constexpr uint8_t WORLD_RADIO_BIT = 1 << 5;
constexpr uint8_t EXTENSION_SCREEN_BITS =
    BATTERY_STATUS_BIT | WORLD_RADIO_BIT;
constexpr uint8_t SCREEN_MASK = 0x3F;

inline uint8_t applyCompatibility(uint8_t wireValue,
                                  uint8_t currentMask) {
  const bool currentProtocol = (wireValue & CURRENT_MASK_MARKER) != 0;
  uint8_t requestedMask = wireValue & SCREEN_MASK;
  if (!currentProtocol) {
    requestedMask = static_cast<uint8_t>(
        requestedMask | (currentMask & EXTENSION_SCREEN_BITS));
  }
  return requestedMask;
}

} // namespace device_screen_protocol
""",
    )


def patch_capability_contract() -> None:
    replace_once(
        "esp32/lib/ble_navigation/device_capabilities_protocol.hpp",
        """constexpr uint8_t RIDE_DELIVERY_ACK_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_MINIMUM_CLIENT_VERSION;
constexpr uint8_t CAP2_SCHEMA_VERSION =
""",
        """constexpr uint8_t RIDE_DELIVERY_ACK_CLIENT_VERSION =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_MINIMUM_CLIENT_VERSION;
constexpr uint8_t WORLD_RADIO_CLIENT_VERSION =
    ride_ble_protocol_generated::WORLD_RADIO_MINIMUM_CLIENT_VERSION;
constexpr uint8_t CAP2_SCHEMA_VERSION =
""",
    )
    replace_once(
        "esp32/lib/ble_navigation/device_capabilities_protocol.hpp",
        """constexpr uint32_t RIDE_DELIVERY_ACK_FEATURE =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_FEATURE;
constexpr uint8_t POWER_BUTTON_CONFIG_TLV = 1;
""",
        """constexpr uint32_t RIDE_DELIVERY_ACK_FEATURE =
    ride_ble_protocol_generated::RIDE_DELIVERY_ACK_FEATURE;
constexpr uint32_t WORLD_RADIO_FEATURE =
    ride_ble_protocol_generated::WORLD_RADIO_FEATURE;
constexpr uint8_t POWER_BUTTON_CONFIG_TLV = 1;
""",
    )


def patch_firmware_ble_header() -> None:
    path = "esp32/lib/ble_navigation/ble_navigation.hpp"
    replace_once(
        path,
        '#include "ride_ble_protocol.generated.hpp"\n',
        '#include "ride_ble_protocol.generated.hpp"\n#include "../world_radio/world_radio_protocol.hpp"\n',
    )
    replace_once(
        path,
        """  DEVICE_SCREEN_MAP_PLUS_NAVIGATION = 3,
  DEVICE_SCREEN_BATTERY_STATUS = 4,
};

static constexpr uint8_t DEVICE_SCREEN_SUPPORTED_MASK =
    (1 << DEVICE_SCREEN_MAP) | (1 << DEVICE_SCREEN_NAVIGATION) |
    (1 << DEVICE_SCREEN_RIDE_STATS) | (1 << DEVICE_SCREEN_MAP_PLUS_NAVIGATION) |
    (1 << DEVICE_SCREEN_BATTERY_STATUS);
""",
        """  DEVICE_SCREEN_MAP_PLUS_NAVIGATION = 3,
  DEVICE_SCREEN_BATTERY_STATUS = 4,
  DEVICE_SCREEN_WORLD_RADIO = 5,
};

static constexpr uint8_t DEVICE_SCREEN_SUPPORTED_MASK =
    (1 << DEVICE_SCREEN_MAP) | (1 << DEVICE_SCREEN_NAVIGATION) |
    (1 << DEVICE_SCREEN_RIDE_STATS) | (1 << DEVICE_SCREEN_MAP_PLUS_NAVIGATION) |
    (1 << DEVICE_SCREEN_BATTERY_STATUS) | (1 << DEVICE_SCREEN_WORLD_RADIO);
static constexpr uint8_t DEVICE_SCREEN_DEFAULT_MASK =
    DEVICE_SCREEN_SUPPORTED_MASK & ~(1 << DEVICE_SCREEN_WORLD_RADIO);
""",
    )
    replace_once(
        path,
        """  uint8_t enabledScreensMask =
      DEVICE_SCREEN_SUPPORTED_MASK; // Bits follow DeviceScreenSetting
""",
        """  uint8_t enabledScreensMask =
      DEVICE_SCREEN_DEFAULT_MASK; // Bits follow DeviceScreenSetting
""",
    )
    replace_once(
        path,
        """  bool requestWorkoutStart();
  bool canRequestWorkoutStart() const;
  WorkoutStartRequestPresentation workoutStartRequestPresentation() const;
""",
        """  bool requestWorkoutStart();
  bool canRequestWorkoutStart() const;
  WorkoutStartRequestPresentation workoutStartRequestPresentation() const;
  bool requestWorldRadio(const world_radio_protocol::Request &request);
  bool canRequestWorldRadio() const;
""",
    )


def patch_firmware_ble_source() -> None:
    path = "esp32/lib/ble_navigation/ble_navigation.cpp"
    replace_once(
        path,
        '#include "authenticated_workout_telemetry.hpp"\n',
        '#include "authenticated_workout_telemetry.hpp"\n#include "../world_radio/world_radio_runtime.hpp"\n',
    )
    replace_once(
        path,
        """static std::atomic<bool> bleSessionSupportsRideDiagnostics{false};
static std::atomic<bool> bleSessionSupportsRideDeliveryAck{false};
""",
        """static std::atomic<bool> bleSessionSupportsRideDiagnostics{false};
static std::atomic<bool> bleSessionSupportsRideDeliveryAck{false};
static std::atomic<bool> bleSessionSupportsWorldRadio{false};
""",
    )
    replace_once(
        path,
        """    if (clientVersion >= device_capabilities_protocol::
                             RIDE_DELIVERY_ACK_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::RIDE_DELIVERY_ACK_FEATURE;
    }
    responseSize = device_capabilities_protocol::encodeCap2(
""",
        """    if (clientVersion >= device_capabilities_protocol::
                             RIDE_DELIVERY_ACK_CLIENT_VERSION) {
      featureFlags |=
          device_capabilities_protocol::RIDE_DELIVERY_ACK_FEATURE;
    }
    if (clientVersion >=
        device_capabilities_protocol::WORLD_RADIO_CLIENT_VERSION) {
      featureFlags |= device_capabilities_protocol::WORLD_RADIO_FEATURE;
    }
    responseSize = device_capabilities_protocol::encodeCap2(
""",
    )
    replace_once(
        path,
        """    bleSessionSupportsRideDeliveryAck.store(
        clientVersion >=
            device_capabilities_protocol::RIDE_DELIVERY_ACK_CLIENT_VERSION,
        std::memory_order_release);
    bleSessionSupportsExplicitInvalidGpsHeading.store(
""",
        """    bleSessionSupportsRideDeliveryAck.store(
        clientVersion >=
            device_capabilities_protocol::RIDE_DELIVERY_ACK_CLIENT_VERSION,
        std::memory_order_release);
    bleSessionSupportsWorldRadio.store(
        clientVersion >= device_capabilities_protocol::WORLD_RADIO_CLIENT_VERSION,
        std::memory_order_release);
    bleSessionSupportsExplicitInvalidGpsHeading.store(
""",
    )
    insert_after_all(
        path,
        """    bleSessionSupportsRideDeliveryAck.store(false,
                                             std::memory_order_release);
""",
        """    bleSessionSupportsWorldRadio.store(false,
                                       std::memory_order_release);
    world_radio_runtime::reset();
""",
    )
    replace_once(
        path,
        """    if (handleDestinationPickerPayload(value, "destination picker")) {
""",
        """    if (value.size() >= 4 &&
        std::memcmp(value.data(),
                    ride_ble_protocol_generated::WORLD_RADIO_STATUS_MAGIC,
                    4) == 0) {
      power_metrics::noteBlePacket(power_metrics::BlePacketClass::Control);
      if (!requireAuthenticated("world radio status") ||
          !bleSessionSupportsWorldRadio.load(std::memory_order_acquire)) {
        return;
      }
      if (!world_radio_runtime::ingestStatus(
              reinterpret_cast<const uint8_t *>(value.data()), value.size())) {
        Serial.println("BLE World Radio: rejected malformed or stale status");
      } else {
        ui_scheduler::notify(ui_scheduler::WakeReason::Ble);
      }
      return;
    }

    if (handleDestinationPickerPayload(value, "destination picker")) {
""",
    )
    method_anchor = "BLEDebugStats BLENavigationServer::getDebugStats() const"
    text = read(path)
    if "bool BLENavigationServer::requestWorldRadio(" not in text:
        index = text.find(method_anchor)
        if index < 0:
            raise RuntimeError(f"{path}: missing method insertion anchor")
        methods = """bool BLENavigationServer::canRequestWorldRadio() const {
  return connected && bleSessionAuthenticated && pNavCharacteristic != nullptr &&
         bleSessionSupportsWorldRadio.load(std::memory_order_acquire);
}

bool BLENavigationServer::requestWorldRadio(
    const world_radio_protocol::Request &request) {
  if (!canRequestWorldRadio()) {
    return false;
  }
  uint8_t payload[world_radio_protocol::REQUEST_BYTES]{};
  if (!world_radio_protocol::encodeRequest(request, payload, sizeof(payload))) {
    return false;
  }
  return notifyAuthenticatedNavigation(pNavCharacteristic, payload,
                                       sizeof(payload));
}

"""
        write(path, text[:index] + methods + text[index:])


def patch_main_screen_header() -> None:
    path = "esp32/lib/gui/src/mainScr.hpp"
    replace_once(path, '#include "maps.hpp"\n', '#include "maps.hpp"\n#include "mainScreenTypes.hpp"\n')
    replace_regex_once(
        path,
        r"\nenum tileName \{.*?\n\};\n",
        "\n",
    )
    replace_once(
        path,
        """extern lv_obj_t *batteryStatusTile;
extern lv_obj_t *mapTile;
""",
        """extern lv_obj_t *batteryStatusTile;
extern lv_obj_t *worldRadioTile;
extern lv_obj_t *mapTile;
""",
    )


def patch_main_screen_source() -> None:
    path = "esp32/lib/gui/src/mainScr.cpp"
    replace_once(
        path,
        '#include "mainScr.hpp"\n',
        '#include "mainScr.hpp"\n#include "mainScreenRegistry.hpp"\n#include "worldRadioScr.hpp"\n',
    )
    replace_once(
        path,
        """lv_obj_t *rideStatsTile;
lv_obj_t *batteryStatusTile;
lv_obj_t *mapTile;
""",
        """lv_obj_t *rideStatsTile;
lv_obj_t *batteryStatusTile;
lv_obj_t *worldRadioTile;
lv_obj_t *mapTile;
""",
    )
    replace_regex_once(
        path,
        r"static bool isMapBackedTile\(uint8_t tile\) \{.*?static bool nextEnabledMapBackedTile\(tileName current, tileName &next\) \{.*?\n\}\n",
        """static bool isMapBackedTile(uint8_t tile) {
  return main_screen_registry::isMapBacked(static_cast<tileName>(tile));
}

static uint8_t normalizedEnabledScreensMask() {
  return main_screen_registry::normalizedMask(
      mapRenderSettings.enabledScreensMask);
}

static uint8_t deviceScreenBit(uint8_t screen) {
  return screen <= DEVICE_SCREEN_WORLD_RADIO
             ? static_cast<uint8_t>(1U << screen)
             : 0;
}

static tileName tileForDeviceScreen(uint8_t screen) {
  return main_screen_registry::tileForDeviceScreen(screen);
}

static uint8_t deviceScreenForTile(tileName tile) {
  return main_screen_registry::deviceScreenForTile(tile);
}

static bool isScreenEnabled(tileName tile) {
  return main_screen_registry::isEnabled(tile,
                                         normalizedEnabledScreensMask());
}

static uint8_t normalizedDefaultDeviceScreen() {
  return main_screen_registry::normalizedDefault(
      mapRenderSettings.defaultScreen, normalizedEnabledScreensMask());
}

static tileName configuredDefaultTile() {
  return tileForDeviceScreen(normalizedDefaultDeviceScreen());
}

static tileName nextEnabledTile(tileName current) {
  return main_screen_registry::nextEnabled(current,
                                           normalizedEnabledScreensMask());
}

static bool nextEnabledMapBackedTile(tileName current, tileName &next) {
  return main_screen_registry::nextEnabledMapBacked(
      current, normalizedEnabledScreensMask(), next);
}
""",
    )
    replace_once(
        path,
        """static bool isGuidanceNavigating() {
""",
        """static_assert(static_cast<uint8_t>(main_screen_registry::DeviceScreenId::Map) ==
                  DEVICE_SCREEN_MAP);
static_assert(static_cast<uint8_t>(main_screen_registry::DeviceScreenId::Navigation) ==
                  DEVICE_SCREEN_NAVIGATION);
static_assert(static_cast<uint8_t>(main_screen_registry::DeviceScreenId::RideStats) ==
                  DEVICE_SCREEN_RIDE_STATS);
static_assert(static_cast<uint8_t>(main_screen_registry::DeviceScreenId::MapPlusNavigation) ==
                  DEVICE_SCREEN_MAP_PLUS_NAVIGATION);
static_assert(static_cast<uint8_t>(main_screen_registry::DeviceScreenId::BatteryStatus) ==
                  DEVICE_SCREEN_BATTERY_STATUS);
static_assert(static_cast<uint8_t>(main_screen_registry::DeviceScreenId::WorldRadio) ==
                  DEVICE_SCREEN_WORLD_RADIO);
static_assert(main_screen_registry::SUPPORTED_MASK ==
                  DEVICE_SCREEN_SUPPORTED_MASK);

static bool isGuidanceNavigating() {
""",
    )
    replace_once(
        path,
        """static void tapCycleScreenEvent(lv_event_t *event);
static void mapGuidanceOverlayTapEvent(lv_event_t *event);
""",
        """static void tapCycleScreenEvent(lv_event_t *event);
static void mapGuidanceOverlayTapEvent(lv_event_t *event);
static bool sendWorldRadioRequest(
    const world_radio_protocol::Request &request) {
  return bleNavServer.requestWorldRadio(request);
}
static void cycleFromWorldRadio() { showNextMainScreen(); }
static bool worldRadioTapCyclesScreens() {
  return mapRenderSettings.tapToSwitchScreens != 0;
}
static bool worldRadioPhoneReady() {
  return bleNavServer.canRequestWorldRadio();
}
""",
    )
    text = read(path)
    text = text.replace(
        "!mapTile || !navTile || !rideStatsTile || !batteryStatusTile",
        "!mapTile || !navTile || !rideStatsTile || !batteryStatusTile || !worldRadioTile",
    )
    text = text.replace(
        "setHiddenIfChanged(batteryStatusTile, true);",
        "setHiddenIfChanged(batteryStatusTile, true);\n    setHiddenIfChanged(worldRadioTile, true);",
    )
    text = text.replace(
        "setHiddenIfChanged(batteryStatusTile, true);\n  setHiddenIfChanged(mapTile, false);",
        "setHiddenIfChanged(batteryStatusTile, true);\n  setHiddenIfChanged(worldRadioTile, true);\n  setHiddenIfChanged(mapTile, false);",
    )
    if "case WORLD_RADIO:" not in text:
        text = text.replace(
            """  case BATTERY_STATUS:
    setHiddenIfChanged(batteryStatusTile, false);
    updateBatteryStatusScr();
    break;
  default:
""",
            """  case BATTERY_STATUS:
    setHiddenIfChanged(batteryStatusTile, false);
    updateBatteryStatusScr();
    break;
  case WORLD_RADIO:
    setHiddenIfChanged(worldRadioTile, false);
    activateWorldRadioScr();
    break;
  default:
""",
            1,
        )
        text = text.replace(
            """  case BATTERY_STATUS:
    updateBatteryStatusScr();
    break;
  default:
""",
            """  case BATTERY_STATUS:
    updateBatteryStatusScr();
    break;
  case WORLD_RADIO:
    updateWorldRadioScr();
    break;
  default:
""",
            1,
        )
    creation_anchor = "  batteryStatusTile = lv_obj_create(mainScreen);"
    if "worldRadioScr(worldRadioTile" not in text:
        index = text.find(creation_anchor)
        if index < 0:
            raise RuntimeError(f"{path}: missing battery tile creation anchor")
        creation = """  worldRadioTile = lv_obj_create(mainScreen);
  lv_obj_remove_style_all(worldRadioTile);
  lv_obj_set_size(worldRadioTile, TFT_WIDTH, TFT_HEIGHT);
  lv_obj_set_pos(worldRadioTile, 0, 0);
  lv_obj_clear_flag(worldRadioTile, LV_OBJ_FLAG_SCROLLABLE);
  WorldRadioScreenCallbacks worldRadioCallbacks{};
  worldRadioCallbacks.sendRequest = sendWorldRadioRequest;
  worldRadioCallbacks.cycleScreen = cycleFromWorldRadio;
  worldRadioCallbacks.tapToSwitchScreens = worldRadioTapCyclesScreens;
  worldRadioCallbacks.phoneReady = worldRadioPhoneReady;
  worldRadioScr(worldRadioTile, worldRadioCallbacks);
  lv_obj_add_flag(worldRadioTile, LV_OBJ_FLAG_HIDDEN);

"""
        text = text[:index] + creation + text[index:]
    write(path, text)


def patch_ios_protocol_and_settings() -> None:
    protocol_path = "ios-app/BikeComputer/BikeComputer/Models/WorldRadioProtocol.swift"
    text = read(protocol_path).replace("private nonisolated extension Data", "private extension Data")
    write(protocol_path, text)

    path = "ios-app/BikeComputer/BikeComputer/Managers/BLEManager.swift"
    replace_once(
        path,
        """    static let destinationStatusPrefix = "DNST"
    static let workoutStartRequestPrefix =
""",
        """    static let destinationStatusPrefix = "DNST"
    static let worldRadioRequestPrefix =
        RideBLEGeneratedProtocolV1.worldRadioRequestMagic
    static let worldRadioStatusPrefix =
        RideBLEGeneratedProtocolV1.worldRadioStatusMagic
    static let workoutStartRequestPrefix =
""",
    )
    replace_once(
        path,
        """    static let rideDeliveryAcknowledgementCapabilityMask =
        RideBLEGeneratedProtocolV1.rideDeliveryAckFeature
    static let deviceCapabilitiesVersion =
""",
        """    static let rideDeliveryAcknowledgementCapabilityMask =
        RideBLEGeneratedProtocolV1.rideDeliveryAckFeature
    static let worldRadioCapabilityMask =
        RideBLEGeneratedProtocolV1.worldRadioFeature
    static let deviceCapabilitiesVersion =
""",
    )
    replace_once(
        path,
        """    static let automaticDisplayOffSettingCoalescingKey =
        "automatic-display-off-setting"
""",
        """    static let automaticDisplayOffSettingCoalescingKey =
        "automatic-display-off-setting"
    static let worldRadioStatusCoalescingKey = "world-radio-status"
""",
    )
    replace_once(
        path,
        """    case mapPlusNavigation = 3
    case batteryStatus = 4
""",
        """    case mapPlusNavigation = 3
    case batteryStatus = 4
    case worldRadio = 5
""",
    )
    replace_once(
        path,
        """        case .batteryStatus:
            return "Battery Status"
""",
        """        case .batteryStatus:
            return "Battery Status"
        case .worldRadio:
            return "World Radio"
""",
    )
    replace_once(
        path,
        """    static var legacyScreensMask: Int {
        allScreensMask & ~batteryStatus.bit
    }

    static var displayOrder: [DeviceScreen] {
        [.mapPlusNavigation, .rideStats, .map, .navigation, .batteryStatus]
    }
""",
        """    static var legacyScreensMask: Int {
        allScreensMask & ~(batteryStatus.bit | worldRadio.bit)
    }

    static var displayOrder: [DeviceScreen] {
        [.mapPlusNavigation, .rideStats, .map, .navigation, .worldRadio,
         .batteryStatus]
    }
""",
    )
    replace_once(
        path,
        """    @Published private(set) var supportsRideDeliveryAcknowledgement: Bool = false
""",
        """    @Published private(set) var supportsRideDeliveryAcknowledgement: Bool = false
    @Published private(set) var supportsWorldRadio: Bool = false
""",
    )
    replace_once(
        path,
        """        static let batteryStatusScreenMigrated = "deviceSettings.enabledScreensMask.batteryStatus.v1"
""",
        """        static let batteryStatusScreenMigrated = "deviceSettings.enabledScreensMask.batteryStatus.v1"
        static let worldRadioScreenMigrated = "deviceSettings.enabledScreensMask.worldRadio.v1"
""",
    )
    text = read(path)
    if "var onWorldRadioRequest" not in text:
        match = re.search(r"(^\s*var onDestinationRequest[^\n]*\n(?:\s+[^\n]*\n)*)", text, re.MULTILINE)
        if not match:
            # Closure is normally a single line, but keep a broad fallback.
            match = re.search(r"^\s*var onDestinationRequest.*$", text, re.MULTILINE)
        if not match:
            raise RuntimeError(f"{path}: missing onDestinationRequest property")
        insertion = match.group(0) + "    var onWorldRadioRequest: ((WorldRadioRequest) -> Void)?\n"
        text = text[: match.start()] + insertion + text[match.end() :]
        write(path, text)
    replace_once(
        path,
        """        let hasRideDeliveryAcknowledgement =
            flags & DeviceBLEProtocol
                .rideDeliveryAcknowledgementCapabilityMask != 0
""",
        """        let hasRideDeliveryAcknowledgement =
            flags & DeviceBLEProtocol
                .rideDeliveryAcknowledgementCapabilityMask != 0
        let hasWorldRadio =
            flags & DeviceBLEProtocol.worldRadioCapabilityMask != 0
""",
    )
    replace_once(
        path,
        """        if hasReceivedDeviceCapabilities &&
            supportsBatteryStatusScreen != hasBatteryStatusScreen {
            hasSentScreenSettingsForConnection = false
        }
""",
        """        if hasReceivedDeviceCapabilities &&
            (supportsBatteryStatusScreen != hasBatteryStatusScreen ||
             supportsWorldRadio != hasWorldRadio) {
            hasSentScreenSettingsForConnection = false
        }
""",
    )
    replace_once(
        path,
        """        supportsDetailedRideDiagnostics = hasDetailedRideDiagnostics
        if supportsRideDeliveryAcknowledgement &&
""",
        """        supportsDetailedRideDiagnostics = hasDetailedRideDiagnostics
        supportsWorldRadio = hasWorldRadio
        if supportsRideDeliveryAcknowledgement &&
""",
    )
    replace_once(
        path,
        """        if DeviceWorkoutStartRequest.matches(data) {
""",
        """        if let request = WorldRadioRequest(data) {
            guard isConnected, isNavigationReady, supportsWorldRadio else {
                log("Ignored World Radio request before capability negotiation")
                return true
            }
            log("Received World Radio request command=\\(request.command.rawValue) id=\\(request.requestID)")
            onWorldRadioRequest?(request)
            return true
        }
        if data.starts(with: Data(DeviceBLEProtocol.worldRadioRequestPrefix.utf8)) {
            log("Rejected malformed World Radio request")
            return true
        }
        if DeviceWorkoutStartRequest.matches(data) {
""",
    )
    # Reset negotiated support anywhere the adjacent high-version capability is reset.
    text = read(path)
    text = text.replace(
        "supportsRideDeliveryAcknowledgement = false\n",
        "supportsRideDeliveryAcknowledgement = false\n        supportsWorldRadio = false\n",
    )
    write(path, text)

    # Add a bounded status send next to other navigation fallback sends.
    text = read(path)
    if "func sendWorldRadioStatus(" not in text:
        marker = "    @discardableResult\n    func handleNavigationCharacteristicNotification"
        index = text.find(marker)
        if index < 0:
            raise RuntimeError(f"{path}: missing World Radio status method anchor")
        method = """    @discardableResult
    func sendWorldRadioStatus(_ status: WorldRadioStatus) -> Bool {
        guard supportsWorldRadio, isNavigationReady,
              let payload = status.encoded() else {
            return false
        }
        return sendFallbackMapPacket(
            payload,
            label: "world radio status",
            payloadClass: .settingsControl,
            coalescingKey: DeviceBLEProtocol.worldRadioStatusCoalescingKey,
            prioritized: true,
            atomically: true
        )
    }

"""
        write(path, text[:index] + method + text[index:])

    # Extend the persisted screen-mask migration and support filter using stable anchors.
    text = read(path)
    battery_migration = re.search(
        r"(if !defaults\.bool\(forKey: SettingsKeys\.batteryStatusScreenMigrated\) \{.*?\n\s*\})",
        text,
        re.DOTALL,
    )
    if battery_migration and "worldRadioScreenMigrated" not in text[battery_migration.end() : battery_migration.end() + 700]:
        insertion = battery_migration.group(1) + "\n        if !defaults.bool(forKey: SettingsKeys.worldRadioScreenMigrated) {\n            enabledDeviceScreensMask |= DeviceScreen.worldRadio.bit\n            defaults.set(true, forKey: SettingsKeys.worldRadioScreenMigrated)\n        }"
        text = text[: battery_migration.start()] + insertion + text[battery_migration.end() :]
    # All supported-screen filters already special-case battery; include World Radio with the same negotiation gate.
    text = text.replace(
        "if supportsBatteryStatusScreen {\n            mask |= DeviceScreen.batteryStatus.bit\n        }",
        "if supportsBatteryStatusScreen {\n            mask |= DeviceScreen.batteryStatus.bit\n        }\n        if supportsWorldRadio {\n            mask |= DeviceScreen.worldRadio.bit\n        }",
    )
    text = text.replace(
        "case .rideStats, .navigation, .batteryStatus:",
        "case .rideStats, .navigation, .batteryStatus, .worldRadio:",
    )
    write(path, text)


def patch_ios_coordinator() -> None:
    path = "ios-app/BikeComputer/BikeComputer/Managers/BikeComputerCoordinator.swift"
    replace_once(
        path,
        """    private var workoutDeviceRelay: WorkoutDeviceRelay?
""",
        """    private var workoutDeviceRelay: WorkoutDeviceRelay?
    private lazy var worldRadioService = WorldRadioService { [weak bleManager] status in
        _ = bleManager?.sendWorldRadioStatus(status)
    }
""",
    )
    replace_once(
        path,
        """    private func setupManagerBindings() {
        // Bind BLE manager state
""",
        """    private func setupManagerBindings() {
        bleManager.onWorldRadioRequest = { [weak self] request in
            self?.worldRadioService.handle(request)
        }

        // Bind BLE manager state
""",
    )


def patch_info_plist_and_runner() -> None:
    path = "ios-app/BikeComputer/BikeComputer/Info.plist.template"
    replace_once(
        path,
        """\t<array>
\t\t<string>bluetooth-central</string>
\t\t<string>location</string>
\t</array>
""",
        """\t<array>
\t\t<string>audio</string>
\t\t<string>bluetooth-central</string>
\t\t<string>location</string>
\t</array>
""",
    )
    path = "ios-app/scripts/run-navigation-tests.sh"
    text = read(path)
    compile_anchor = '"$ROOT/BikeComputer/BikeComputer/Managers/BLEManager.swift"'
    if "WorldRadioProtocol.swift" not in text:
        text = text.replace(
            compile_anchor,
            '"$ROOT/BikeComputer/BikeComputer/Models/WorldRadioProtocol.swift" \\\n  "$ROOT/BikeComputer/BikeComputer/Services/WorldRadioService.swift" \\\n  ' + compile_anchor,
            1,
        )
    test_anchor = '"$ROOT/BikeComputerTests/NavigationProtocolTests.swift"'
    if "WorldRadioTests.swift" not in text:
        text = text.replace(
            test_anchor,
            test_anchor + ' \\\n  "$ROOT/BikeComputerTests/WorldRadioTests.swift"',
            1,
        )
    write(path, text)


def write_tests() -> None:
    write(
        "esp32/tools/tests/test_world_radio_protocol.cpp",
        r'''#include "../../lib/world_radio/world_radio_protocol.hpp"

#include <cassert>
#include <cstring>
#include <iostream>

int main() {
  using namespace world_radio_protocol;

  Request request{};
  request.command = Command::SelectLocation;
  request.requestId = 0x12345678;
  request.latitudeE7 = 312304000;
  request.longitudeE7 = 1214737000;
  uint8_t requestBytes[REQUEST_BYTES]{};
  assert(encodeRequest(request, requestBytes, sizeof(requestBytes)));
  assert(std::memcmp(requestBytes, "WRQ1", 4) == 0);
  assert(requestBytes[4] == VERSION);
  Request decodedRequest{};
  assert(decodeRequest(requestBytes, sizeof(requestBytes), decodedRequest));
  assert(decodedRequest.command == request.command);
  assert(decodedRequest.requestId == request.requestId);
  assert(decodedRequest.latitudeE7 == request.latitudeE7);
  assert(decodedRequest.longitudeE7 == request.longitudeE7);
  request.requestId = 0;
  assert(!encodeRequest(request, requestBytes, sizeof(requestBytes)));

  Status status{};
  status.state = PlaybackState::Playing;
  status.favorite = true;
  status.hasStation = true;
  status.stationIndex = 2;
  status.stationCount = 7;
  status.bitrateKbps = 96;
  status.requestId = 0x12345678;
  status.stationLatitudeE7 = 356817000;
  status.stationLongitudeE7 = 1397671000;
  std::memcpy(status.countryCode, "JP", 2);
  std::strcpy(status.stationName, "Tokyo Community Radio");
  std::strcpy(status.place, "Tokyo");
  std::strcpy(status.message, "Playing on iPhone");
  uint8_t statusBytes[STATUS_MAX_BYTES]{};
  std::size_t written = 0;
  assert(encodeStatus(status, statusBytes, sizeof(statusBytes), written));
  assert(written > STATUS_HEADER_BYTES);
  Status decodedStatus{};
  assert(decodeStatus(statusBytes, written, decodedStatus));
  assert(decodedStatus.state == PlaybackState::Playing);
  assert(decodedStatus.favorite);
  assert(decodedStatus.hasStation);
  assert(decodedStatus.requestId == status.requestId);
  assert(std::strcmp(decodedStatus.stationName, status.stationName) == 0);
  assert(std::strcmp(decodedStatus.place, status.place) == 0);
  assert(std::strcmp(decodedStatus.message, status.message) == 0);
  statusBytes[31] = 1;
  assert(!decodeStatus(statusBytes, written, decodedStatus));

  std::cout << "world radio protocol tests passed\n";
  return 0;
}
''',
    )
    write(
        "esp32/tools/tests/test_main_screen_registry.cpp",
        r'''#include "../../lib/gui/src/mainScreenRegistry.hpp"

#include <cassert>
#include <iostream>

int main() {
  using namespace main_screen_registry;

  static_assert(SUPPORTED_MASK == 0x3F);
  static_assert(deviceScreenForTile(WORLD_RADIO) == 5);
  static_assert(tileForDeviceScreen(5) == WORLD_RADIO);
  static_assert(isMapBacked(MAP));
  static_assert(isMapBacked(MAP_GUIDANCE));
  static_assert(!isMapBacked(WORLD_RADIO));

  assert(nextEnabled(NAV, SUPPORTED_MASK) == WORLD_RADIO);
  assert(nextEnabled(WORLD_RADIO, SUPPORTED_MASK) == BATTERY_STATUS);
  assert(nextEnabled(NAV, static_cast<uint8_t>(SUPPORTED_MASK & ~bit(DeviceScreenId::WorldRadio))) ==
         BATTERY_STATUS);
  tileName next = WORLD_RADIO;
  assert(nextEnabledMapBacked(RIDESTATS, SUPPORTED_MASK, next));
  assert(next == MAP);

  std::cout << "main screen registry tests passed\n";
  return 0;
}
''',
    )
    write(
        "ios-app/BikeComputerTests/WorldRadioTests.swift",
        r'''import Foundation

private final class WorldRadioTestPlayer: WorldRadioAudioPlaying {
    var eventHandler: ((WorldRadioAudioEvent) -> Void)?
    private(set) var played: [WorldRadioStation] = []
    private(set) var pauseCount = 0

    func play(_ station: WorldRadioStation) {
        played.append(station)
        eventHandler?(.playing)
    }

    func pause() {
        pauseCount += 1
        eventHandler?(.paused)
    }

    func resume() {
        eventHandler?(.playing)
    }

    func stop() {}
}

@MainActor
func runWorldRadioTests() async {
    var request = Data("WRQ1".utf8)
    request.append(contentsOf: [1, WorldRadioCommand.selectLocation.rawValue, 0, 0])
    request.append(contentsOf: [0x78, 0x56, 0x34, 0x12])
    request.append(contentsOf: [0x80, 0xFC, 0x9C, 0x12])
    request.append(contentsOf: [0xA8, 0xD9, 0x67, 0x48])
    let decoded = WorldRadioRequest(request)
    precondition(decoded?.requestID == 0x12345678)
    precondition(decoded?.latitudeE7 == 312_304_000)
    precondition(decoded?.longitudeE7 == 1_214_737_000)

    let station = WorldRadioStation(
        uuid: "12345678-1234-1234-1234-123456789abc",
        name: "Tokyo Community Radio",
        place: "Tokyo",
        countryCode: "JP",
        latitudeE7: 356_817_000,
        longitudeE7: 1_397_671_000,
        bitrateKbps: 96,
        streamURL: URL(string: "https://example.com/live.mp3")!,
        clickCount: 100,
        distanceMeters: 2500
    )
    let status = WorldRadioStatus(
        state: .playing,
        stationIndex: 0,
        stationCount: 1,
        requestID: 0x12345678,
        station: station,
        message: "Playing on iPhone"
    )
    let encoded = status.encoded()
    precondition(encoded?.starts(with: Data("WRS1".utf8)) == true)
    precondition(encoded?.count ?? 0 <= WorldRadioStatus.maximumBytes)

    let directory = WorldRadioDirectoryClient(
        nearby: { _, _ in [station] },
        random: { [station] },
        recordClick: { _ in }
    )
    let player = WorldRadioTestPlayer()
    var statuses: [WorldRadioStatus] = []
    let service = WorldRadioService(
        directory: directory,
        player: player,
        statusSink: { statuses.append($0) }
    )
    guard let serviceRequest = decoded else {
        preconditionFailure("request did not decode")
    }
    service.handle(serviceRequest)
    await Task.yield()
    await Task.yield()
    precondition(statuses.first?.state == .searching)
    precondition(statuses.last?.state == .playing)
    precondition(player.played == [station])

    service.handle(WorldRadioRequest.makeForTesting(
        command: .playPause,
        requestID: 0x12345679
    ))
    precondition(player.pauseCount == 1)
}

private extension WorldRadioRequest {
    static func makeForTesting(
        command: WorldRadioCommand,
        requestID: UInt32
    ) -> WorldRadioRequest {
        var data = Data("WRQ1".utf8)
        data.append(contentsOf: [1, command.rawValue, 0, 0])
        data.append(contentsOf: [
            UInt8(truncatingIfNeeded: requestID),
            UInt8(truncatingIfNeeded: requestID >> 8),
            UInt8(truncatingIfNeeded: requestID >> 16),
            UInt8(truncatingIfNeeded: requestID >> 24),
        ])
        data.append(Data(repeating: 0, count: 8))
        return WorldRadioRequest(data)!
    }
}
''',
    )
    # Invoke async tests from the existing host-test main.
    path = "ios-app/BikeComputerTests/NavigationProtocolTests.swift"
    text = read(path)
    if "runWorldRadioTests()" not in text:
        main_match = re.search(r"(@main\s+struct\s+\w+\s*\{\s*static func main\(\)\s*(?:async\s*)?\{)", text)
        if not main_match:
            raise RuntimeError(f"{path}: missing host-test main")
        declaration = main_match.group(1)
        if "async" not in declaration:
            updated = declaration.replace("static func main()", "static func main() async")
            text = text[: main_match.start()] + updated + text[main_match.end() :]
            main_match = re.search(r"(@main\s+struct\s+\w+\s*\{\s*static func main\(\)\s+async\s*\{)", text)
        insert_at = main_match.end()
        text = text[:insert_at] + "\n        await runWorldRadioTests()" + text[insert_at:]
        write(path, text)

    # Extend existing low-level tests.
    path = "esp32/tools/tests/test_device_screen_protocol.cpp"
    text = read(path)
    text = text.replace("0x1F", "0x3F")
    write(path, text)

    path = "esp32/tools/tests/test_device_capabilities_protocol.cpp"
    text = read(path)
    if "WORLD_RADIO_CLIENT_VERSION" not in text:
        marker = "  static_assert(\n      device_capabilities_protocol::RIDE_DELIVERY_ACK_CLIENT_VERSION == 20);"
        insertion = marker + "\n  static_assert(device_capabilities_protocol::WORLD_RADIO_CLIENT_VERSION == 21);\n  static_assert(device_capabilities_protocol::WORLD_RADIO_FEATURE ==\n                (1UL << 23));"
        if marker not in text:
            raise RuntimeError(f"{path}: missing capability static assert anchor")
        text = text.replace(marker, insertion, 1)
        write(path, text)


def write_docs() -> None:
    write(
        "docs/world-radio.md",
        """# World Radio

World Radio turns the ESP32-S3 display into a geographic remote for internet
radio. The device renders and manipulates the map; the authenticated iPhone app
performs every network request and plays the stream through the phone's active
audio route. Encoded audio never crosses BLE and the firmware does not enable
Wi-Fi for this feature.

## Flow

1. The rider opens **World Radio** and drags the wrapped, equirectangular map
   under the fixed reticle.
2. Releasing the map sends one fixed-size `WRQ1` coordinate request over the
   existing authenticated navigation characteristic.
3. The iPhone queries Radio Browser with progressively larger radii, filters to
   healthy HTTPS streams, and keeps a bounded candidate queue.
4. `AVPlayer` starts the selected live stream. The phone returns a bounded
   `WRS1` status containing station metadata and playback state.
5. Previous, play/pause, next, stop, and global-random commands remain tiny BLE
   control messages. Audio continues on the iPhone if the device temporarily
   disconnects.

## Privacy and security

- World Radio uses the existing owner-authenticated BLE envelope.
- Station and coordinate requests are sent only to the connected iPhone.
- The device receives no station URL and cannot fetch internet content.
- The iPhone accepts HTTPS station streams only in the first release.
- Radio Browser's click endpoint is called only after playback begins.

## Validation boundary

Host tests cover request/status encoding, screen registry behavior, iPhone
service orchestration, and generated-contract drift. Firmware and iOS builds
prove integration at compile time. Physical acceptance still requires dragging
the map and controlling live playback on both supported Waveshare panels while
an authenticated iPhone is connected.
""",
    )
    write(
        "docs/main-screen-architecture.md",
        """# Main-screen architecture

`mainScr.cpp` historically owned screen IDs, cycle order, settings mappings,
root-object visibility, and each screen's implementation. That made every new
screen a cross-cutting edit and encouraged more globals and switch statements.

World Radio starts an incremental migration rather than a risky rewrite of all
existing screens.

## Registry

`mainScreenRegistry.hpp` is the source of truth for stable device-screen IDs,
cycle order, internal tile mapping, and whether a screen is map-backed. It is a
pure header with host tests, so settings compatibility and cycle behavior can
be validated without LVGL or hardware.

Wire IDs remain separate from internal `tileName` values. Static assertions in
`mainScr.cpp` prevent the registry and BLE contract from drifting.

## Screen modules

A new screen should own its LVGL objects, events, local presentation state, and
create/update/activate entry points in its own `*Scr.cpp` module. The main
screen supplies narrow callbacks for application actions; the module must not
reach into BLE, storage, or network managers directly.

Background work publishes immutable snapshots. Only the LVGL task reads those
snapshots and mutates visible objects. A stable update with no changed revision
must be a no-op.

## Adding the next screen

1. Allocate a stable `DeviceScreenSetting` wire ID and capability when the
   screen depends on a companion-app feature.
2. Add one descriptor to `mainScreenRegistry.hpp`.
3. Implement a self-contained screen module with bounded callbacks.
4. Add the iOS settings case and migration for existing users.
5. Add registry, protocol, and module-state host tests.
6. Validate both Waveshare firmware profiles and the iOS build.

Future PRs can migrate the legacy screens behind the same module interface one
at a time. Once all roots are registered, the remaining `showMainTile` switch
can become descriptor callbacks without changing the stable settings protocol.
""",
    )


def fix_known_new_file_issues() -> None:
    path = "esp32/lib/gui/src/worldRadioScr.cpp"
    text = read(path)
    text = text.replace(
        "constexpr int32_t LONGITUDE_FULL_E7 = 3600000000LL;",
        "constexpr int64_t LONGITUDE_FULL_E7 = 3600000000LL;",
    )
    write(path, text)


def main() -> int:
    patch_contract()
    patch_device_screen_contract()
    patch_capability_contract()
    patch_firmware_ble_header()
    patch_firmware_ble_source()
    patch_main_screen_header()
    patch_main_screen_source()
    patch_ios_protocol_and_settings()
    patch_ios_coordinator()
    patch_info_plist_and_runner()
    write_tests()
    write_docs()
    fix_known_new_file_issues()
    print("World Radio integration patch applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
