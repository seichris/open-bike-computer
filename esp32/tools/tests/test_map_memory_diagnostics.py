from pathlib import Path
import unittest


ESP32_ROOT = Path(__file__).resolve().parents[2]
MAP_RENDERER_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "maps.cpp"
).read_text(encoding="utf-8")
MAP_PROJECTION_SOURCE = (
    ESP32_ROOT / "lib" / "maps" / "src" / "map_projection.hpp"
).read_text(encoding="utf-8")
PLATFORMIO_SOURCE = (ESP32_ROOT / "platformio.ini").read_text(encoding="utf-8")
DIAGNOSTICS_DOC = (
    ESP32_ROOT.parent / "docs" / "firmware-map-memory-diagnostics.md"
).read_text(encoding="utf-8")


class MapMemoryDiagnosticsTests(unittest.TestCase):
    def test_frame_projection_caches_immutable_trigonometry(self):
        ground_start = MAP_PROJECTION_SOURCE.index("GroundPoint groundForWorld")
        ground_end = MAP_PROJECTION_SOURCE.index(
            "map_transform::WorldPoint worldForGround", ground_start
        )
        ground_body = MAP_PROJECTION_SOURCE[ground_start:ground_end]
        self.assertIn("rotationCosine_", ground_body)
        self.assertIn("rotationSine_", ground_body)
        self.assertIn("worldToScreenScale_", ground_body)
        self.assertNotIn("map_transform::worldToScreen", ground_body)

    def test_variable_frame_scratch_uses_psram(self):
        for declaration in (
            "std::vector<Point32, PsramAllocator<Point32>> requiredOffsets",
            "PsramAllocator<map_projection::GroundPoint>>",
            "std::vector<uint8_t, PsramAllocator<uint8_t>> visited",
            "std::vector<uint8_t, PsramAllocator<uint8_t>> admission",
        ):
            self.assertIn(declaration, MAP_RENDERER_SOURCE)

    def test_structured_memory_snapshot_has_stable_fields(self):
        self.assertIn(
            '"MAPIO: memory phase=%s freeInternalHeap=%u "',
            MAP_RENDERER_SOURCE,
        )
        self.assertIn("kMapMemorySnapshotMinIntervalMs = 250", MAP_RENDERER_SOURCE)
        self.assertIn("static uint32_t lastSnapshotMs[4] = {}", MAP_RENDERER_SOURCE)
        for field in (
            "largestInternalHeap=%u",
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
        self.assertIn(
            "courtyardSnapshots=%u courtyardMaxBytes=%u", MAP_RENDERER_SOURCE
        )
        self.assertIn(
            "freeInternalHeap=%u largestInternalHeap=%u", MAP_RENDERER_SOURCE
        )
        self.assertIn("buildingFailureInternalHeapFree", MAP_RENDERER_SOURCE)
        self.assertIn("buildingFailureInternalHeapLargest", MAP_RENDERER_SOURCE)
        self.assertIn("reason=interrupt fallback=deferred", MAP_RENDERER_SOURCE)

    def test_diagnostic_profiles_enable_the_stream_on_both_boards(self):
        for profile in (
            "WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS",
            "WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS",
        ):
            self.assertIn(f"[env:{profile}]", PLATFORMIO_SOURCE)
            section = PLATFORMIO_SOURCE.split(f"[env:{profile}]", 1)[1].split(
                "\n[", 1
            )[0]
            self.assertIn(
                "board_build.partitions = partitions_remote_debug.csv", section
            )
        self.assertGreaterEqual(
            PLATFORMIO_SOURCE.count("-DWAVESHARE_MAPIO_TIMING_LOG=1"), 2
        )

    def test_documentation_defines_capture_contract(self):
        for term in (
            "WAVESHARE_MAPIO_TIMING_LOG",
            "WAVESHARE_TOUCH_DIAGNOSTICS",
            "WAVESHARE_AMOLED_175_MAPIO_DIAGNOSTICS",
            "WAVESHARE_AMOLED_206_MAPIO_DIAGNOSTICS",
            "largestPsram",
            "courtyardMaxBytes",
            "source-monitor",
        ):
            self.assertIn(term, DIAGNOSTICS_DOC)


if __name__ == "__main__":
    unittest.main()
