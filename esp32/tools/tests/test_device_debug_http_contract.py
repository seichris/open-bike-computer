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
LV_CONFIG = (ROOT / "lib/lvgl/lv_conf.h").read_text(encoding="utf-8")
LV_CONFIG_TEMPLATE = (ROOT / "tools/lv_conf_template.h").read_text(
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

    def test_debug_profile_moves_fixed_lvgl_pool_to_psram(self):
        for config in (LV_CONFIG, LV_CONFIG_TEMPLATE):
            self.assertIn(
                "#if defined(DEVICE_REMOTE_DEBUG) && DEVICE_REMOTE_DEBUG",
                config,
            )
            self.assertIn(
                "#define LV_MEM_POOL_INCLUDE <esp_heap_caps.h>", config
            )
            self.assertIn(
                "heap_caps_aligned_alloc(16, (size), "
                "MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)",
                config,
            )
            debug_gate = config.index(
                "#if defined(DEVICE_REMOTE_DEBUG) && DEVICE_REMOTE_DEBUG"
            )
            fallback = config.index("#else", debug_gate)
            self.assertIn(
                "#undef LV_MEM_POOL_ALLOC", config[fallback:]
            )


if __name__ == "__main__":
    unittest.main()
