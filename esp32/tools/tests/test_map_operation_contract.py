"""Source-composition contracts; portable C++ tests exercise actual policy/IO."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class MapOperationCompositionTests(unittest.TestCase):
    def test_operation_worker_is_serviced_in_live_loop_and_shutdown(self):
        main = (ROOT / 'src/main.cpp').read_text()
        self.assertGreaterEqual(main.count('mapTransferHttp.submitPendingOperationTask();'), 2)
        for boundary in ('deviceTransferHttp.pollShutdown();', 'mapTransferHttp.submitPendingRollback();'):
            position = main.index(boundary)
            self.assertIn('mapTransferHttp.submitPendingOperationTask();', main[position:position+180])

    def test_new_metadata_does_not_masquerade_as_legacy_ready(self):
        stream = (ROOT / 'lib/map_transfer/map_stream_install.cpp').read_text()
        self.assertIn('operationID_.empty() ? kReadyFile : ".operation-ready"', stream)
        install = (ROOT / 'lib/map_transfer/map_transfer.cpp').read_text()
        self.assertGreaterEqual(install.count('acceptedMapOperation(storageRoot_, operationDeviceID_'), 2)

    def test_shared_journal_writes_are_serialized_and_release_is_terminal(self):
        source = (ROOT / 'lib/map_transfer_http/map_transfer_http.cpp').read_text()
        self.assertIn('xSemaphoreCreateRecursiveMutexStatic', source)
        self.assertIn('OperationStoreGuard operationStoreGuard(*this);', source)
        terminal = source[source.index('void MapTransferHttpServer::executeOperationTask'):]
        self.assertLess(terminal.index('store.rendererAcknowledged'), terminal.index('finishActivation('))
        self.assertLess(terminal.index('finishActivation('), terminal.index('releaseCommitGrant();'))
        self.assertIn('readOperationStatus(request.mapOperationID)', source)
        self.assertIn('permitsOperationAdmission(request.mapOperationAdmissionEpoch', source)

    def test_boot_binds_the_same_physical_identity_before_recovery_and_render(self):
        main = (ROOT / 'src/main.cpp').read_text()
        start = main.index('map_transfer::MapTransferInstaller mapInstaller("/sdcard");')
        block = main[start:]
        self.assertLess(block.index('setOperationDeviceID(device_ownership::hardwareDeviceIdHex())'),
                        block.index('mapInstaller.recoverInterruptedActivation()'))
        self.assertLess(block.index('mapInstaller.recoverInterruptedActivation()'),
                        block.index('mapInstaller.readActiveMap(activeMap)'))
        ownership = (ROOT / 'lib/ble_navigation/device_ownership.cpp').read_text()
        load = ownership[ownership.index('bool DeviceOwnership::loadOrCreateDeviceId()'):]
        self.assertIn('deriveHardwareDeviceId(derivedDeviceId)', load)
        source = (ROOT / 'lib/map_transfer_http/map_transfer_http.cpp').read_text()
        self.assertIn('installer_ = MapTransferInstaller(storageRoot_);\n  installer_.setOperationDeviceID(operationDeviceID_);', source)

    def test_ownership_initialization_and_query_use_authenticated_channel(self):
        source = (ROOT / 'lib/ble_navigation/ble_navigation.cpp').read_text()
        self.assertIn('mapTransferHttp.setOperationDeviceID(stableDeviceId);', source)
        self.assertIn('hasPrefix(value, "MOPQ|")', source)
        self.assertIn('requireAuthenticated("map operation query")', source)
        self.assertIn('mapTransferHttp.takeOperationStatusNotification()', source)

if __name__ == '__main__':
    unittest.main()
