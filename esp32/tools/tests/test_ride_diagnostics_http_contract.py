from pathlib import Path
import re
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
        self.assertIn("diagnostics_index_unreadable", index)
        self.assertIn("index.readable", index)
        self.assertIn("sendIndex(client, index, snapshot", index)

        streamed_index = HTTP[
            HTTP.index("bool sendIndex") :
            HTTP.index("bool sendFile")
        ]
        header = streamed_index.index("sendHttpHead")
        first_hash = streamed_index.index("sha256File(chunk.path")
        first_body = streamed_index.index("writeBodySegment(client, prefix)")
        self.assertLess(header, first_hash)
        self.assertLess(first_body, first_hash)
        self.assertIn("contentLength > kMaximumIndexBytes", streamed_index)
        self.assertIn("indexHashProgressCharacters", streamed_index)
        self.assertIn("snapshot.dropped", streamed_index)
        self.assertIn("bytes != chunk.bytes", streamed_index)
        self.assertIn("endTransferSnapshotLease()", streamed_index)

        hasher = HTTP[
            HTTP.index("bool sha256File") :
            HTTP.index("std::size_t indexHashProgressCharacters")
        ]
        self.assertIn("kIndexHashProgressBytes", hasher)
        self.assertIn("bytes == expectedBytes", hasher)
        self.assertIn("writeHttpBytes(client, &progress, 1)", hasher)
        self.assertIn("while (bytes < expectedBytes)", hasher)
        self.assertIn("expectedBytes - bytes", hasher)
        self.assertNotIn("while (true)", hasher)

        chunk = HTTP[
            HTTP.index("http_policy::RouteKind::Chunk") :
            HTTP.index("http_policy::RouteKind::ActiveTail")
        ]
        self.assertIn("resolveClosedChunk", chunk)
        self.assertIn("sendFile(client, chunk, server_, request)", chunk)
        self.assertIn("sent != chunk.bytes || closeResult != 0", HTTP)
        self.assertIn("readWithEvidence", HTTP)
        self.assertIn("read.error", HTTP)

    def test_zero_byte_crash_artifacts_are_ignored_but_read_errors_fail_closed(self):
        self.assertIn("CandidateDisposition::IgnoreEmpty", HTTP)
        self.assertIn("CandidateDisposition::Reject", HTTP)
        self.assertIn("index.readable = false", HTTP)

    def test_ffat_storage_steps_never_run_on_the_psram_worker(self):
        # FFat reads disable the flash cache, so the worker hands each step to
        # the transfer owner's internal stack. Removable SD stays direct.
        helper = HTTP[HTTP.index("bool runStorageCall(") : HTTP.index("int closeFile(")]
        self.assertIn("storage.hasInternalFallbackMounted()", helper)
        self.assertIn("esp_ptr_internal(&stackMarker)", helper)
        self.assertIn("http_policy::runStorageCall(", helper)
        self.assertIn("server->runOnInternalStack(dispatched, dispatchedContext)", helper)
        # Each step is a thin thunk into the one shared placement function.
        self.assertIn("(*static_cast<Step *>(context))();", helper)

        # These two scan whole directories. Each has exactly one caller, a step.
        scans = []
        for name, call, step in (
            ("listChunks", "index = listChunks(server_, request);", "listStep"),
            ("resolveClosedChunk",
             "resolved = resolveClosedChunk(route.boot, route.chunk, chunk);",
             "resolveStep"),
        ):
            self.assertEqual(HTTP.count(name + "("), 2, name)
            call_at = HTTP.index(call)
            step_at = HTTP.rindex("auto " + step + " = [&] {", 0, call_at)
            self.assertLess(call_at, HTTP.index("};", step_at))
            self.assertIn("runStorage(server_, " + step + ")", HTTP[call_at:])
            start = HTTP.index(" " + name + "(")
            scans.append((start, HTTP.index("\n}\n", start)))

        primitives = re.compile(
            r"storage\.(?:open|read|readWithEvidence|close|size|exists|write|"
            r"flush|sync|seek|remove|mkdir|rmdir)\(|opendir\(|readdir\(|"
            r"closedir\(|::stat\(|catalog_v2::read\(")
        steps = 0
        for match in primitives.finditer(HTTP):
            at = match.start()
            if any(start <= at < end for start, end in scans):
                continue
            # Any other file-system call sits in a step lambda that is run
            # through runStorage, never directly on the worker.
            opening = HTTP.rindex(" = [&] {", 0, at)
            self.assertLess(at, HTTP.index("};", opening), match.group(0))
            step = HTTP[HTTP.rindex("auto ", 0, opening) + 5 : opening]
            self.assertRegex(HTTP[opening:], r"runStorage\(server_?, " + step + r"\)")
            steps += 1
        self.assertGreaterEqual(steps, 5)

    def test_exit_is_deferred_until_clean_response(self):
        self.assertIn("exitAfterResponse_ = true", HTTP)
        self.assertIn("peerClosedCleanly", HTTP)
        self.assertIn("server_->setEnabled(false)", HTTP)
        self.assertIn("bool handleRequest", HEADER)


if __name__ == "__main__":
    unittest.main()
