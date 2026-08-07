from pathlib import Path
import unittest


ESP32_ROOT = Path(__file__).resolve().parents[2]
MAP_RENDERER_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "maps.cpp"
).read_text(encoding="utf-8")
DIAGNOSTICS_DOC = (
    ESP32_ROOT.parent / "docs" / "firmware-map-memory-diagnostics.md"
).read_text(encoding="utf-8")


class MapMemoryDiagnosticsTests(unittest.TestCase):
    def test_structured_memory_snapshot_has_stable_fields(self):
        self.assertIn('"MAPIO: memory phase=%s freeHeap=%u largestHeap=%u "',
                      MAP_RENDERER_SOURCE)
        for field in (
            "freePsram=%u",
            "largestPsram=%u",
            "psramUsed=%u",
            "psramTotal=%u",
        ):
            self.assertIn(field, MAP_RENDERER_SOURCE)

    def test_snapshots_cover_map_and_canvas_boundaries(self):
        for phase in (
            'logMapMemorySnapshot("block-cache")',
            'logMapMemorySnapshot("canvas-no-map")',
            'logMapMemorySnapshot("canvas-draw")',
            'logMapMemorySnapshot("canvas-draw-empty")',
        ):
            self.assertIn(phase, MAP_RENDERER_SOURCE)

    def test_building_diagnostics_include_temporary_snapshot_and_heap_usage(self):
        self.assertIn("courtyardSnapshots=%u courtyardMaxBytes=%u", MAP_RENDERER_SOURCE)
        self.assertIn("freeHeap=%u largestHeap=%u", MAP_RENDERER_SOURCE)
        self.assertIn("buildingFailureHeapFree", MAP_RENDERER_SOURCE)
        self.assertIn("buildingFailureHeapLargest", MAP_RENDERER_SOURCE)

    def test_documentation_defines_capture_contract(self):
        for term in (
            "WAVESHARE_MAPIO_TIMING_LOG",
            "WAVESHARE_TOUCH_DIAGNOSTICS",
            "largestPsram",
            "courtyardMaxBytes",
            "source-monitor",
        ):
            self.assertIn(term, DIAGNOSTICS_DOC)


if __name__ == "__main__":
    unittest.main()
