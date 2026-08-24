from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
STORAGE = (ROOT / "lib/storage/storage.cpp").read_text(encoding="utf-8")
RECORDER = (ROOT / "lib/ride_diagnostics/ride_diagnostics.cpp").read_text(
    encoding="utf-8"
)


class RideDiagnosticsStorageContractTests(unittest.TestCase):
    def test_alternate_mount_requires_probe_and_tears_down_unhealthy_mount(self):
        self.assertIn("writableProbeSucceeded", STORAGE)
        self.assertIn("storage_mount_policy::diagnosticsMountReady", STORAGE)
        self.assertIn("if (!ready) {\n      SD.end();", STORAGE)
        self.assertIn("diagnosticsSdMountedAtAlternateRoot = false", STORAGE)

    def test_ffat_fallback_is_a_valid_diagnostics_backend(self):
        self.assertIn("internalFallbackMounted.load()", STORAGE)
        self.assertIn("const uint64_t total = FFat.totalBytes();", STORAGE)
        self.assertIn("diagnosticsSdHealthy = true", STORAGE)

    def test_writer_retries_only_after_recovery_gate_and_quiesces_for_transition(self):
        self.assertIn("storageRecoveryAllowedProbe", RECORDER)
        self.assertIn("storage->canRetryDiagnosticsSd()", RECORDER)
        self.assertIn("storage->ensureDiagnosticsSdMounted()", RECORDER)
        self.assertIn("storageTransitionRequested", RECORDER)
        self.assertIn("beginStorageTransition", RECORDER)
        self.assertIn("prepareForShutdown", RECORDER)

    def test_writer_isolated_from_cpu0_watchdog_and_uses_dedicated_sd_bus(self):
        self.assertIn(
            'xTaskCreatePinnedToCore(writerTask, "ride_diag_writer", 6144, nullptr, 0,',
            RECORDER,
        )
        self.assertIn("&writerTaskHandle, 1);", RECORDER)
        open_body = STORAGE.split("FILE *Storage::open", 1)[1].split(
            "int Storage::close", 1
        )[0]
        self.assertIn(
            "waveshareSdBus().begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS)", open_body
        )
        self.assertNotIn("SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS)", open_body)


if __name__ == "__main__":
    unittest.main()
