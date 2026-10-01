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
#include "map_selection_health.hpp"
struct ActiveMapSelection { std::string sessionId, root, mapId; };
struct Status { bool ok = true; };
struct Installer {
  Status rollbackActiveMap(const std::string &) { return {}; }
  bool failRead = true;
  Status readActiveMap(ActiveMapSelection &selected) {
    if (failRead) throw std::bad_alloc();
    selected = {"old-session", "/maps/old", "old-map"}; return {};
  }
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
  std::string rollbackOperationID_, terminalOperationID_, terminalSessionID_, terminalMapID_;
  bool terminalAutomaticExit_ = false, terminalFailed_ = false;
  bool operationStatusNotification_ = false;
  bool rollbackAutomaticExit_ = false;
  bool rollbackSucceeded_ = false;
  bool rollbackComplete_ = false;
  ActiveMapSelection rollbackRestored_;
  map_transfer::MapSelectionHealth selectionHealth_;
  std::string selectionOperationID(const ActiveMapSelection &) { return "restored-op"; }
  Installer installer_;
  Activation activationState_;
  void lockState() {}
  void unlockState() {}
  void requestAutomaticExit() {}
  void releaseCommitGrant() {}
  void executeRollback();
};
'''
        fixture += method + r'''
int main() {
  MapTransferHttpServer server;
  server.selectionHealth_.select("/maps/new","installed-operation","new-map","new-session",true);
  server.selectionHealth_.degrade("/maps/new");
  server.selectionHealth_.beginRollback();
  server.executeRollback();
  if (!server.rollbackComplete_ || server.rollbackSucceeded_ ||
      server.selectionHealth_.state != "rollback_failed" ||
      server.selectionHealth_.affectedOperationID != "installed-operation") return 1;
  MapTransferHttpServer success;
  success.installer_.failRead = false;
  success.selectionHealth_.select("/maps/new","installed-operation","new-map","new-session",true);
  success.selectionHealth_.degrade("/maps/new");
  success.selectionHealth_.beginRollback();
  success.executeRollback();
  if (!success.rollbackComplete_ || !success.rollbackSucceeded_ ||
      success.selectionHealth_.state != "unknown" ||
      success.selectionHealth_.affectedOperationID != "installed-operation") return 2;
  if (success.selectionHealth_.acknowledge("/maps/new",true)) return 3;
  if (!success.selectionHealth_.acknowledge("/maps/old",true) ||
      success.selectionHealth_.state != "ready" ||
      success.selectionHealth_.operationID != "restored-op") return 4;
  return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="rollback-failure-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "lib/map_transfer"), str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            result = subprocess.run([str(path / "test")])
            self.assertEqual(result.returncode, 0,
                             "allocation failure after rollback cannot publish restoration success")


if __name__ == "__main__":
    unittest.main()
