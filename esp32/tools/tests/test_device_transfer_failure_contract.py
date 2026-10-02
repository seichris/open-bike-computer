from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
HTTP = (ROOT / "lib/device_transfer/device_transfer_http.cpp").read_text()
TLS = (ROOT / "lib/device_transfer/device_transfer_tls.cpp").read_text()
STORAGE = (ROOT / "lib/storage/storage.cpp").read_text()
DIAGNOSTICS = (ROOT / "lib/ride_diagnostics/ride_diagnostics_http.cpp").read_text()
BLE = (ROOT / "lib/ble_navigation/ble_navigation.cpp").read_text()
IOS = (
    ROOT.parent
    / "ios-app/BikeComputer/BikeComputer/Managers/DeviceDiagnosticsTransferManager.swift"
).read_text()


class TransferFailureContractTests(unittest.TestCase):
    def test_first_abort_is_copied_before_tls_teardown_and_kept_in_auth_status(self):
        abort = HTTP[
            HTTP.index("if (client.httpResponseWriteFailed()") :
            HTTP.index("if (handled) {", HTTP.index("if (client.httpResponseWriteFailed()"))
        ]
        self.assertLess(abort.index("client.failureRecord()"), abort.index("client.stop()"))
        self.assertLess(abort.index("lastTransferFailure_ = failure"), abort.index("client.stop()"))
        self.assertLess(abort.index("client.stop()"), abort.index("responseDidAbort(request)"))
        self.assertIn("result.lastTransferFailure = lastTransferFailure", HTTP)
        self.assertIn('appendFieldPrefix(body, "firstTransferFailure")', BLE)

    def test_first_write_failure_retains_raw_result_and_errno(self):
        write = TLS[TLS.index("size_t TransferClient::write(") : TLS.index("uint8_t TransferClient::connected()")]
        self.assertLess(write.index("const int writeErrno = errno"), write.index("noteFailure(TransferFailureReason::TlsWrite"))
        self.assertIn("lastRawTlsResult_ = result", write)
        self.assertIn("wantReadCalls_", write)
        self.assertIn("wantWriteCalls_", write)

    def test_file_error_is_sampled_before_close_and_positive_ferror_aborts(self):
        read = STORAGE[
            STORAGE.index("StorageReadEvidence Storage::readWithEvidence") :
            STORAGE.index("size_t Storage::read(FILE *file, char")
        ]
        self.assertLess(read.index("evidence.errorNumber = errno"), read.rindex("return evidence"))
        self.assertIn("ferror(file)", read)
        self.assertIn("feof(file)", read)
        send = DIAGNOSTICS[DIAGNOSTICS.index("bool sendFile(") : DIAGNOSTICS.index("bool resolveClosedChunk")]
        self.assertLess(send.index("client.noteFileRead("), send.index("storage.close(file);", send.index("client.noteFileRead(")))
        self.assertIn("fileReadFailed(count, read.error)", send)

    def test_ios_preserves_exact_prefix_and_never_imports_partial_chunk(self):
        request = IOS[IOS.index("nonisolated private enum DeviceDiagnosticsHTTPClient") : IOS.index("@MainActor\nprotocol DeviceDiagnosticsSessionControlling")]
        self.assertIn("receivedBytes: data.count", request)
        self.assertIn("expectedBytes: expectedLength", request)
        self.assertLess(request.index("for try await byte in bytes"), request.index("return data"))
        flow = IOS[IOS.index("func downloadDeviceLogs") : IOS.index("private func closeSession")]
        self.assertLess(flow.index("inspection.bytes == chunk.bytes"), flow.index("importDeviceChunkAsync("))
        self.assertLess(flow.index("inspection.sha256 == chunk.sha256.lowercased()"), flow.index("importDeviceChunkAsync("))


if __name__ == "__main__":
    unittest.main()
