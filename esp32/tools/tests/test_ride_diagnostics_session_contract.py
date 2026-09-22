from pathlib import Path
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
