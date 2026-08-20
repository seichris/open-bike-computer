from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
HTTP = (ROOT / "lib/ride_diagnostics/ride_diagnostics_http.cpp").read_text(
    encoding="utf-8"
)
HEADER = (ROOT / "lib/ride_diagnostics/ride_diagnostics_http.hpp").read_text(
    encoding="utf-8"
)


class RideDiagnosticsHttpContractTests(unittest.TestCase):
    def test_routes_are_authenticated_and_mode_bound(self):
        handler = HTTP[
            HTTP.index("bool RideDiagnosticsHttp::handleRequest") :
            HTTP.index("void RideDiagnosticsHttp::responseDidComplete")
        ]
        gate = handler.index("server_->isRequestAuthorized(request)")
        mode = handler.index('server_->status().mode != "diagnostics"')
        self.assertLess(gate, handler.index('kPrefix) + "status"'))
        self.assertLess(mode, handler.index('kPrefix) + "status"'))
        for route in ("status", "index", "chunks/", "active-tail", "session/exit"):
            self.assertIn(f'kPrefix) + "{route}', handler)

    def test_index_and_chunk_routes_use_snapshot_and_exact_bytes(self):
        index = HTTP[
            HTTP.index('kPrefix) + "index"') :
            HTTP.index("const std::string chunkPrefix")
        ]
        self.assertIn("beginTransferSnapshotLease()", index)
        self.assertIn("endTransferSnapshotLease()", index)
        self.assertIn("listChunks(server_, request)", index)
        self.assertIn("kMaximumIndexBytes", index)
        self.assertIn("snapshot.dropped", index)

        chunk = HTTP[
            HTTP.index("const std::string chunkPrefix") :
            HTTP.index('kPrefix) + "active-tail"')
        ]
        self.assertIn("resolveClosedChunk", chunk)
        self.assertIn("sendFile(client, chunk, server_, request)", chunk)
        self.assertIn("sent == chunk.bytes", HTTP)
        self.assertIn("storage.hasError(file)", HTTP)

    def test_exit_is_deferred_until_clean_response(self):
        self.assertIn("exitAfterResponse_ = true", HTTP)
        self.assertIn("peerClosedCleanly", HTTP)
        self.assertIn("server_->setEnabled(false)", HTTP)
        self.assertIn("bool handleRequest", HEADER)


if __name__ == "__main__":
    unittest.main()
