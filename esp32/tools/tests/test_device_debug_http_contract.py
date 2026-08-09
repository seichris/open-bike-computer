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


class DeviceDebugHttpContractTests(unittest.TestCase):
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
            pointer.index("deserializeJson"),
        )

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


if __name__ == "__main__":
    unittest.main()
