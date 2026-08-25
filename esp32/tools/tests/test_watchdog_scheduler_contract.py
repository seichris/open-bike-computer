#!/usr/bin/env python3

import re
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[2]
MAP_SOURCE = (PROJECT_DIR / "lib/maps/src/maps.cpp").read_text(encoding="utf-8")
RIDE_SOURCE = (PROJECT_DIR / "lib/ride_diagnostics/ride_diagnostics.cpp").read_text(
    encoding="utf-8"
)
PLATFORMIO = (PROJECT_DIR / "platformio.ini").read_text(encoding="utf-8")


class WatchdogSchedulerContractTests(unittest.TestCase):
    def test_map_worker_cannot_outrank_watched_idle_task(self):
        creation = re.search(
            r'xTaskCreatePinnedToCoreWithCaps\(\s*renderWorkerTaskThunk,.*?;\n',
            MAP_SOURCE,
            re.DOTALL,
        )
        self.assertIsNotNone(creation)
        self.assertIn("tskIDLE_PRIORITY", creation.group(0))
        self.assertRegex(creation.group(0), r"renderWorkerTaskHandle,\s*0,")

    def test_cpu_heavy_rendering_opens_a_bounded_idle_window(self):
        self.assertIn("kMapRenderIdleReleaseIntervalUs = 10000", MAP_SOURCE)
        checkpoint_start = MAP_SOURCE.index("bool shouldCancelMapRenderWork()")
        checkpoint_end = MAP_SOURCE.index("constexpr uint16_t rgb565FromRgb888")
        checkpoint = MAP_SOURCE[checkpoint_start:checkpoint_end]
        self.assertIn("vTaskDelay(pdMS_TO_TICKS(1));", checkpoint)
        self.assertIn("Role::MapRender", checkpoint)

    def test_pinned_sdk_keeps_idle_zero_as_the_only_twdt_subscriber(self):
        required = (
            "CONFIG_ESP_TASK_WDT_INIT=y",
            "CONFIG_ESP_TASK_WDT_PANIC=y",
            "CONFIG_ESP_TASK_WDT_TIMEOUT_S=5",
            "CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0=y",
            "CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1=n",
        )
        for setting in required:
            self.assertIn(setting, PLATFORMIO)
        self.assertIn("static_assert(configUSE_PREEMPTION == 1", MAP_SOURCE)
        self.assertIn("static_assert(configUSE_TIME_SLICING == 1", MAP_SOURCE)
        self.assertIn("static_assert(configIDLE_SHOULD_YIELD == 0", MAP_SOURCE)

    def test_diagnostics_writer_remains_off_watched_cpu(self):
        creation = re.search(
            r'xTaskCreatePinnedToCore\(writerTask, "ride_diag_writer".*?;\n',
            RIDE_SOURCE,
            re.DOTALL,
        )
        self.assertIsNotNone(creation)
        self.assertRegex(creation.group(0), r",\s*0,\s*&writerTaskHandle,\s*1\);\n")

    def test_attribution_covers_map_and_storage_blocking_phases(self):
        for phase in (
            "Phase::MapBlockPlanning",
            "Phase::MapBlockIo",
            "Phase::MapBlockParse",
            "Phase::MapRaster",
            "Phase::MapActivation",
            "Phase::DiagnosticsWrite",
            "Phase::DiagnosticsFlush",
            "Phase::DiagnosticsRecovery",
        ):
            self.assertIn(phase, MAP_SOURCE + RIDE_SOURCE)


if __name__ == "__main__":
    unittest.main()
