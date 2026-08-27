from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
STORAGE = (ROOT / "lib/storage/storage.cpp").read_text(encoding="utf-8")
RECORDER = (ROOT / "lib/ride_diagnostics/ride_diagnostics.cpp").read_text(
    encoding="utf-8"
)


class RideDiagnosticsStorageContractTests(unittest.TestCase):
    def test_transfer_preparation_probes_the_stable_recorder_backend(self):
        self.assertIn("writableProbeSucceeded", STORAGE)
        self.assertIn("prepareDiagnosticsStorage", STORAGE)
        self.assertIn("StoragePreparation::CardMissing", STORAGE)
        self.assertIn("StoragePreparation::WritableProbeFailed", STORAGE)
        self.assertIn("StoragePreparation::ReadyInternalFallback", STORAGE)
        self.assertNotIn("SD.begin(\n        SD_CS, hspi, WAVESHARE_SD_SPI_FREQ_HZ,\n        kDiagnosticsAlternateRoot)", STORAGE)

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

    def test_logger_health_captures_queue_and_storage_state_before_shutdown(self):
        health = RECORDER.split("bool recordHealth", 1)[1].split(
            "bool recordClockAnchor", 1
        )[0]
        for field in (
            "enqueuedCount",
            "writtenCount",
            "droppedCount",
            "storageErrorCount",
            "queueDepth",
            "maxQueueDepth",
            "available",
        ):
            self.assertIn(field, health)
        shutdown = RECORDER.split("bool prepareForShutdown", 1)[1].split(
            "bool beginStorageTransition", 1
        )[0]
        self.assertLess(
            shutdown.index('recordHealth("shutdown")'),
            shutdown.index('"controlled_shutdown"'),
        )


if __name__ == "__main__":
    unittest.main()
