from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
HTTP = (ROOT / "lib/device_debug/device_debug_http.cpp").read_text(
    encoding="utf-8"
)
PANEL = (ROOT / "lib/panel/WAVESHARE_AMOLED_175.cpp").read_text(
    encoding="utf-8"
)
BLE = (ROOT / "lib/ble_navigation/ble_navigation.cpp").read_text(
    encoding="utf-8"
)
INPUT = (ROOT / "lib/device_debug/device_debug_input.cpp").read_text(
    encoding="utf-8"
)
MAIN = (ROOT / "src/main.cpp").read_text(encoding="utf-8")
RENDERER_DIAGNOSTICS = (
    ROOT / "lib/renderer_diagnostics/renderer_diagnostics.cpp"
).read_text(encoding="utf-8")
IOS_TRANSFER_MANAGER = (
    ROOT.parent
    / "ios-app/BikeComputer/BikeComputer/Managers/DeviceTransferManager.swift"
).read_text(encoding="utf-8")
IOS_SETTINGS = (
    ROOT.parent / "ios-app/BikeComputer/BikeComputer/Views/SettingsView.swift"
).read_text(encoding="utf-8")
LV_CONFIG = (ROOT / "lib/lvgl/lv_conf.h").read_text(encoding="utf-8")
LV_CONFIG_TEMPLATE = (ROOT / "tools/lv_conf_template.h").read_text(
    encoding="utf-8"
)


class DeviceDebugHttpContractTests(unittest.TestCase):
    def test_ordinary_builds_compile_only_route_free_debug_stubs(self):
        real_implementation = HTTP.index("#if DEVICE_REMOTE_DEBUG")
        route_registration = HTTP.index(
            'server_->registerHandler("/device-debug/", this)'
        )
        stub_branch = HTTP.rindex("#else")
        self.assertLess(real_implementation, route_registration)
        self.assertLess(route_registration, stub_branch)
        self.assertIn("bool DeviceDebugHttp::takeWakeRequest() { return false; }", HTTP)

    def test_shell_is_mode_gated_but_secret_free(self):
        handler = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleRequest") :
            HTTP.index(
                "bool DeviceDebugHttp::allowShortUnauthenticatedResponseCompletion"
            )
        ]
        mode_gate = handler.index("requireMode(client)")
        shell = handler.index('request.path == "/device-debug/"')
        authorization = handler.index("authorize(request, client)")
        self.assertLess(mode_gate, shell)
        self.assertLess(shell, authorization)

    def test_pointer_rechecks_revocation_after_bounded_body_read(self):
        pointer = HTTP[
            HTTP.index("bool DeviceDebugHttp::handlePointer") :
            HTTP.index("bool DeviceDebugHttp::handleWake")
        ]
        self.assertLess(
            pointer.index("validatePointerEnvelope"),
            pointer.index("readHttpBody"),
        )
        self.assertLess(
            pointer.index("readHttpBody"),
            pointer.index("server_->isRequestAuthorized(request)"),
        )
        self.assertLess(
            pointer.index("server_->isRequestAuthorized(request)"),
            pointer.index(
                "displayPowerManager.state()",
                pointer.index("server_->isRequestAuthorized(request)"),
            ),
        )
        self.assertLess(
            pointer.index("displayPowerManager.state()", pointer.index("readHttpBody")),
            pointer.index("deserializeJson"),
        )

    def test_renderer_metrics_are_authenticated_bounded_and_rate_limited(self):
        handler = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleRequest") :
            HTTP.index(
                "bool DeviceDebugHttp::allowShortUnauthenticatedResponseCompletion"
            )
        ]
        authorization = handler.index("authorize(request, client)")
        metrics_route = handler.index('"/device-debug/v1/metrics"')
        window_route = handler.index('"/device-debug/v1/metrics/window"')
        self.assertLess(authorization, metrics_route)
        self.assertLess(authorization, window_route)

        metrics = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleRendererMetrics") :
            HTTP.index("bool DeviceDebugHttp::handleRendererWindow")
        ]
        self.assertIn("kMetricsResponseMinimumIntervalMs", metrics)
        self.assertIn("metrics_rate_limited", metrics)
        self.assertIn("metrics_memory", metrics)
        self.assertIn("body.empty()", metrics)

        window = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleRendererWindow") :
            HTTP.index("bool DeviceDebugHttp::handleFrame")
        ]
        self.assertIn("kRendererWindowMinimumIntervalMs", window)
        self.assertIn("renderer_window_rate_limited", window)
        self.assertIn("kRendererWindowBodyMaximumBytes", window)
        self.assertLess(
            window.index("readHttpBody"),
            window.index("server_->isRequestAuthorized(request)"),
        )
        self.assertLess(
            window.index("server_->isRequestAuthorized(request)"),
            window.index("xQueueOverwrite"),
        )

    def test_renderer_metrics_expose_non_secret_crypto_resource_counters(self):
        for field in (
            r'\"cryptoCountersScope\":\"window\"',
            r'\"cryptoHeadroomRejections\"',
            r'\"cryptoOperationFailures\"',
        ):
            self.assertIn(field, RENDERER_DIAGNOSTICS)
        self.assertNotIn("sessionToken", RENDERER_DIAGNOSTICS)
        self.assertNotIn("apPassphrase", RENDERER_DIAGNOSTICS)

    def test_renderer_metrics_serialize_without_small_internal_stream_buffers(self):
        self.assertIn("class JsonBuilder", RENDERER_DIAGNOSTICS)
        self.assertIn("body_.reserve(4096);", RENDERER_DIAGNOSTICS)
        self.assertIn("std::to_chars", RENDERER_DIAGNOSTICS)
        self.assertNotIn("std::ostringstream", RENDERER_DIAGNOSTICS)

    def test_checkpoint_frame_floor_skips_stale_pixels_before_transfer(self):
        frame = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleFrame") :
            HTTP.index("bool DeviceDebugHttp::handlePointer")
        ]
        self.assertIn("parseFrameRequestPath", frame)
        self.assertIn("query.hasCapturedAtOrAfter", frame)
        self.assertIn("timestampAtOrAfter", frame)
        stale_check = frame.index("!timestampAtOrAfter")
        release = frame.index("frameStore().releaseSnapshot()", stale_check)
        no_content = frame.index("sendHttpHead(client, 204, 0)", release)
        payload = frame.index("snapshot.payloadBytes", no_content)
        self.assertLess(stale_check, release)
        self.assertLess(release, no_content)
        self.assertLess(no_content, payload)

    def test_renderer_windows_bind_the_active_map_before_profile_change(self):
        active_identity = MAIN[
            MAIN.index("static bool readActiveRendererMap") :
            MAIN.index("void appRemoteDebugPointerActivity")
        ]
        self.assertIn("readActiveMapContentReceipt", active_identity)
        renderer_loop = MAIN[
            MAIN.index("device_debug::RendererRunRequest rendererRunRequest") :
            MAIN.index("constexpr uint32_t kStaticHousekeepingPeriodMs")
        ]
        self.assertLess(
            renderer_loop.index("rendererRequestMatchesActiveMap"),
            renderer_loop.index("beginWindow"),
        )
        self.assertLess(
            renderer_loop.index("beginWindow"),
            renderer_loop.index(
                "setRendererTuningProfile(rendererRunRequest.profile"
            ),
        )
        self.assertIn("rendererTransferStatus.enabled", renderer_loop)
        self.assertIn('rendererTransferStatus.mode == "debug"', renderer_loop)
        self.assertIn(
            "rejected window restored current profile", renderer_loop
        )

    def test_generic_status_exposes_network_selection_without_password(self):
        status = BLE[
            BLE.index("static std::string genericTransferStatusJson") :
            BLE.index("static void notifyMapTransferStatus")
        ]
        for field in (
            '\\"apPassphrase\\"',
            '\\"networkTransport\\"',
            '\\"networkSsid\\"',
            '\\"hotspotFallback\\"',
            '\\"hotspotFallbackReason\\"',
        ):
            self.assertIn(field, status)
        self.assertNotIn("password", status.lower())

    def test_debug_hotspot_uses_ephemeral_wpa2_secret(self):
        transfer = (ROOT / "lib/device_transfer/device_transfer_http.cpp").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "apPassphrase_ = generateSessionToken().substr(0, 24);",
            transfer,
        )
        self.assertIn(
            "WiFi.softAP(apSsid.c_str(), apPassphrase.c_str())", transfer
        )
        self.assertNotIn("WiFi.softAP(apSsid.c_str());", transfer)
        info = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleInfo") :
            HTTP.index("bool DeviceDebugHttp::handleFrame")
        ]
        self.assertNotIn("apPassphrase", info)

    def test_fallback_reasons_are_firmware_owned_and_distinct(self):
        transfer = (ROOT / "lib/device_transfer/device_transfer_http.cpp").read_text(
            encoding="utf-8"
        )
        network_protocol = (
            ROOT / "lib/device_transfer/device_transfer_network_protocol.hpp"
        ).read_text(encoding="utf-8")
        for reason in (
            "ssid_unavailable",
            "authentication_failed",
            "association_timeout",
        ):
            self.assertIn(reason, network_protocol)
        self.assertIn("endpoint_unreachable", transfer)
        self.assertIn('command == "enter|debug|h1|e"', BLE)
        self.assertIn("forceHotspotFallbackAfterEndpointFailure", BLE)
        self.assertNotIn("markDeviceTransferHotspotFallback", IOS_TRANSFER_MANAGER)

    def test_lan_credentials_are_device_only_and_entry_failure_compensates(self):
        self.assertIn(
            "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly",
            IOS_TRANSFER_MANAGER,
        )
        self.assertIn("kSecAttrSynchronizable as String: false", IOS_TRANSFER_MANAGER)
        entry = IOS_TRANSFER_MANAGER[
            IOS_TRANSFER_MANAGER.index("func enterRemoteDebug(") :
            IOS_TRANSFER_MANAGER.index("private func waitForRemoteDebugSession")
        ]
        self.assertIn("if enterWasQueued", entry)
        self.assertIn("try? await exitRemoteDebug", entry)

    def test_hotspot_password_can_be_revealed_without_clipboard_handoff(self):
        self.assertIn('"Show Hotspot Password"', IOS_SETTINGS)
        self.assertIn("if revealsHotspotPassphrase", IOS_SETTINGS)
        revealed = IOS_SETTINGS[
            IOS_SETTINGS.index("if revealsHotspotPassphrase") :
            IOS_SETTINGS.index("Button(action: copyHotspotPassphrase)")
        ]
        self.assertIn("Text(passphrase)", revealed)
        self.assertIn(".textSelection(.enabled)", revealed)
        self.assertIn('title: "Fallback Reason"', IOS_SETTINGS)
        self.assertIn('case "endpoint_unreachable"', IOS_SETTINGS)

    def test_debug_exit_requires_fresh_empty_status(self):
        exit_method = IOS_TRANSFER_MANAGER[
            IOS_TRANSFER_MANAGER.index("func exitRemoteDebug(") :
            IOS_TRANSFER_MANAGER.index("private func joinDeviceNetworkIfNeeded")
        ]
        self.assertIn("deviceTransferStatusRevision != initialRevision", exit_method)
        self.assertIn("deviceTransferMode.isEmpty", exit_method)
        self.assertIn("deviceTransferSessionToken?.isEmpty != false", exit_method)

    def test_disconnect_and_owner_recovery_revoke_debug_sessions(self):
        disconnect = BLE[
            BLE.index("void disconnectActive()") :
            BLE.index("class MyNavCharacteristicCallbacks")
        ]
        owner_reset = BLE[
            BLE.index("bool BLENavigationServer::forgetOwner()") :
            BLE.index("void BLENavigationServer::noteOwnershipDisplayFlushCompleted")
        ]
        self.assertIn("DisableOnBleDisconnect", disconnect)
        self.assertLess(
            disconnect.index("clearAuthenticatedBleSession()"),
            disconnect.index("DisableOnBleDisconnect"),
        )
        self.assertIn("stopActiveDeviceTransfer();", owner_reset)

    def test_debug_transport_does_not_hold_display_on(self):
        policy = MAIN[
            MAIN.index("display_inactivity::Context context;") :
            MAIN.index("displayInactivityPolicy.update")
        ]
        self.assertIn('signals.transferMode != "debug"', policy)

    def test_boot_short_press_is_authenticated_bounded_and_session_scoped(self):
        boot = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleBootPress") :
            HTTP.index("bool DeviceDebugHttp::handleExit")
        ]
        self.assertLess(
            boot.index("server_->isRequestAuthorized(request)"),
            boot.index("bootPressRequested_.request()"),
        )
        self.assertIn("boot_press_pending", boot)
        self.assertIn("bootPressRequested_.clear()", HTTP)

    def test_teardown_clears_late_session_actions_after_worker_stops(self):
        cancel = HTTP[
            HTTP.index("void DeviceDebugHttp::cancelSession()") :
            HTTP.index("void DeviceDebugHttp::finishSessionTeardown()")
        ]
        for action in (
            "pointerInput().cancelSession()",
            "wakeRequested_.store(false",
            "bootPressRequested_.clear()",
            "exitRequested_.store(false",
            "exitResponsePending_.store(false",
        ):
            self.assertIn(action, cancel)

        stop = MAIN[
            MAIN.index("bool stopActiveDeviceTransfer()") :
            MAIN.index("void appRemoteDebugPointerActivity()")
        ]
        worker_stopped = stop.index(
            "const bool stopped = deviceTransferHttp.waitUntilStopped(5500)"
        )
        final_cancel = stop.index("deviceDebugHttp.cancelSession()", worker_stopped)
        finish = stop.index("deviceDebugHttp.finishSessionTeardown()", worker_stopped)
        self.assertLess(worker_stopped, final_cancel)
        self.assertLess(final_cancel, finish)

    def test_remote_boot_uses_existing_waveshare_button_path(self):
        button = MAIN[
            MAIN.index("static bool processWaveshareBootButton") :
            MAIN.index("static bool processWavesharePowerButton")
        ]
        self.assertIn("takeWaveshareBootScreenCycle()", button)
        self.assertIn("deviceDebugHttp.takeBootPressRequest()", button)
        self.assertIn("const bool latchedPress =", button)
        self.assertIn("toggleNavigationScreen();", button)
        self.assertIn("confirmOwnershipPairing();", button)

    def test_shell_security_headers_are_present(self):
        for header in (
            "Cache-Control",
            "Referrer-Policy",
            "X-Content-Type-Options",
            "Content-Security-Policy",
            "frame-ancestors 'none'",
        ):
            self.assertIn(header, HTTP)

    def test_capability_is_macro_and_runtime_gated(self):
        capability = BLE[
            BLE.index("#if DEVICE_REMOTE_DEBUG", BLE.index("featureFlags")) :
            BLE.index("responseSize =", BLE.index("featureFlags"))
        ]
        self.assertIn("deviceDebugHttp.initialized()", capability)
        self.assertIn("REMOTE_DEVICE_DEBUG_FEATURE", capability)

    def test_info_exposes_exact_firmware_identity(self):
        info = HTTP[
            HTTP.index("bool DeviceDebugHttp::handleInfo") :
            HTTP.index("bool DeviceDebugHttp::handleFrame")
        ]
        for identity_field in (
            "firmware_metadata::buildProfile()",
            "firmware_metadata::json()",
            '\\"uptimeMs\\"',
        ):
            self.assertIn(identity_field, info)

    def test_full_frame_readiness_includes_software_rotation_buffer(self):
        readiness = PANEL[
            PANEL.index("bool hasFullScreenRgb565Buffer") :
            PANEL.index("void setupDisplay")
        ]
        self.assertIn("disp_rotation_buf != nullptr", readiness)

    def test_physical_override_survives_pointer_mutex_contention(self):
        sample = INPUT[
            INPUT.index("PointerSample PointerInputRuntime::sample") :
            INPUT.index("PointerCounters PointerInputRuntime::counters")
        ]
        self.assertIn("physicalOverridePending_.store(true", sample)
        self.assertIn("controller_.sample(true, nowMs)", sample)

    def test_amoled_profiles_move_fixed_lvgl_pool_to_psram(self):
        psram_gate = (
            "#if defined(BOARD_HAS_PSRAM) && "
            "(defined(WAVESHARE_AMOLED_175) || "
            "defined(WAVESHARE_AMOLED_206))"
        )
        for config in (LV_CONFIG, LV_CONFIG_TEMPLATE):
            self.assertIn(psram_gate, config)
            self.assertIn(
                "#define LV_MEM_POOL_INCLUDE <esp_heap_caps.h>", config
            )
            self.assertIn(
                "heap_caps_aligned_alloc(16, (size), "
                "MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)",
                config,
            )
            profile_gate = config.index(psram_gate)
            fallback = config.index("#else", profile_gate)
            self.assertIn(
                "#undef LV_MEM_POOL_ALLOC", config[fallback:]
            )


if __name__ == "__main__":
    unittest.main()
