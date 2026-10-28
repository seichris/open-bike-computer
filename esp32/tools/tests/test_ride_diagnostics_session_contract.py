from pathlib import Path
import json
import subprocess
import sys
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
    def test_actual_marker_replay_is_noop_across_capture_rebind(self):
        from tools.tests.test_navigation_idle_clear import function
        import shutil

        harness = r'''
#include <atomic>
#include <cassert>
#include <cstdio>
#include "ride_diagnostics_control.hpp"
namespace ride_diagnostics {
enum class Level {Warning};
std::atomic<uint32_t> lastMarkerSequence{0};
std::atomic<bool> checkpointRequested{false};
control::MarkerReplayReceipt lastMarkerReceipt;
bool healthy=false;
unsigned recorded=0;
bool record(Level,const char *,const char *,const char *) {
  if (!healthy) return false;
  ++recorded; return true;
}
'''
        harness += function(RECORDER, "bool validIssueCode(const char *value)")
        harness += function(RECORDER, "bool markIssue(const char *code, uint32_t markerSequence, const char *incidentId)")
        harness += r'''
}
std::atomic<bool> bleSessionSupportsRideDiagnostics{true};
struct Http {
  unsigned errors=0;
  void setLastError(const char *,const char *) {++errors;}
} deviceTransferHttp;
namespace ble_transfer {enum class Action {None}; enum {NotifyGeneric};}
void queueTransferControl(ble_transfer::Action,int) {}
void handle(const std::string &command) {
'''
        harness += function(BLE, 'if (command.rfind("mark|", 0) == 0)')
        harness += r'''
}
int main() {
  using namespace ride_diagnostics;
  const char *a="123e4567-e89b-12d3-a456-426614174000";
  const char *b="123e4567-e89b-12d3-a456-426614174001";
  assert(!markIssue("other",7,a)); // failure cannot reserve a receipt
  healthy=true;
  handle(std::string("mark|2|7|other|")+a);
  assert(recorded==1 && deviceTransferHttp.errors==0);
  checkpointRequested=false;
  // The first application succeeded but its ATT response was lost. Exact
  // replay through the actual BLE handler must not poison transfer lastError.
  handle(std::string("mark|2|7|other|")+a);
  assert(recorded==1 && !checkpointRequested && deviceTransferHttp.errors==0);
  assert(!markIssue("device_blank",7,a)); // conflicting payload is not a replay
  assert(!markIssue("other",8,a));
  lastMarkerSequence=control::markerSequenceAfterBinding(a,b,7);
  handle(std::string("mark|2|7|other|")+a);
  assert(recorded==1 && deviceTransferHttp.errors==0); // no event in new capture
  assert(lastMarkerSequence==0); // replay does not mutate the new capture's sequence
  assert(markIssue("other",1,b) && recorded==2); // independent new capture marker
  assert(markIssue("other",1,b) && recorded==2);
  assert(!markIssue("other",0,b));
  assert(markIssue("other",2,nullptr) && recorded==3);
  assert(!markIssue("other",2,nullptr)); // legacy is not silently made idempotent
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "marker.cpp"
            source.write_text(harness)
            compilers = ["g++"]
            if shutil.which("g++-15"):
                compilers.append("g++-15")
            for index, compiler in enumerate(compilers):
                executable = Path(directory) / f"marker-{index}"
                subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                                "-I", str(ROOT / "lib/ride_diagnostics"), str(source),
                                "-o", str(executable)], check=True)
                subprocess.run([str(executable)], check=True)

    def test_actual_loss_summary_is_bounded_and_preserves_failed_receipts(self):
        start = RECORDER.index("  // Report cumulative per-reason counts")
        stop = RECORDER.index("  if (static_cast<uint32_t>(nowMs - lastMemorySampleMs)", start)
        summary = RECORDER[start:stop]
        harness = r'''#include "ride_diagnostics_queue_policy.hpp"
#include "ride_diagnostics_format.hpp"
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string>
namespace queue_policy = ride_diagnostics::queue_policy;
using queue_policy::DropReason;
constexpr unsigned kDropReasonCount = static_cast<unsigned>(DropReason::Count);
std::atomic<unsigned> dropped{1}, dropsByReason[kDropReasonCount]{};
std::atomic<unsigned> maximumWriterDelayMs{987}, maximumWriteDurationMs{123}, maxQueueDepth{24};
std::atomic<uint32_t> memoryDeferrals{0}, maximumMemoryDeferralMs{340},
    memoryDeferralMinimumDmaFree{1200}, memoryDeferralMinimumDmaLargest{40};
unsigned lastReportedDrops[kDropReasonCount]{}, lastLossSummaryMs=0;
uint32_t lastReportedMemoryDeferrals=0;
unsigned depth=0, calls=0, deferralCalls=0;
bool accept=false, acceptDeferral=false;
enum class Level { Info, Warning };
unsigned queuedDepth() { return depth; }
bool record(Level level, const char *category, const char *event, const char *fields) {
  assert(ride_diagnostics::detail::validateFieldsJson(fields, std::strlen(fields)));
  if (std::string(category)=="storage") {
    assert(std::string(event)=="memory_deferred" && level==Level::Warning);
    std::printf("%s\n", fields);
    ++deferralCalls; return acceptDeferral;
  }
  assert(std::string(category)=="logger" && std::string(event)=="loss");
  assert(std::strstr(fields, "\"writerDelayMs\":987"));
  assert(std::strstr(fields, "\"durationMs\":123"));
  assert(std::strstr(fields, "\"maxQueueDepth\":24"));
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
  // Memory deferrals follow the same bounded, drained, retried cadence.
  assert(deferralCalls==0);
  memoryDeferrals=2;
  depth=3; process(150001); assert(deferralCalls==0);
  depth=0; process(150002); assert(deferralCalls==1 && lastReportedMemoryDeferrals==0);
  acceptDeferral=true; process(180002); assert(deferralCalls==2 && lastReportedMemoryDeferrals==2);
  process(210002); assert(deferralCalls==2);
  memoryDeferrals=3; process(240002); assert(deferralCalls==3 && lastReportedMemoryDeferrals==3);
}
'''.replace("// SUMMARY", summary)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "loss.cpp"
            source.write_text(harness)
            executable = Path(directory) / "loss"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "lib/ride_diagnostics"), str(source), "-o", str(executable)], check=True)
            result = subprocess.run([str(executable)], check=True, capture_output=True, text=True)
        # Installed apps reject any field outside the closed vocabulary, so the
        # deferral summary may only reuse existing numeric field names.
        sys.path.insert(0, str(ROOT.parent / "tools"))
        import ride_diagnostics as host_diagnostics
        summaries = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(summaries), 3)
        self.assertEqual(summaries[-1], {"eventCount": 3, "durationMs": 340,
                                         "minimumFreeBytes": 1200,
                                         "minimumLargestBytes": 40})
        for fields in summaries:
            for key in fields:
                self.assertIn(key, host_diagnostics.ALLOWED_FIELD_KEYS)
                self.assertIn(key, host_diagnostics.FIRMWARE_NUMBER_FIELD_KEYS)

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

    def test_fault_capsule_write_failure_retries_and_preserves_rtc(self):
        update = RECORDER[RECORDER.index("void updateFaultCapsule("):RECORDER.index("bool utcNow(")]
        start = RECORDER.index("bool flushFaultCapsulesIfPossible(bool beforeSealCutoff) {")
        flush = RECORDER[start:RECORDER.index("uint16_t queuedDepth()", start)]
        receipt = RECORDER[RECORDER.index("struct FaultCapsuleWriteReceipt {"):RECORDER.index("bool writeQueuedEvent(")]
        self.run_production_harness("ride_diagnostics_fault_retry_harness.cpp", update + receipt + flush)

    def test_transfer_seal_admits_capsules_under_sustained_load(self):
        start = RECORDER.index("transfer_policy::SealPreparation\nsealActiveChunkForTransfer(uint32_t timeoutMs) {")
        seal = RECORDER[start:RECORDER.index("bool sealActiveChunk(uint32_t timeoutMs) {", start)]
        self.run_production_harness("ride_diagnostics_seal_harness.cpp", seal)

    def test_writer_services_reconnect_bursts_and_wakes_without_polling(self):
        start = RECORDER.index("void noteDrop(DropReason reason) {")
        note = RECORDER[start:RECORDER.index("std::atomic<uint32_t> storageErrors", start)]
        start = RECORDER.index("void noteMaximum(")
        maximum = RECORDER[start:RECORDER.index("// When the reserved critical lane", start)]
        start = RECORDER.index("bool peekNextEvent(")
        peek = RECORDER[start:RECORDER.index("bool completeSealIfReady()", start)]
        start = RECORDER.index("void writerTask(void *) {")
        writer = RECORDER[start:RECORDER.index("bool enqueueFormattedEvent", start)]
        self.run_production_harness("ride_diagnostics_writer_harness.cpp", note + maximum + peek + writer)

    def memory_pressure_functions(self):
        start = RECORDER.index("void noteDrop(DropReason reason) {")
        note = RECORDER[start:RECORDER.index("std::atomic<uint32_t> storageErrors", start)]
        start = RECORDER.index("void noteMaximum(")
        extremes = RECORDER[start:RECORDER.index("// When the reserved critical lane", start)]
        start = RECORDER.index("bool peekNextEvent(")
        peek = RECORDER[start:RECORDER.index("bool completeSealIfReady()", start)]
        start = RECORDER.index("struct MemoryDeferral {")
        writer = RECORDER[start:RECORDER.index("bool enqueueFormattedEvent", start)]
        return note + extremes + peek + writer

    def run_memory_pressure(self, functions):
        harness = (ROOT / "tools/tests/ride_diagnostics_memory_pressure_harness.cpp").read_text()
        harness = harness.replace("// PRODUCTION_FUNCTIONS", functions)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "pressure.cpp"
            source.write_text(harness)
            executable = Path(directory) / "pressure"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "lib/ride_diagnostics"), str(source),
                            "-o", str(executable)], check=True)
            return subprocess.run([str(executable)], capture_output=True, text=True)

    def test_writer_defers_io_below_the_dma_floor_and_paces_recovery(self):
        result = self.run_memory_pressure(self.memory_pressure_functions())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_memory_gate_and_recovery_regressions_are_detected(self):
        functions = self.memory_pressure_functions()
        mutations = {
            "records written through a DMA trough": (
                "const bool memoryWait = recorderHealthy && recordsWaiting && !ioAdmitted();",
                "const bool memoryWait = false;"),
            "probe immediately after the fault": (
                "} else if (recovery.due(nowMs) &&", "} else if (true &&"),
            "probe below the floor": (
                "                storageRecoveryAllowedProbe()) &&\n               ioAdmitted()) {",
                "                storageRecoveryAllowedProbe())) {"),
            "checkpoint below the floor": (
                "static_cast<uint32_t>(nowMs - lastCheckpointMs) >= 5000U) &&\n        ioAdmitted()) {",
                "static_cast<uint32_t>(nowMs - lastCheckpointMs) >= 5000U)) {"),
            "no backoff growth": (
                "        recovery.probeFailed(nowMs);", "        recovery.reset();"),
        }
        for name, (old, new) in mutations.items():
            with self.subTest(name):
                self.assertIn(old, functions)
                result = self.run_memory_pressure(functions.replace(old, new, 1))
                self.assertEqual(result.returncode, 42, result.stderr)

    def test_oversized_index_cannot_claim_complete_inventory(self):
        http = (ROOT / "lib/ride_diagnostics/ride_diagnostics_http.cpp").read_text()
        types = http[http.index("struct Chunk {"):http.index("std::string jsonEscape")]
        listing = http[http.index("ChunkIndex listChunks("):http.index("bool writeBodySegment")]
        self.run_production_harness("ride_diagnostics_index_harness.cpp", types + listing, filesystem=True)

    def test_checked_checkpoints_precede_fault_acknowledgement(self):
        writer = RECORDER[RECORDER.index("struct FaultCapsuleWriteReceipt {"):RECORDER.index("bool flushFaultCapsulesIfPossible(bool beforeSealCutoff) {")]
        self.run_production_harness("ride_diagnostics_checkpoint_harness.cpp", writer)

    def test_backend_transition_allocates_new_namespace(self):
        parse = RECORDER[RECORDER.index("bool parseUnsigned(const char *value, uint32_t &out) {"):RECORDER.index("void copyCapture")]
        identity = RECORDER[RECORDER.index("uint32_t persistentBootSequence("):RECORDER.index("enum class ActiveFileCloseResult")]
        paths = RECORDER[RECORDER.index("bool ensurePaths()"):RECORDER.index("void abandonActiveChunkAfterUncertainWrite()")]
        start = RECORDER.index("bool isClosedChunk(")
        closed = RECORDER[start:RECORDER.index("\n}", start) + 2]
        end = RECORDER[RECORDER.index("bool beginStorageTransition("):RECORDER.index("bool prepareForShutdown(")]
        start = RECORDER.index("    if (storageTransitionRequested.load(std::memory_order_acquire) &&\n        !sealRequested.load(std::memory_order_acquire)) {")
        pause = RECORDER[start:RECORDER.index("    const uint32_t nowMs = millis();", start)]
        pause = "void writerPauseIteration() { for (int pass=0; pass<1; ++pass) {" + pause + "}}"
        self.run_production_harness("ride_diagnostics_backend_transition_harness.cpp", parse + identity + paths + closed + end + pause, filesystem=True)

    def run_production_harness(self, name, functions, filesystem=False):
        harness = (ROOT / "tools/tests" / name).read_text().replace("// PRODUCTION_FUNCTIONS", functions)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "recovery.cpp"
            source.write_text(harness)
            executable = Path(directory) / "recovery"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "lib/ride_diagnostics"), str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)] + ([str(Path(directory) / "data")] if filesystem else []), check=True)

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

    def test_completed_preparation_reclaims_stack_before_network_admission(self):
        begin = BLE.index("static void processCompletedDiagnosticsSessionStart()")
        end = BLE.index("static bool startDiagnosticsSessionAsync()", begin)
        function = BLE[begin:end]
        shutdown = BLE[BLE.index("bool BLENavigationServer::pollShutdownQuiescence()"):
                       BLE.index("void BLENavigationServer::process()")]
        shutdown = shutdown.replace("BLENavigationServer::", "")
        harness = (ROOT / "tools/tests/diagnostics_preparation_handoff_harness.cpp").read_text()
        harness = harness.replace("// PRODUCTION_SHUTDOWN", shutdown)
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "handoff.cpp"
            source.write_text(harness.replace("// PRODUCTION_FUNCTION", function))
            executable = Path(directory) / "handoff"
            subprocess.run(["g++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "lib/ride_diagnostics"),
                            "-I", str(ROOT / "lib/device_transfer"),
                            str(source), "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

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
