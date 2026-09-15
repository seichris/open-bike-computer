"""Execute the production rollback callback with a failing storage boundary."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeRollbackFailureTests(unittest.TestCase):
    def test_post_rollback_read_allocation_failure_is_not_success(self):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler, "C++ host compiler is required")
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        start = source.index("void MapTransferHttpServer::executeRollback()")
        end = source.index("\nbool MapTransferHttpServer::takeAutomaticExitRequest", start)
        method = source[start:end]
        fixture = r'''
#include <string>
#include <new>
#include <utility>
struct ActiveMapSelection { std::string sessionId; };
struct Status { bool ok = true; };
struct Installer {
  Status rollbackActiveMap(const std::string &) { return {}; }
  Status readActiveMap(ActiveMapSelection &) { throw std::bad_alloc(); }
};
struct Activation {
  void finish(std::string, std::string, std::string, std::string) {}
};
struct SerialStub {
  void println(const char *) {}
  template<class... Args> void printf(const char *, Args...) {}
} Serial;
namespace ui_scheduler {
enum class WakeReason { Transfer };
void notify(WakeReason) {}
}
class MapTransferHttpServer {
public:
  enum class RollbackKind { None, Runtime, Transfer };
  RollbackKind rollbackKind_ = RollbackKind::Runtime;
  std::string rollbackSession_ = "already-selected";
  bool rollbackAutomaticExit_ = false;
  bool rollbackSucceeded_ = false;
  bool rollbackComplete_ = false;
  ActiveMapSelection rollbackRestored_;
  Installer installer_;
  Activation activationState_;
  void lockState() {}
  void unlockState() {}
  void requestAutomaticExit() {}
  void executeRollback();
};
'''
        fixture += method + r'''
int main() {
  MapTransferHttpServer server;
  server.executeRollback();
  return server.rollbackComplete_ && !server.rollbackSucceeded_ ? 0 : 1;
}
'''
        with tempfile.TemporaryDirectory(prefix="rollback-failure-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            result = subprocess.run([str(path / "test")])
            self.assertEqual(result.returncode, 0,
                             "allocation failure after rollback cannot publish restoration success")


if __name__ == "__main__":
    unittest.main()
