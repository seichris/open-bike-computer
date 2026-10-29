from pathlib import Path
import re
import unittest
import subprocess
import tempfile


ROOT = Path(__file__).parents[2]
STORAGE = (ROOT / "lib/storage/storage.cpp").read_text(encoding="utf-8")
HAL = (ROOT / "include/hal.hpp").read_text(encoding="utf-8")
BLE_NAVIGATION = (ROOT / "lib/ble_navigation/ble_navigation.cpp").read_text(
    encoding="utf-8"
)
RECORDER = (ROOT / "lib/ride_diagnostics/ride_diagnostics.cpp").read_text(
    encoding="utf-8"
)
POLICY = (
    ROOT / "lib/ride_diagnostics/ride_diagnostics_storage_policy.hpp"
).read_text(encoding="utf-8")


class RideDiagnosticsStorageContractTests(unittest.TestCase):
    def test_checked_sync_commits_vfs_and_propagates_each_failure(self):
        function = STORAGE[STORAGE.index("int Storage::sync(FILE *file)"):STORAGE.index("/**", STORAGE.index("int Storage::sync(FILE *file)"))]
        harness = r"""
#include <cassert>
#include <cstdio>
#include <vector>
namespace power_management {
 enum class LockDomain { Storage };
 struct ScopedLock { explicit ScopedLock(LockDomain) {} };
}
struct Storage { int sync(FILE*); };
std::vector<int> calls;
int flushResult=0, descriptor=3, syncResult=0;
int test_fflush(FILE*) { calls.push_back(1); return flushResult; }
int test_fileno(FILE*) { calls.push_back(2); return descriptor; }
int test_fsync(int value) { assert(value==descriptor); calls.push_back(3); return syncResult; }
#define fflush test_fflush
#define fileno test_fileno
#define fsync test_fsync
// FUNCTION
int main() {
 Storage store; FILE *file=reinterpret_cast<FILE*>(1);
 assert(store.sync(file)==0 && calls==std::vector<int>({1,2,3}));
 calls.clear(); flushResult=-1;
 assert(store.sync(file)!=0 && calls==std::vector<int>({1}));
 calls.clear(); flushResult=0; descriptor=-1;
 assert(store.sync(file)!=0 && calls==std::vector<int>({1,2}));
 calls.clear(); descriptor=3; syncResult=-1;
 assert(store.sync(file)!=0 && calls==std::vector<int>({1,2,3}));
 calls.clear(); assert(store.sync(nullptr)!=0 && calls.empty());
}
""".replace("// FUNCTION", function)
        with tempfile.TemporaryDirectory() as directory:
            source, executable = Path(directory)/"sync.cpp", Path(directory)/"sync"
            source.write_text(harness)
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

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

    def test_ffat_uses_a_bounded_backend_specific_retention_policy(self):
        self.assertIn("kInternalFfatBudget", POLICY)
        self.assertIn("1ULL * 1024ULL * 1024ULL", POLICY)
        self.assertIn("2ULL * 1024ULL * 1024ULL", POLICY)
        self.assertIn("kRemovableBudget", POLICY)
        self.assertIn("32ULL * 1024ULL * 1024ULL", POLICY)
        self.assertIn("8ULL * 1024ULL * 1024ULL", POLICY)
        self.assertIn(
            "storage->storageBackend() == StorageBackend::InternalFFat",
            RECORDER,
        )
        self.assertIn("storage_policy::constraintsExceeded", RECORDER)
        self.assertIn("freeBytes = storage->diagnosticsSdFreeBytes();", RECORDER)

    def test_writer_retries_only_after_recovery_gate_and_quiesces_for_transition(self):
        self.assertIn("storageRecoveryAllowedProbe", RECORDER)
        self.assertIn("storage->canRetryDiagnosticsSd()", RECORDER)
        self.assertIn("storage->ensureDiagnosticsSdMounted()", RECORDER)
        self.assertIn("storageTransitionRequested", RECORDER)
        self.assertIn("beginStorageTransition", RECORDER)
        self.assertIn("prepareForShutdown", RECORDER)

    def test_writer_isolated_from_cpu0_watchdog_and_uses_native_first_migration(self):
        self.assertIn(
            'writerTask, "ride_diag_writer", 6144, nullptr, 1,',
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
        self.assertIn("formatRecorderHealthFields", health)
        formatter = (ROOT / "lib/ride_diagnostics/ride_diagnostics_format.hpp").read_text()
        for field in (
            "recorderReady",
            "enqueuedCount",
            "writtenCount",
            "droppedCount",
            "storageErrorCount",
            "queueDepth",
            "maxQueueDepth",
            "available",
        ):
            self.assertIn(field, formatter)
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

    def descriptor_fault_harness(self, mutate=None):
        from tools.tests.test_sd_only_map_storage import definition
        header = (ROOT / "lib/storage/storage.hpp").read_text(encoding="utf-8")
        start = header.index("struct StorageReadEvidence {")
        evidence = header[start:header.index("};", start) + 2]
        probe = definition(STORAGE, "bool writableProbeSucceeded(const char *root) {")
        descriptors = "".join(definition(STORAGE, signature) for signature in (
            "int Storage::openDescriptor(",
            "int Storage::closeDescriptor(",
            "size_t Storage::writeDescriptor(",
            "StorageReadEvidence Storage::readDescriptor(",
            "int Storage::syncDescriptor(",
        ))
        recorder = (
            RECORDER[RECORDER.index("enum class ActiveFileCloseResult"):
                     RECORDER.index("ActiveFileCloseResult closeAndAdvanceActiveChunk()")] +
            RECORDER[RECORDER.index("bool ensurePaths()"):
                     RECORDER.index("void abandonActiveChunkAfterUncertainWrite()")])
        if mutate is not None:
            probe, descriptors, recorder = mutate(probe, descriptors, recorder)

        # Route the production POSIX calls through the harness fault points.
        def faulted(text):
            return re.sub(r"(?<![\w:])::(open|write|read|fsync|close|unlink)\(",
                          lambda match: "fault" + match.group(1).capitalize() + "(",
                          text)

        harness = (ROOT / "tools/tests/storage_descriptor_fault_harness.cpp").read_text()
        for marker, text in (("// PRODUCTION_EVIDENCE", evidence),
                             ("// PRODUCTION_PROBE", faulted(probe)),
                             ("// PRODUCTION_DESCRIPTORS", faulted(descriptors)),
                             ("// PRODUCTION_RECORDER", faulted(recorder))):
            harness = harness.replace(marker, text, 1)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "faults.cpp"
            source.write_text(harness)
            executable = Path(directory) / "faults"
            compiled = subprocess.run(
                ["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                 "-I", str(ROOT / "tools/tests"), str(source),
                 "-o", str(executable)], capture_output=True, text=True)
            if compiled.returncode != 0:
                return compiled
            return subprocess.run([str(executable), str(Path(directory) / "card")],
                                  capture_output=True, text=True)

    def test_storage_io_fails_with_errors_and_never_uses_stdio(self):
        result = self.descriptor_fault_harness()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("never stdio", result.stdout)

    def test_storage_fault_regressions_are_detected(self):
        mutations = {
            # Reintroducing a newlib stream fails to compile: fopen is poisoned.
            "stdio probe": (0, "const int probe = ::open(probePath, O_WRONLY | O_CREAT | O_TRUNC, 0644);\n"
                               "  if (probe < 0)\n    return false;",
                            "FILE *stream = fopen(probePath, \"wb\");\n"
                            "  if (stream == nullptr)\n    return false;\n"
                            "  const int probe = -1;"),
            "probe leaks its descriptor on a failed write": (
                0, "  const bool synced = wrote && ::fsync(probe) == 0;",
                "  if (!wrote) return false;\n  const bool synced = ::fsync(probe) == 0;"),
            "failed open keeps its admission slot": (
                1, "  streamAdmission_.finishOpenDescriptor(slot, descriptor);",
                "  if (descriptor >= 0)\n    streamAdmission_.finishOpenDescriptor(slot, descriptor);"),
            "failed close is not latched": (
                1, "  streamAdmission_.finishClose(slot, result == 0);",
                "  streamAdmission_.finishClose(slot, true);"),
            "short writes are reported as complete": (
                1, "    if (result <= 0)\n      break;\n    written += static_cast<size_t>(result);",
                "    if (result <= 0)\n      return size;\n    written += static_cast<size_t>(result);"),
            "chunk keeps a closed descriptor": (
                2, "  activeDescriptor = -1;\n  if (flushResult != 0)",
                "  if (flushResult != 0)"),
        }
        for name, (part, old, new) in mutations.items():
            with self.subTest(name):
                def mutate(probe, descriptors, recorder, part=part, old=old, new=new):
                    parts = [probe, descriptors, recorder]
                    self.assertIn(old, parts[part])
                    parts[part] = parts[part].replace(old, new, 1)
                    return tuple(parts)
                result = self.descriptor_fault_harness(mutate)
                if name == "stdio probe":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("poisoned", result.stderr)
                else:
                    self.assertEqual(result.returncode, 42, result.stderr)

    def test_recorder_scratch_is_task_only_psram_and_files_are_raw(self):
        self.assertIn('#include "../utils/src/task_data_placement.hpp"', RECORDER)
        self.assertIn(
            "BICINO_TASK_DATA ChunkFile retentionFiles[kMaximumRetainedFiles]",
            RECORDER)
        self.assertIn(
            "BICINO_TASK_DATA ChunkFile filePruneCandidates[kFilePruneBatch]",
            RECORDER)
        # PSRAM is safe only for writer-task data: the scratch has no user
        # outside retention pruning (no ISR, callback or cache-disabled path).
        prune = RECORDER.index("void pruneRetention() {")
        prune_end = RECORDER.index("bool hasChunkWriteReserve()", prune)
        for name in ("retentionFiles", "filePruneCandidates"):
            uses = [match.start() for match in
                    re.finditer(r"\b" + name + r"\b", RECORDER)]
            self.assertGreater(len(uses), 1, name)
            for at in uses[1:]:
                self.assertTrue(prune <= at < prune_end, name)
        # Recorder and export files are raw descriptors: newlib's fopen()
        # aborts when its stream lock cannot be allocated from internal RAM.
        for path in sorted((ROOT / "lib/ride_diagnostics").glob("*.[ch]pp")):
            code = re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))
            stream = re.search(
                r"\b(?:fopen|fdopen|freopen)\(|"
                r"storage(?:->|\.)(?:open|close|read|write|sync|flush)\(", code)
            with self.subTest(path.name):
                self.assertIsNone(stream, stream and stream.group(0))
        probe = STORAGE[STORAGE.index("bool writableProbeSucceeded("):
                        STORAGE.index("#if defined(WAVESHARE_AMOLED_175)",
                                      STORAGE.index("bool writableProbeSucceeded("))]
        self.assertNotIn("fopen(", re.sub(r"//[^\n]*", "", probe))

    def test_device_transfer_status_exposes_storage_migration_state(self):
        status = BLE_NAVIGATION.split(
            "static std::string genericTransferStatusJson()", 1
        )[1].split("static void notifyMapTransferStatus", 1)[0]
        self.assertIn('appendFieldPrefix(body, "storage")', status)
        self.assertIn("storage.storageBackendName()", status)
        self.assertIn("storage.storagePowerCycleRequired()", status)


if __name__ == "__main__":
    unittest.main()
