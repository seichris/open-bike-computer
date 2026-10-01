"""Execute production response callbacks at deterministic transport barriers."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def method(source, name):
    start = source.index("void MapTransferHttpServer::" + name + "(")
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("unclosed method")


class MapCommitCallbackTests(unittest.TestCase):
    def test_abort_complete_duplicate_and_late_request_callbacks(self):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler)
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        fixture = r'''
#include <cassert>
#include <string>
#include <utility>
#include "device_transfer_http_limits.hpp"
#include "commit_boundary_policy.hpp"
namespace device_transfer {
struct HttpRequest {
  uint32_t transferGeneration;
  std::string method;
  std::string path;
  uint64_t requestSequence;
};
}
struct SerialStub {
  template<class... Args> void printf(const char *, Args...) {}
} Serial;
class MapTransferHttpServer {
public:
  struct DeferredActivation {
    device_transfer::HttpResponseCompletionToken response;
    std::string sessionId;
    uint32_t minimumSequence = 0;
    bool pending() const { return !sessionId.empty(); }
  };
  DeferredActivation deferredActivation_;
  device_transfer::commit_boundary_policy::Boundary boundary;
  unsigned dispatched = 0;
  bool automaticExit = false;
  void lockState() {}
  void unlockState() {}
  void beginDeferredActivation(const DeferredActivation &, bool peerClosed) {
    assert(boundary.active());
    ++dispatched;
    automaticExit = peerClosed;
  }
  void responseDidComplete(const device_transfer::HttpRequest &, bool);
  void responseDidAbort(const device_transfer::HttpRequest &);
};
'''
        fixture += method(source, "responseDidComplete")
        fixture += method(source, "responseDidAbort")
        fixture += r'''
int main() {
  const device_transfer::HttpRequest first{7, "PUT", "/map/one", 11};
  const device_transfer::HttpRequest later{7, "PUT", "/map/one", 12};
  for (int outcome = 0; outcome != 3; ++outcome) {
    MapTransferHttpServer server;
    const auto grant = server.boundary.begin(true, true, true, "/map/one", "signed");
    server.deferredActivation_ = {{7, "PUT", "/map/one", 11}, "one", 2};
    // Revocation / shutdown after grant must not affect callback ownership.
    server.boundary.closeAdmission(true);
    if (outcome == 0) server.responseDidAbort(first); // enqueue / write failure
    else server.responseDidComplete(first, outcome == 1); // clean / lost close
    assert(server.dispatched == 1);
    assert(server.automaticExit == (outcome == 1));
    assert(server.boundary.owns(grant)); // receipt delivery is not renderer ACK
    server.responseDidAbort(first);
    server.responseDidComplete(first, true);
    assert(server.dispatched == 1);
    assert(server.boundary.end(grant));
    server.boundary.closeAdmission(false);
    const auto next = server.boundary.begin(true, true, true, "/map/one", "signed");
    server.deferredActivation_ = {{7, "PUT", "/map/one", 12}, "one", 3};
    server.responseDidAbort(first); // same generation/path, stale request
    server.responseDidComplete(first, true);
    assert(server.dispatched == 1 && server.deferredActivation_.pending());
    server.responseDidAbort(later);
    assert(server.dispatched == 2 && !server.deferredActivation_.pending());
    assert(server.boundary.owns(next));
  }
}
'''
        with tempfile.TemporaryDirectory(prefix="map-callback-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I" + str(ROOT / "lib/device_transfer"),
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
