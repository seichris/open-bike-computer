from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
STORAGE = (ROOT / "lib/storage/storage.cpp").read_text(encoding="utf-8")
HAL = (ROOT / "include/hal.hpp").read_text(encoding="utf-8")
BLE_NAVIGATION = (ROOT / "lib/ble_navigation/ble_navigation.cpp").read_text(
    encoding="utf-8"
)
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
        self.assertNotIn("kDiagnosticsAlternateRoot", STORAGE)

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

    def test_writer_isolated_from_cpu0_watchdog_and_uses_native_first_migration(self):
        self.assertIn(
            'writerTask, "ride_diag_writer", 6144, nullptr, 0,',
            RECORDER,
        )
        self.assertIn("&writerTaskHandle, 1);", RECORDER)
        waveshare_init = STORAGE.split("esp_err_t Storage::initSD()", 1)[1].split(
            "#elif defined(SPI_SHARED)", 1
        )[0]
        self.assertIn("SD_MMC.setPins(", waveshare_init)
        self.assertIn('SD_MMC.begin("/sdcard", true, false,', waveshare_init)
        self.assertIn("storage_mount_retry_policy::runMountSequence", waveshare_init)
        self.assertIn(
            "waveshare_storage_migration_policy::mountNativeFirst",
            waveshare_init,
        )
        self.assertIn("SD.begin(", waveshare_init)
        self.assertIn("SPIClass &migrationBus", waveshare_init)
        self.assertIn("bus=HSPI", waveshare_init)
        self.assertLess(
            waveshare_init.index("SD_MMC.begin"),
            waveshare_init.index("SD.begin"),
        )

        waveshare_pins = HAL.split(
            "// microSD in vendor-native one-bit SDMMC mode.", 1
        )[1].split(
            "#endif // WAVESHARE_AMOLED_175 || WAVESHARE_AMOLED_206", 1
        )[0]
        self.assertIn("WAVESHARE_SDMMC_CLK = GPIO_NUM_2", waveshare_pins)
        self.assertIn("WAVESHARE_SDMMC_CMD = GPIO_NUM_1", waveshare_pins)
        self.assertIn("WAVESHARE_SDMMC_D0 = GPIO_NUM_3", waveshare_pins)
        self.assertIn("WAVESHARE_LEGACY_SD_CS = GPIO_NUM_17", waveshare_pins)
        self.assertIn("WAVESHARE_LEGACY_SD_CS = GPIO_NUM_41", waveshare_pins)
        self.assertIn("WAVESHARE_LEGACY_SD_MOSI = GPIO_NUM_1", waveshare_pins)
        self.assertIn("WAVESHARE_LEGACY_SD_MISO = GPIO_NUM_3", waveshare_pins)
        self.assertIn("WAVESHARE_LEGACY_SD_CLK = GPIO_NUM_2", waveshare_pins)

        open_body = STORAGE.split("FILE *Storage::open", 1)[1].split(
            "int Storage::close", 1
        )[0]
        self.assertNotIn("SD_MMC.begin", open_body)
        self.assertNotIn("SD_MMC.setPins", open_body)
        self.assertNotIn("SPI.begin", open_body)

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

    def test_waveshare_build_links_legacy_stack_only_for_migration_fallback(self):
        include_block = STORAGE.split('#include "freertos/task.h"', 1)[1].split(
            "#include <FFat.h>", 1
        )[0]
        self.assertIn("#include <SD_MMC.h>", include_block)
        self.assertIn("#include <SD.h>", include_block)
        self.assertIn("#include <SPI.h>", include_block)
        self.assertIn(
            '"legacy_spi_migration"',
            STORAGE,
        )
        self.assertIn(
            "backend == StorageBackend::LegacySpiMigration",
            STORAGE,
        )

    def test_device_transfer_status_exposes_storage_migration_state(self):
        status = BLE_NAVIGATION.split(
            "static std::string genericTransferStatusJson()", 1
        )[1].split("static void notifyMapTransferStatus", 1)[0]
        self.assertIn('\\"storage\\":{\\"backend\\":\\"', status)
        self.assertIn("storage.storageBackendName()", status)
        self.assertIn("storage.storagePowerCycleRequired()", status)


if __name__ == "__main__":
    unittest.main()
