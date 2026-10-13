from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parents[2]
BLE = (ROOT / "lib/ble_navigation/ble_navigation.cpp").read_text(
    encoding="utf-8"
)
RECORDER = (ROOT / "lib/ride_diagnostics/ride_diagnostics.cpp").read_text(
    encoding="utf-8"
)
MAIN = (ROOT / "src/main.cpp").read_text(encoding="utf-8")


class RideDiagnosticsSessionContractTests(unittest.TestCase):
    def test_actual_loss_summary_is_bounded_and_preserves_failed_receipts(self):
        start = RECORDER.index("  // Report cumulative per-reason counts")
        stop = RECORDER.index("  if (static_cast<uint32_t>(nowMs - lastMemorySampleMs)", start)
        summary = RECORDER[start:stop]
        harness = r'''#include "ride_diagnostics_queue_policy.hpp"
#include "ride_diagnostics_format.hpp"
#include <atomic>
#include <cassert>
#include <string>
namespace queue_policy = ride_diagnostics::queue_policy;
using queue_policy::DropReason;
constexpr unsigned kDropReasonCount = static_cast<unsigned>(DropReason::Count);
std::atomic<unsigned> dropped{1}, dropsByReason[kDropReasonCount]{};
unsigned lastReportedDrops[kDropReasonCount]{}, lastLossSummaryMs=0;
unsigned depth=0, calls=0;
bool accept=false;
enum class Level { Info };
unsigned queuedDepth() { return depth; }
bool record(Level, const char *category, const char *event, const char *fields) {
  assert(std::string(category)=="logger" && std::string(event)=="loss");
  assert(ride_diagnostics::detail::validateFieldsJson(fields, std::strlen(fields)));
  ++calls; return accept;
}
void process(unsigned nowMs) {
// SUMMARY
}
int main() {
  const unsigned reason=static_cast<unsigned>(DropReason::QueueBusy);
  dropsByReason[reason]=1;
  process(29999); assert(calls==0);
  depth=1; process(30000); assert(calls==0 && lastLossSummaryMs==0);
  depth=0; process(30001); assert(calls==1 && lastReportedDrops[reason]==0);
  accept=true; process(60000); assert(calls==1);
  process(60001); assert(calls==2 && lastReportedDrops[reason]==1);
  assert(dropped==1 && dropsByReason[reason]==1);
  process(90001); assert(calls==2);
  dropsByReason[reason]=2; dropped=2;
  process(120001); assert(calls==3 && lastReportedDrops[reason]==2);
  assert(dropped==2 && dropsByReason[reason]==2);
}
'''.replace("// SUMMARY", summary)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "loss.cpp"
            source.write_text(harness)
            executable = Path(directory) / "loss"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "lib/ride_diagnostics"), str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_actual_enqueue_accounts_for_each_admission_failure(self):
        note = RECORDER[RECORDER.index("void noteDrop(DropReason reason) {"):
                        RECORDER.index("std::atomic<uint32_t> storageErrors")]
        enqueue = RECORDER[RECORDER.index("bool enqueue(QueuedEvent &event) {"):
                           RECORDER.index("bool enqueueFormattedEvent")]
        peek = RECORDER[RECORDER.index("bool peekNextEvent("):
                        RECORDER.index("bool completeSealIfReady()")]
        harness = (ROOT / "tools/tests/ride_diagnostics_queue_harness.cpp").read_text()
        harness = harness.replace("// PRODUCTION_FUNCTIONS", note + peek + enqueue)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "queue.cpp"
            source.write_text(harness)
            executable = Path(directory) / "queue"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "tools/tests"), str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_actual_maintenance_yields_at_every_filesystem_boundary(self):
        # Use the production loops, not a second implementation of retention.
        helpers = RECORDER[RECORDER.index("struct ChunkFileScan"):
                           RECORDER.index("const char *levelName")]
        parse = RECORDER[RECORDER.index("bool parseUnsigned(const char *value, uint32_t &out) {"):
                         RECORDER.index("void copyCapture")]
        collect = RECORDER[RECORDER.index("ChunkFileScan collectChunkFiles"):
                           RECORDER.index("bool hasChunkWriteReserve()")]
        harness = (ROOT / "tools/tests/ride_diagnostics_retention_harness.cpp").read_text()
        harness = harness.replace("// PRODUCTION_FUNCTIONS", parse + helpers + collect)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "retention.cpp"
            source.write_text(harness)
            executable = Path(directory) / "retention"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "tools/tests"), str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable), str(Path(directory) / "sdcard")], check=True)

    def test_admitted_retry_clears_old_error_before_worker_can_fail(self):
        start = BLE[BLE.index("static bool startDiagnosticsSessionAsync"):
                    BLE.index("static uint64_t currentAuthenticatedTransferSessionId")]
        admission = start.index("diagnosticsSessionActiveGeneration.store(generation")
        clear = start.index('deviceTransferHttp.setLastError("", "")')
        worker = start.index("xTaskCreatePinnedToCore")
        self.assertLess(admission, clear)
        self.assertLess(clear, worker)
        self.assertGreater(clear, start.index("diagnosticsSessionStartInProgress.exchange"))

    def test_in_flight_maintenance_yields_without_deleting_from_partial_scan(self):
        collect_start = RECORDER.index("ChunkFileScan collectChunkFiles")
        prune_start = RECORDER.index("void pruneRetention()", collect_start)
        collect = RECORDER[collect_start:prune_start]
        prune = RECORDER[prune_start:
                         RECORDER.index("bool hasChunkWriteReserve()")]
        cleanup = RECORDER[RECORDER.index("void removeEmptyBootDirectories()"):
                           RECORDER.index("const char *levelName")]
        self.assertGreaterEqual(collect.count("shouldStop()"), 6)
        self.assertIn("closedir(bootDirectory)", collect)
        self.assertIn("closedir(boots)", collect)
        self.assertLess(prune.index("scan.interrupted"), prune.index("removeChunkFile"))
        self.assertIn("empty && !retentionScanInterrupted()", cleanup)
        self.assertNotIn("retentionLeaseDeadlineMs.store(0", prune)

    def test_snapshot_lease_precedes_storage_probe_and_seal(self):
        start = BLE[
            BLE.index("static void diagnosticsSessionStartTask") :
            BLE.index("static bool startDiagnosticsSessionAsync")
        ]
        lease = start.index("armTransferSnapshotLease()")
        storage = start.index("storage.prepareDiagnosticsStorage()")
        seal = start.index("sealActiveChunkForTransfer()")
        self.assertLess(lease, storage)
        self.assertLess(storage, seal)

    def test_only_an_enabled_session_retains_the_lease(self):
        start = BLE[
            BLE.index("static void diagnosticsSessionStartTask") :
            BLE.index("static bool startDiagnosticsSessionAsync")
        ]
        enabled = start.index(
            'deviceTransferHttp.setEnabled(true, "diagnostics")'
        )
        keep = start.index("keepSnapshotLease = true", enabled)
        release = start.index("endTransferSnapshotLease()", keep)
        self.assertLess(enabled, keep)
        self.assertLess(keep, release)

    def test_server_start_failure_preserves_the_specific_cause(self):
        start = BLE[
            BLE.index("static void diagnosticsSessionStartTask") :
            BLE.index("static bool startDiagnosticsSessionAsync")
        ]
        enabled = start.index(
            'deviceTransferHttp.setEnabled(true, "diagnostics")'
        )
        failure = start.index("startFailure.lastErrorCode.empty()", enabled)
        fallback = start.index('"diagnostics_start_failed"', failure)
        record = start.index("startFailureCode", fallback)
        self.assertLess(enabled, failure)
        self.assertLess(failure, fallback)
        self.assertLess(fallback, record)

    def test_preseal_lease_publication_never_waits_behind_pruning(self):
        arm = RECORDER[
            RECORDER.index("void armTransferSnapshotLease") :
            RECORDER.index("void beginTransferSnapshotLease")
        ]
        begin = RECORDER[
            RECORDER.index("void beginTransferSnapshotLease") :
            RECORDER.index("void refreshTransferSnapshotLease")
        ]
        end = RECORDER[
            RECORDER.index("void endTransferSnapshotLease") :
            RECORDER.index("Stats stats()")
        ]
        self.assertIn("retentionLeaseDeadlineMs.store", arm)
        self.assertNotIn("SemaphoreGuard", arm)
        self.assertIn("SemaphoreGuard", begin)
        self.assertIn("armTransferSnapshotLease(durationMs)", begin)
        self.assertIn("retentionLeaseDeadlineMs.store(0", end)
        self.assertNotIn("SemaphoreGuard", end)

    def test_mode_teardown_releases_the_session_lease(self):
        stop = MAIN[
            MAIN.index("bool stopActiveDeviceTransfer") :
            MAIN.index("#if FIRMWARE_DIAGNOSTICS", MAIN.index("bool stopActiveDeviceTransfer"))
        ]
        diagnostics = stop[
            stop.index('status.mode == "diagnostics"') :
            stop.index('status.mode == "map"')
        ]
        self.assertIn("endTransferSnapshotLease()", diagnostics)
        self.assertIn("deviceTransferHttp.setEnabled(false)", diagnostics)


if __name__ == "__main__":
    unittest.main()
