"""Execute production failed-finalization disposition with a real durable ledger."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def method(source, name):
    start = source.index("bool MapTransferHttpServer::" + name + "(")
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


class MapCommitRecoveryTests(unittest.TestCase):
    def test_post_grant_errors_cannot_reuse_response_without_callback(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        body = method(source, "handleInstallStream")
        grant = body.index("pendingCommitGrant_ = grant")
        closed = body.index("client.requestHttpResponseClose()", grant)
        self.assertLess(closed, body.index("receiver->finish()", grant))
        self.assertLess(body.index("CommitRecovery recovery;"),
                        body.index("beginAuthorizedCommit("))
        control = method(source, "handleOperationControl")
        self.assertLess(control.index("client.requestHttpResponseClose()"), control.index("store.accept(record.identity)"))

    def test_actual_activation_failure_rearms_reserved_disposition(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        retry = source[source.index("void MapTransferHttpServer::retryAcceptedActivation("):
                       source.index("bool MapTransferHttpServer::recoverCommitDisposition(")]
        execute = source[source.index("void MapTransferHttpServer::executeActivation("):
                         source.index("bool MapTransferHttpServer::runStreamActivationTask(")]
        fixture = r'''
#include <cassert>
#include <new>
#include <string>
namespace power_management {
enum class LockDomain { Transfer };
struct ScopedLock { explicit ScopedLock(LockDomain) {} };
}
namespace ui_scheduler { enum class WakeReason { Transfer }; void notify(WakeReason) {} }
class MapTransferHttpServer {
public:
  struct StateGuard { explicit StateGuard(MapTransferHttpServer &) {} };
  struct Recovery {
    struct Identity { std::string session; } identity;
    bool armed=false, responseCompleted=true;
    bool pending() const { return !identity.session.empty(); }
  } commitRecovery_;
  bool pendingRendererAcknowledgement_=false;
  bool grantOwned=true, automaticExit=false;
  int outcome=0, runs=0;
  bool runStreamActivationTask(const std::string &, bool) {
    ++runs;
    if(outcome==2) throw std::bad_alloc();
    if(outcome==1) {pendingRendererAcknowledgement_=true;return true;}
    return false;
  }
  void requestAutomaticExit() {automaticExit=true;}
  void retryAcceptedActivation(const std::string &);
  void executeActivation(const std::string &, bool);
};
''' + retry + execute + r'''
int main() {
  for(int outcome: {0,2}) {
    MapTransferHttpServer server;
    server.commitRecovery_.identity.session="accepted-session";
    server.outcome=outcome;
    server.executeActivation("accepted-session",true);
    assert(server.grantOwned && server.commitRecovery_.armed && !server.automaticExit);
    assert(server.commitRecovery_.identity.session=="accepted-session");
    // Actual recovery may now retry; eventual renderer handoff retires the
    // dormant disposition while retaining the grant for its ACK/receipt.
    server.outcome=1;
    server.executeActivation("accepted-session",true);
    assert(server.runs==2 && server.pendingRendererAcknowledgement_);
    assert(!server.commitRecovery_.pending() && server.grantOwned && !server.automaticExit);
  }
  MapTransferHttpServer stale;
  stale.commitRecovery_.identity.session="new-session";
  stale.executeActivation("old-session",true);
  assert(!stale.commitRecovery_.armed && stale.commitRecovery_.identity.session=="new-session");
  stale.pendingRendererAcknowledgement_=true;
  stale.retryAcceptedActivation("new-session");
  assert(!stale.commitRecovery_.armed); // never race an outstanding renderer ACK
}
'''
        with tempfile.TemporaryDirectory(prefix="activation-disposition-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)

    def test_new_operation_same_content_gets_fresh_renderer_handoff(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        body = source[source.index("void MapTransferHttpServer::beginDeferredActivation("):
                      source.index("void MapTransferHttpServer::ownedActivation(")]
        fixture = r'''
#include <cassert>
#include <new>
#include <string>
using esp_err_t=int;
constexpr int ESP_OK=0, ESP_ERR_INVALID_STATE=1, ESP_ERR_TIMEOUT=2;
enum class ActivationBeginResult {Started, AlreadyInstalled, Busy};
struct Progress {int a,b,c,d;};
struct ActivationState {
  bool installed=true; unsigned begins=0;
  ActivationBeginResult begin(const std::string &,int,unsigned) {
    ++begins; return installed?ActivationBeginResult::AlreadyInstalled:ActivationBeginResult::Started;
  }
  void finish(const char *,const char *,const char *,const char *) {installed=false;}
  void updateProgress(Progress) {}
};
struct Transfer {void sampleResources(const char *) {}};
using Work=void (*)(void *,const char *,bool);
struct Owner {
  Work called=nullptr; int result=ESP_OK;
  int runMapActivation(Work work,void *,const std::string &,bool) {called=work;return result;}
};
class MapTransferHttpServer {
public:
  struct StateGuard {explicit StateGuard(MapTransferHttpServer &) {}};
  struct DeferredActivation {std::string sessionId; unsigned minimumSequence=0;};
  struct {struct {std::string operation;} identity;} commitRecovery_;
  ActivationState activationState_; bool streamStatusActive_=true; unsigned retries=0;
  Transfer transfer; Transfer *transferServer_=&transfer;
  Owner owner; Owner *operationOwner_=&owner;
  static void ownedActivation(void *,const char *,bool) {}
  static void ownedInstalledCleanup(void *,const char *,bool) {}
  void retryAcceptedActivation(const std::string &) {++retries;}
  void finishActivation(const char *,const char *,const char *,const char *) {}
  void setLastError(const char *,const char *) {}
  void beginDeferredActivation(const DeferredActivation &,bool);
};
''' + body + r'''
int main() {
  MapTransferHttpServer fresh;
  fresh.commitRecovery_.identity.operation="new-logical-operation";
  fresh.beginDeferredActivation({"same-content",4},true);
  assert(fresh.owner.called==MapTransferHttpServer::ownedActivation);
  assert(fresh.activationState_.begins==2 && !fresh.streamStatusActive_);
  MapTransferHttpServer legacy;
  legacy.beginDeferredActivation({"same-content",4},true);
  assert(legacy.owner.called==MapTransferHttpServer::ownedInstalledCleanup);
  legacy.owner.result=ESP_ERR_INVALID_STATE;
  legacy.beginDeferredActivation({"same-content",4},true);
  assert(legacy.retries==1);
  legacy.owner.result=ESP_ERR_TIMEOUT;
  legacy.beginDeferredActivation({"same-content",4},true);
  assert(legacy.retries==1); // late live owner cannot race storage retry
}
'''
        with tempfile.TemporaryDirectory(prefix="activation-reinstall-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)

    def test_storage_disposition_retains_unknown_and_resolves_known(self):
        compiler = shutil.which("c++")
        self.assertIsNotNone(compiler)
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        fixture = r'''
#include <cassert>
#include <string>
#include <vector>
#include "durable_operation.hpp"
namespace operation = device_transfer::durable_operation;
struct MapOperationStorage : operation::Storage {
  static std::vector<uint8_t> slots[2];
  static bool failRead, failWrite;
  MapOperationStorage(const std::string &) {}
  bool read(unsigned slot, std::vector<uint8_t> &out) override {
    if (failRead) return false;
    out = slots[slot]; return true;
  }
  bool writeDurable(unsigned slot, const std::vector<uint8_t> &in) override {
    if (failWrite) return false;
    slots[slot] = in; return true;
  }
};
std::vector<uint8_t> MapOperationStorage::slots[2];
bool MapOperationStorage::failRead = false;
bool MapOperationStorage::failWrite = false;
struct Status { bool ok; std::string code; Status(bool value, std::string reason="") : ok(value), code(reason) {} };
struct ReadyStreamMap {
  std::string operationID, mapId, manifestReceipt, signedManifestReceipt;
};
struct Installer {
  bool ready = false, discardable = true, discarded = false;
  ReadyStreamMap marker;
  Status readReadyStreamMap(const std::string &, ReadyStreamMap &out) {
    out = marker; return {ready};
  }
  Status promotePreparedOperation(const std::string &, const std::string &) {
    return {ready, ready ? "ok" : "stream_ready_invalid"};
  }
  Status discardUnselectedStreamMap(const std::string &) {
    discarded = discardable; return {discardable};
  }
};
enum class ActivationBeginResult { Started, Busy, AlreadyInstalled };
struct Activation {
  ActivationBeginResult begin(const std::string &, int) { return ActivationBeginResult::Started; }
};
class MapTransferHttpServer {
public:
  struct CommitRecovery { operation::Identity identity; };
  struct StateGuard { StateGuard(MapTransferHttpServer &) {} };
  struct OperationStoreGuard { OperationStoreGuard(MapTransferHttpServer &) {} };
  std::string storageRoot_ = "/sdcard", operationDeviceID_ = std::string(32, 'a');
  Installer installer_;
  Activation activationState_;
  bool streamStatusActive_ = true, released = false, dispatched = false, finished = false;
  bool storageAvailable = true;
  bool refreshStreamStorageCapability(bool) { return storageAvailable; }
  bool observeOperationRevision(uint64_t) { return true; }
  bool runStreamActivationTask(const std::string &, bool) { dispatched = true; return true; }
  void finishActivation(const char *, const std::string &, const char *, const char *) { finished = true; }
  void releaseCommitGrant() { released = true; }
  bool recoverCommitDisposition(const CommitRecovery &);
};
'''
        fixture += method(source, "recoverCommitDisposition")
        fixture += r'''
int main() {
  const operation::Identity id{std::string(32,'a'), std::string(32,'b'),
      std::string(64,'c'), std::string(64,'d'), std::string(64,'e'), 100, "session", "map"};
  for (int scenario = 0; scenario != 8; ++scenario) {
    MapOperationStorage::slots[0].clear(); MapOperationStorage::slots[1].clear();
    MapOperationStorage::failRead = MapOperationStorage::failWrite = false;
    MapOperationStorage storage(""); operation::Store store(storage, id.device);
    assert(store.restore() == operation::Result::Ok);
    assert(store.initializeAdmission(123) == operation::Result::Ok);
    if (scenario != 0) {
      assert(store.admit(id, store.admissionRevision()) == operation::Result::Ok);
      if (scenario != 1) {
        assert(store.prepare(id) == operation::Result::Ok);
        assert(store.accept(id) == operation::Result::Ok);
      }
    }
    MapTransferHttpServer server;
    server.installer_.marker = {id.operation, id.map, id.manifest, id.signedManifest};
    server.storageAvailable = scenario != 7;
    server.installer_.ready = scenario == 3;
    server.installer_.discardable = scenario != 4;
    MapOperationStorage::failRead = scenario == 5;
    MapOperationStorage::failWrite = scenario == 6;
    const bool resolved = server.recoverCommitDisposition({id});
    if (scenario <= 2) {
      assert(resolved && server.released && server.finished && server.installer_.discarded);
      if (scenario != 0) {
        assert(store.restore() == operation::Result::Ok);
        operation::Record record;
        assert(store.query(id, record) == operation::Result::Ok);
        assert(record.phase == operation::Phase::Failed);
      }
    } else if (scenario == 3) {
      assert(resolved && server.dispatched && !server.released && !server.installer_.discarded);
    } else {
      assert(!resolved && !server.released && !server.finished);
    }
  }
}
'''
        with tempfile.TemporaryDirectory(prefix="map-recovery-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            "-I" + str(ROOT / "lib/device_transfer"),
                            str(path / "test.cpp"), str(ROOT / "lib/device_transfer/durable_operation.cpp"),
                            "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
