"""Execute production failed-finalization disposition with a real durable ledger."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Start of the bounded retry constants and helpers in map_transfer_http.cpp.
RETRY_POLICY = "namespace {\n// Accepted work gets this many activation attempts"
# Fixtures that include the constants reference each one; clang rejects unused ones.
USES_RETRY_POLICY = (
    "\nstatic_assert(kCommitRecoveryAttempts == 3 && "
    "kCommitRecoveryBackoffMs < kCommitRecoveryMaximumBackoffMs, \"retry policy\");\n")


# recoverCommitDisposition returns a nested type, declared on its own line.
RECOVER = ("MapTransferHttpServer::CommitRecoveryResult\n"
           "MapTransferHttpServer::recoverCommitDisposition(")


def method(source, name, returns="bool "):
    start = source.index(returns + "MapTransferHttpServer::" + name + "(")
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
        retry = source[source.index(RETRY_POLICY):source.index(RECOVER)]
        execute = source[source.index("void MapTransferHttpServer::executeActivation("):
                         source.index("bool MapTransferHttpServer::runStreamActivationTask(")]
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <new>
#include <string>
uint32_t millis() { return 0; }
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
    uint8_t failures=0; uint32_t retryAfterMs=0;
    bool pending() const { return !identity.session.empty(); }
  } commitRecovery_;
  void scheduleCommitRecoveryRetry();
  void deferCommitRecoveryRetry();
  bool commitRecoveryDue() const;
  bool pendingRendererAcknowledgement_=false;
  bool grantOwned=true, automaticExit=false;
  struct Activation {
    std::string session="accepted-session", status="activating", code;
    bool running=true;
    bool runningFor(const std::string &id) const { return running && session==id; }
    void finish(std::string state, std::string, std::string error, std::string) {
      running=false; status=state; code=error;
    }
  } activationState_;
  int outcome=0, runs=0;
  std::string firstOwnerCode;
  void rememberOwnerRecovery(const char *code) { if(firstOwnerCode.empty()) firstOwnerCode=code; }
  bool runStreamActivationTask(const std::string &, bool, bool owner) {
    assert(owner);
    ++runs;
    if(outcome==2) throw std::bad_alloc();
    if(outcome==1) {pendingRendererAcknowledgement_=true;return true;}
    return false;
  }
  void requestAutomaticExit() {automaticExit=true;}
  void retryAcceptedActivation(const std::string &);
  void executeActivation(const std::string &, bool);
  void finishUnwoundActivation(const std::string &) noexcept;
};
''' + retry + execute + USES_RETRY_POLICY + r'''
int main() {
  for(int outcome: {0,2}) {
    MapTransferHttpServer server;
    server.commitRecovery_.identity.session="accepted-session";
    server.outcome=outcome;
    server.executeActivation("accepted-session",true);
    assert(server.grantOwned && server.commitRecovery_.armed && !server.automaticExit);
    if(outcome==2) {
      assert(server.firstOwnerCode=="out_of_memory");
      // Left marked running, the unwound attempt would hold off every
      // storage-worker retry for its session.
      assert(!server.activationState_.running);
      assert(server.activationState_.status=="recovering" &&
             server.activationState_.code=="out_of_memory");
    }
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
  // An unwound attempt releases only its own session, and never a renderer
  // handoff that is still pending.
  MapTransferHttpServer other;
  other.commitRecovery_.identity.session="accepted-session";
  other.activationState_.session="other-session";
  other.outcome=2;
  other.executeActivation("accepted-session",true);
  assert(other.activationState_.running && other.commitRecovery_.armed);
  MapTransferHttpServer handoff;
  handoff.commitRecovery_.identity.session="accepted-session";
  handoff.pendingRendererAcknowledgement_=true;
  handoff.outcome=2;
  handoff.executeActivation("accepted-session",true);
  assert(handoff.activationState_.running && !handoff.commitRecovery_.armed);
}
'''
        with tempfile.TemporaryDirectory(prefix="activation-disposition-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)

    def test_each_failed_attempt_is_counted_once(self):
        # A storage-worker attempt runs the activation directly and never
        # re-arms, so executeOperationTask schedules its one retry. Only owner
        # and boot attempts re-arm through retryAcceptedActivation, and those
        # never run inside the storage worker's disposition.
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        run = source[source.index("bool MapTransferHttpServer::runStreamActivationTask("):
                     source.index("void MapTransferHttpServer::activationTaskThunk(")]
        self.assertNotIn("retryAcceptedActivation(", run)
        recover = method(source, "recoverCommitDisposition",
                         returns="MapTransferHttpServer::CommitRecoveryResult\n")
        self.assertIn("runStreamActivationTask(identity.session, false)", recover)
        self.assertNotIn("executeActivation(", recover)
        self.assertNotIn("retryAcceptedActivation(", recover)
        # Boot resume re-arms only when its dedicated task was never created.
        # The task is not an owner dispatch, so false cannot mean a timed-out
        # activation that is still running.
        start = source[source.index("bool MapTransferHttpServer::startActivationTask("):
                       source.index("bool MapTransferHttpServer::deferActivationUntilResponse(")]
        self.assertNotIn("runMapActivation(", start)
        created = start.index("xTaskCreate(activationTaskThunk")
        self.assertLess(start.index("new ActivationTaskContext"), created)
        self.assertEqual(start.count("return true;"), 1)
        self.assertLess(start.index("if (created != pdPASS) {"), start.index("return true;"))

    def test_failed_attempts_back_off_before_the_storage_worker_retries(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        retry = source[source.index(RETRY_POLICY):source.index(RECOVER)]
        submit = source[source.index("void MapTransferHttpServer::submitPendingOperationTask()"):
                        source.index("void MapTransferHttpServer::operationTask(")]
        fixture = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <string>
uint32_t clockMs = 1000;
uint32_t millis() { return clockMs; }
namespace ui_scheduler { enum class WakeReason { Transfer }; void notify(WakeReason) {} }
class MapTransferHttpServer {
public:
  struct StateGuard { explicit StateGuard(MapTransferHttpServer &) {} };
  struct Recovery {
    struct Identity { std::string session; } identity;
    bool armed = false, responseCompleted = false;
    uint8_t failures = 0; uint32_t retryAfterMs = 0;
    bool pending() const { return !identity.session.empty(); }
  } commitRecovery_;
  bool pendingRendererAcknowledgement_ = false, operationTaskSubmitted_ = false;
  std::string operationQuery_, terminalOperationID_;
  bool (*storageControlSubmit_)(void (*)(void *), void *) =
      [](void (*)(void *), void *) { return true; };
  static void operationTask(void *) {}
  void lockState() {}
  void unlockState() {}
  void scheduleCommitRecoveryRetry();
  void deferCommitRecoveryRetry();
  bool commitRecoveryDue() const;
  void retryAcceptedActivation(const std::string &);
  void submitPendingOperationTask();
};
''' + retry + submit + USES_RETRY_POLICY + r'''
void expectRetryAfter(MapTransferHttpServer &server, uint32_t wait) {
  server.operationTaskSubmitted_ = false;
  server.retryAcceptedActivation("accepted");
  assert(server.commitRecovery_.armed);
  // The storage worker is not resubmitted before the backoff expires.
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_);
  clockMs += wait - 1;
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_);
  clockMs += 1;
  server.submitPendingOperationTask();
  assert(server.operationTaskSubmitted_);
}
int main() {
  MapTransferHttpServer server;
  server.commitRecovery_.identity.session = "accepted";
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_); // Reserved but not armed.
  for (uint32_t wait : {5000U, 10000U, 20000U, 40000U, 60000U, 60000U})
    expectRetryAfter(server, wait);
  assert(server.commitRecovery_.failures == 6);
  // The deadline stays correct across the millis() wrap.
  clockMs = UINT32_MAX - 1000U;
  expectRetryAfter(server, 60000U);
  // Another session's failure, or one racing an outstanding renderer ACK,
  // schedules nothing.
  const uint8_t failures = server.commitRecovery_.failures;
  server.retryAcceptedActivation("other");
  server.pendingRendererAcknowledgement_ = true;
  server.retryAcceptedActivation("accepted");
  assert(server.commitRecovery_.failures == failures);
  // Waiting for this session's running attempt spends no attempt and checks
  // again after the first interval, whatever the failure count.
  server.operationTaskSubmitted_ = false;
  server.deferCommitRecoveryRetry();
  assert(server.commitRecovery_.failures == failures);
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_);
  clockMs += 4999U;
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_);
  clockMs += 1U;
  server.submitPendingOperationTask();
  assert(server.operationTaskSubmitted_);
  // Queries and terminal receipts are never held back by the backoff.
  server.pendingRendererAcknowledgement_ = false;
  server.retryAcceptedActivation("accepted");
  server.operationTaskSubmitted_ = false;
  server.operationQuery_ = "query";
  server.submitPendingOperationTask();
  assert(server.operationTaskSubmitted_);
}
'''
        with tempfile.TemporaryDirectory(prefix="activation-backoff-") as temporary:
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
  void rememberOwnerRecovery(const char *) {}
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
#include <new>
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
struct Status {
  bool ok; std::string code;
  Status(bool value, std::string reason = "", std::string = "") : ok(value), code(reason) {}
};
using InstallStatus = Status;
struct ReadyStreamMap {
  std::string operationID, mapId, manifestReceipt, signedManifestReceipt;
};
struct Installer {
  bool ready = false, discardable = true, discarded = false;
  std::string discardCode = "stream_discard_cleanup";
  ReadyStreamMap marker;
  int calls = 0;
  Status readReadyStreamMap(const std::string &, ReadyStreamMap &out) {
    ++calls; out = marker; return {ready};
  }
  Status promotePreparedOperation(const std::string &, const std::string &) {
    ++calls; return {ready, ready ? "ok" : "stream_ready_invalid"};
  }
  Status discardUnselectedStreamMap(const std::string &) {
    ++calls; discarded = discardable; return {discardable, discardable ? "stream_superseded" : discardCode};
  }
  bool keepable = false, kept = false;
  Status keepSelectedStreamMap(const std::string &) {
    ++calls; kept = keepable; return {keepable, keepable ? "library_kept" : "stream_keep_unverified"};
  }
};
enum class ActivationBeginResult { Started, AlreadyRunning, AlreadyInstalled, Busy };
struct Progress { unsigned step, totalSteps; uint64_t completed, total; };
// MapActivationState's begin/finish/progress rules for one session.
struct Activation {
  unsigned step = 1, begins = 0;
  bool running = false, installed = false, otherRunning = false, startsBeforeBegin = false;
  std::string status = "idle", session = "session";
  bool runningFor(const std::string &id) const { return running && id == session; }
  ActivationBeginResult begin(const std::string &id, int) {
    ++begins;
    if (startsBeforeBegin) running = true; // An attempt began after the first check.
    if (running) return id == session ? ActivationBeginResult::AlreadyRunning
                                      : ActivationBeginResult::Busy;
    if (otherRunning) return ActivationBeginResult::Busy;
    if (installed) return ActivationBeginResult::AlreadyInstalled;
    running = true; step = 1; status = "activating";
    return ActivationBeginResult::Started;
  }
  void finish(const char *state, const char *, const char *, const char *) {
    running = false; status = state; installed = status == "installed";
  }
  void updateProgress(const Progress &progress) { if (running) step = progress.step; }
};
class MapTransferHttpServer {
public:
  struct CommitRecovery { operation::Identity identity; uint8_t failures = 0; };
  enum class CommitRecoveryResult { Completed, Failed, Deferred };
  struct StateGuard { StateGuard(MapTransferHttpServer &) {} };
  struct OperationStoreGuard { OperationStoreGuard(MapTransferHttpServer &) {} };
  std::string storageRoot_ = "/sdcard", operationDeviceID_ = std::string(32, 'a');
  Installer installer_;
  Activation activationState_;
  bool streamStatusActive_ = true, released = false, dispatched = false, finished = false;
  bool storageAvailable = true, throwAllocation = false;
  int refreshes = 0;
  std::string unwound;
  bool refreshStreamStorageCapability(bool) { ++refreshes; return storageAvailable; }
  void finishUnwoundActivation(const std::string &session) noexcept {
    unwound = session; activationState_.running = false;
  }
  bool observeOperationRevision(uint64_t) { return true; }
  std::string firstOwnerCode;
  void rememberOwnerRecovery(const char *code) { if(firstOwnerCode.empty()) firstOwnerCode=code; }
  bool runStreamActivationTask(const std::string &, bool, bool owner = false) {
    assert(!owner); dispatched = true;
    if (throwAllocation) throw std::bad_alloc();
    return true;
  }
  std::string finishedCode;
  void finishActivation(const char *, const std::string &, const char *code, const char *) {
    finished = true; finishedCode = code;
  }
  void releaseCommitGrant() { released = true; }
  CommitRecoveryResult recoverCommitDisposition(const CommitRecovery &);
};
'''
        policy = source.index(RETRY_POLICY)
        fixture += source[policy:source.index("} // namespace", policy) + len("} // namespace")]
        fixture += USES_RETRY_POLICY
        fixture += method(source, "recoverCommitDisposition",
                          returns="MapTransferHttpServer::CommitRecoveryResult\n")
        fixture += r'''
using Result = MapTransferHttpServer::CommitRecoveryResult;
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
    const bool resolved = server.recoverCommitDisposition({id}) == Result::Completed;
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
      // A storage retry reports the activation step, not upload step 1.
      assert(server.activationState_.step == 3);
    } else {
      assert(!resolved && !server.released && !server.finished);
    }
  }
  // After the last allowed attempt an exact ready map is not activated again:
  // the work fails so the phone can retry. A selected root is never deleted:
  // a completed version it reused is kept while the attempt fails, and a new
  // version the pointer already names keeps retrying activation. Legacy work
  // has no receipt to hold, so its attempt fails either way.
  for (int scenario = 0; scenario != 6; ++scenario) {
    const bool operationBacked = scenario >= 3, selected = scenario % 3 != 0;
    const bool keepable = scenario % 3 == 1;
    MapOperationStorage::slots[0].clear(); MapOperationStorage::slots[1].clear();
    MapOperationStorage::failRead = MapOperationStorage::failWrite = false;
    MapOperationStorage storage(""); operation::Store store(storage, id.device);
    assert(store.restore() == operation::Result::Ok);
    assert(store.initializeAdmission(123) == operation::Result::Ok);
    operation::Identity identity = id;
    if (operationBacked) {
      assert(store.admit(id, store.admissionRevision()) == operation::Result::Ok);
      assert(store.prepare(id) == operation::Result::Ok);
      assert(store.accept(id) == operation::Result::Ok);
    } else {
      identity.operation.clear();
    }
    MapTransferHttpServer server;
    server.installer_.marker = {identity.operation, id.map, id.manifest, id.signedManifest};
    server.installer_.ready = true;
    server.installer_.discardable = !selected;
    server.installer_.discardCode = "stream_discard_active";
    server.installer_.keepable = keepable;
    MapTransferHttpServer::CommitRecovery recovery{identity};
    recovery.failures = 2;
    MapTransferHttpServer attempt;
    attempt.installer_ = server.installer_;
    assert(attempt.recoverCommitDisposition(recovery) == Result::Completed && attempt.dispatched);
    assert(!attempt.installer_.discarded && !attempt.installer_.kept);
    recovery.failures = 3;
    const bool resolved = server.recoverCommitDisposition(recovery) == Result::Completed;
    assert(server.installer_.discarded == !selected);
    assert(server.installer_.kept == (selected && keepable));
    operation::Record record;
    if (operationBacked) {
      assert(store.restore() == operation::Result::Ok);
      assert(store.query(id, record) == operation::Result::Ok);
    }
    if (operationBacked && selected && !keepable) {
      // The new selected version is activated again; its receipt stays open.
      assert(resolved && server.dispatched && !server.released && !server.finished);
      assert(server.activationState_.step == 3);
      assert(record.phase == operation::Phase::Accepted);
      continue;
    }
    assert(resolved && !server.dispatched && server.released && server.finished);
    assert(server.finishedCode == "activation_retry_limit");
    if (operationBacked) assert(record.phase == operation::Phase::Failed);
  }
  const auto accepted = [&](MapTransferHttpServer &server, const operation::Identity &identity) {
    MapOperationStorage::slots[0].clear(); MapOperationStorage::slots[1].clear();
    MapOperationStorage::failRead = MapOperationStorage::failWrite = false;
    if (!identity.operation.empty()) {
      MapOperationStorage storage(""); operation::Store store(storage, id.device);
      assert(store.restore() == operation::Result::Ok);
      assert(store.initializeAdmission(123) == operation::Result::Ok);
      assert(store.admit(identity, store.admissionRevision()) == operation::Result::Ok);
      assert(store.prepare(identity) == operation::Result::Ok);
      assert(store.accept(identity) == operation::Result::Ok);
    }
    server.installer_.marker = {identity.operation, id.map, id.manifest, id.signedManifest};
    server.installer_.ready = true;
  };
  // This session's attempt still runs on the internal owner, or waits for its
  // renderer. The retry neither touches storage nor starts a second attempt,
  // even past the attempt limit, and the caller spends no attempt on it.
  for (const uint8_t failures : {0, 3}) {
    MapTransferHttpServer server;
    accepted(server, id);
    server.activationState_.running = true;
    MapTransferHttpServer::CommitRecovery recovery{id};
    recovery.failures = failures;
    assert(server.recoverCommitDisposition(recovery) == Result::Deferred);
    assert(server.refreshes == 0 && server.installer_.calls == 0 && !server.dispatched);
    assert(server.activationState_.begins == 0 && !server.released && !server.finished);
  }
  {
    // An attempt that starts after the first check is caught by begin().
    MapTransferHttpServer server;
    accepted(server, id);
    server.activationState_.startsBeforeBegin = true;
    assert(server.recoverCommitDisposition({id}) == Result::Deferred);
    assert(!server.dispatched && !server.installer_.discarded && !server.released);
  }
  {
    // Another session's activation still spends an attempt, as before.
    MapTransferHttpServer server;
    accepted(server, id);
    server.activationState_.otherRunning = true;
    assert(server.recoverCommitDisposition({id}) == Result::Failed && !server.dispatched);
  }
  {
    // Earlier renderer success for the same content cannot complete a new
    // operation: the attempt starts over and reports its own progress.
    MapTransferHttpServer server;
    accepted(server, id);
    server.activationState_.finish("installed", "", "", "");
    assert(server.recoverCommitDisposition({id}) == Result::Completed && server.dispatched);
    assert(server.activationState_.begins == 2 && server.activationState_.running);
    assert(server.activationState_.step == 3);
  }
  {
    // Legacy work has no receipt of its own and keeps that success.
    operation::Identity legacy = id;
    legacy.operation.clear();
    MapTransferHttpServer server;
    accepted(server, legacy);
    server.activationState_.finish("installed", "", "", "");
    assert(server.recoverCommitDisposition({legacy}) == Result::Completed && server.dispatched);
    assert(server.activationState_.begins == 1 && server.activationState_.status == "installed");
  }
  {
    // An attempt that unwinds on allocation failure gives up the state, so
    // the next pass retries instead of waiting for it.
    MapTransferHttpServer server;
    accepted(server, id);
    server.throwAllocation = true;
    bool threw = false;
    try { (void)server.recoverCommitDisposition({id}); }
    catch (const std::bad_alloc &) { threw = true; }
    assert(threw && server.unwound == id.session);
    server.throwAllocation = false;
    assert(server.recoverCommitDisposition({id}) == Result::Completed);
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
