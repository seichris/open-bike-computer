from pathlib import Path
import re
import unittest


PAGE = (
    Path(__file__).parents[2]
    / "lib"
    / "device_debug"
    / "device_debug_page.hpp"
).read_text(encoding="utf-8")


class DeviceDebugPageTests(unittest.TestCase):
    def test_page_is_offline_and_secret_free(self):
        self.assertNotRegex(PAGE, r"https?://")
        self.assertNotIn("localStorage", PAGE)
        self.assertNotIn("document.cookie", PAGE)
        self.assertNotIn("console.", PAGE)
        self.assertIn("location.hash.slice(1)", PAGE)
        self.assertIn("history.replaceState", PAGE)
        self.assertIn("location.pathname);", PAGE)
        self.assertIn("X-BikeComputer-Transfer-Token", PAGE)
        self.assertIn("Synthetic pointer:", PAGE)
        self.assertNotIn("Touch test", PAGE)

    def test_page_has_frame_and_input_validation(self):
        for text in (
            "BCF1",
            "crc32(payload)",
            "setPointerCapture",
            "pointercancel",
            "visibilitychange",
            "event.key==='Escape'",
            "requestAnimationFrame",
            "AbortController",
            "pointerChain",
            "canvas.toBlob",
            "capturedAtMs",
            "lastRequestLatencyMs",
            "firmware.gitSha",
            "data.buildProfile",
            "shortGitSha",
            "Stale · retry",
            "/device-debug/v1/info",
            "/device-debug/v1/frame?after=",
        ):
            self.assertIn(text, PAGE)

    def test_no_script_or_style_dependencies(self):
        self.assertIsNone(re.search(r"<(?:script|link)[^>]+src=", PAGE))
        self.assertNotIn("@import", PAGE)


if __name__ == "__main__":
    unittest.main()
