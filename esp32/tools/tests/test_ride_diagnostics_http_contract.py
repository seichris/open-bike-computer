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
        dispatch = handler.index("http_policy::parseRoute")
        non_exit = handler.index(
            "route.kind != http_policy::RouteKind::Exit", dispatch
        )
        unknown = handler.index(
            "route.kind == http_policy::RouteKind::Unknown", dispatch
        )
        self.assertLess(gate, dispatch)
        self.assertLess(mode, dispatch)
        self.assertLess(non_exit, unknown)
        self.assertIn("http_policy::parseRoute", handler)
        for route in ("Status", "Index", "Chunk", "ActiveTail", "Exit"):
            self.assertIn(f"http_policy::RouteKind::{route}", handler)

    def test_index_and_chunk_routes_use_snapshot_and_exact_bytes(self):
        index = HTTP[
            HTTP.index("http_policy::RouteKind::Index") :
            HTTP.index("http_policy::RouteKind::Chunk")
        ]
        self.assertIn("beginTransferSnapshotLease()", index)
        self.assertIn("endTransferSnapshotLease()", index)
        self.assertIn("listChunks(server_, request)", index)
        self.assertIn("kMaximumIndexBytes", index)
        self.assertIn("snapshot.dropped", index)
        self.assertIn("diagnostics_index_unreadable", index)
        self.assertIn("index.readable", index)

        chunk = HTTP[
            HTTP.index("http_policy::RouteKind::Chunk") :
            HTTP.index("http_policy::RouteKind::ActiveTail")
        ]
        self.assertIn("resolveClosedChunk", chunk)
        self.assertIn("sendFile(client, chunk, server_, request)", chunk)
        self.assertIn("sent == chunk.bytes", HTTP)
        self.assertIn("storage.hasError(file)", HTTP)

    def test_zero_byte_crash_artifacts_are_ignored_but_read_errors_fail_closed(self):
        self.assertIn("CandidateDisposition::IgnoreEmpty", HTTP)
        self.assertIn("CandidateDisposition::Reject", HTTP)
        self.assertIn("index.readable = false", HTTP)

    def test_exit_is_deferred_until_clean_response(self):
        self.assertIn("exitAfterResponse_ = true", HTTP)
        self.assertIn("peerClosedCleanly", HTTP)
        self.assertIn("server_->setEnabled(false)", HTTP)
        self.assertIn("bool handleRequest", HEADER)


if __name__ == "__main__":
    unittest.main()
