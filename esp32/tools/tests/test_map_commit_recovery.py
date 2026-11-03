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
    "kCommitRecoveryBackoffMs < kCommitRecoveryMaximumBackoffMs && "
    "kCommitRecoveryStalledMs == 600000U, \"retry policy\");\n")


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
    bool waiting=false; uint32_t waitingProgress=0, waitingSinceMs=0;
    bool pending() const { return !identity.session.empty(); }
  } commitRecovery_;
  uint32_t storageProgressSequence() const { return 0; }
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

    def test_boot_and_upload_admission_skip_a_finished_selection_marker(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        # Boot used to resume these markers: a previous map's activation can
        # never finish, refused uploads meanwhile and could select it again.
        for body in (method(source, "resumePendingActivations", returns="void "),
                     method(source, "handleInstallStream")):
            self.assertIn("readPendingStreamInstall(", body)
            self.assertNotIn("readRecoverableMapStreamInstall(", body)
        self.assertEqual(source.count("readRecoverableMapStreamInstall("), 1)
        helper = method(source, "readPendingStreamInstall", returns="MapStreamRecoveryResult ")
        fixture = r'''
#include <cassert>
#include <functional>
#include <string>
#include <vector>
enum class MapStreamRecoveryResult { None, Found };
struct MapStreamInstallSnapshot { std::string sessionId, signedManifestReceipt; };
std::vector<MapStreamInstallSnapshot> readyRoots;
MapStreamRecoveryResult readRecoverableMapStreamInstall(
    const std::string &, MapStreamInstallSnapshot &snapshot,
    const std::function<bool(const MapStreamInstallSnapshot &)> &skipReady) {
  for (const auto &ready : readyRoots)
    if (!skipReady(ready)) { snapshot = ready; return MapStreamRecoveryResult::Found; }
  return MapStreamRecoveryResult::None;
}
struct Status { bool ok; };
struct ActiveMapSelection { std::string root, previousRoot, signedManifestReceipt; };
class MapTransferHttpServer {
public:
  struct Installer {
    ActiveMapSelection selection{"/VECTMAP/.maps/selected", "/VECTMAP/.maps/previous", "installed"};
    bool known = true;
    Status readActiveMap(ActiveMapSelection &out) const { out = selection; return {known}; }
  } installer_;
  std::string storageRoot_ = "/sd";
  MapStreamRecoveryResult readPendingStreamInstall(MapStreamInstallSnapshot &snapshot) const;
};
''' + helper + r'''
int main() {
  MapTransferHttpServer server;
  MapStreamInstallSnapshot found;
  // A finished selection's marker, or the previous map's, is not pending work.
  readyRoots = {{"selected", "installed"}, {"previous", "older"}};
  assert(server.readPendingStreamInstall(found) == MapStreamRecoveryResult::None);
  // A version the pointer names that never finished, and any other map, are.
  readyRoots = {{"selected", "newer"}};
  assert(server.readPendingStreamInstall(found) == MapStreamRecoveryResult::Found &&
         found.sessionId == "selected");
  readyRoots = {{"previous", "older"}, {"other", "other"}};
  assert(server.readPendingStreamInstall(found) == MapStreamRecoveryResult::Found &&
         found.sessionId == "other");
  // An unreadable selection skips nothing.
  server.installer_.known = false;
  readyRoots = {{"previous", "older"}};
  assert(server.readPendingStreamInstall(found) == MapStreamRecoveryResult::Found);
}
'''
        with tempfile.TemporaryDirectory(prefix="pending-stream-") as temporary:
            path = Path(temporary)
            (path / "test.cpp").write_text(fixture)
            subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(path / "test.cpp"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)

    def test_every_legacy_resume_reserves_bounded_retries(self):
        source = (ROOT / "lib/map_transfer_http/map_transfer_http.cpp").read_text()
        resume = method(source, "resumePendingStreamActivation")
        fixture = r'''
#include <cassert>
#include <cstdint>
#include <string>
#include <utility>
struct SerialStub { template<class... Args> void printf(const char *, Args...) {} } Serial;
enum class MapStreamInstallState { Receiving, Ready };
enum class MapStreamRecoveryResult { None, Found };
struct MapStreamInstallSnapshot {
  std::string sessionId; MapStreamInstallState state; uint32_t sequence;
};
MapStreamRecoveryResult readRecoverableMapStreamInstall(const std::string &, MapStreamInstallSnapshot &) {
  return MapStreamRecoveryResult::None;
}
struct Status { bool ok; };
struct ActiveMapSelection { std::string root, previousRoot; };
struct ReadyStreamMap {
  std::string operationID, manifestReceipt, signedManifestReceipt, sessionId, mapId;
};
struct ActivationProgress { uint8_t step = 1, totalSteps = 5; uint64_t completed = 0, total = 0; };
enum class ActivationBeginResult { Started, AlreadyRunning };
class MapTransferHttpServer {
public:
  struct CommitRecovery {
    struct Identity {
      std::string device, operation, manifest, signedManifest, sha256;
      uint64_t bytes = 0; std::string session, map;
    } identity;
    bool responseCompleted = false;
    bool pending() const { return !identity.session.empty(); }
  } commitRecovery_;
  struct Installer {
    ActiveMapSelection selection;
    ReadyStreamMap ready{"", "manifest", "signed", "ready-session", "map-1"};
    Status readActiveMap(ActiveMapSelection &out) const { out = selection; return {true}; }
    Status readReadyStreamMap(const std::string &id, ReadyStreamMap &out) const {
      out = ready; return {id == ready.sessionId};
    }
  } installer_;
  struct Activation {
    int begins = 0;
    ActivationBeginResult begin(const std::string &, uint8_t, uint32_t) {
      ++begins; return ActivationBeginResult::Started;
    }
    void updateProgress(const ActivationProgress &) {}
  } activationState_;
  std::string storageRoot_ = "/sd", operationDeviceID_ = "device";
  bool streamStatusActive_ = true, taskStarts = true;
  int retries = 0;
  void lockState() {}
  void unlockState() {}
  void updateStreamInstallState(const MapStreamInstallSnapshot &, bool) {}
  bool startActivationTask(const std::string &, bool) { return taskStarts; }
  void retryAcceptedActivation(const std::string &) { ++retries; }
  MapStreamRecoveryResult readPendingStreamInstall(MapStreamInstallSnapshot &) const {
    return MapStreamRecoveryResult::None;
  }
  bool resumePendingStreamActivation(const MapStreamInstallSnapshot *recovered);
};
''' + resume + r'''
int main() {
  MapStreamInstallSnapshot snapshot{"ready-session", MapStreamInstallState::Ready, 4};
  const ActiveMapSelection selections[] = {
      {"/VECTMAP/.maps/other", ""},
      // Boot skips a finished selection's marker, so a root the pointer names
      // arrives here only as a version that never finished.
      {"/VECTMAP/.maps/ready-session", ""}};
  for (const auto &selection : selections) {
    MapTransferHttpServer server;
    server.installer_.selection = selection;
    assert(server.resumePendingStreamActivation(&snapshot));
    // Every legacy resume gets the bounded disposition. A failed attempt then
    // retries, and the last one keeps a selected root and fails the attempt,
    // never leaving it recovering without a retry coming.
    assert(server.commitRecovery_.pending() && server.commitRecovery_.responseCompleted);
    assert(server.commitRecovery_.identity.session == "ready-session" &&
           server.commitRecovery_.identity.operation.empty() &&
           server.commitRecovery_.identity.map == "map-1");
    assert(server.activationState_.begins == 1 && !server.streamStatusActive_);
    assert(server.retries == 0);
  }
  {
    // Operation-backed work is armed from its Accepted receipt instead.
    MapTransferHttpServer server;
    server.installer_.ready.operationID = "0123456789abcdef0123456789abcdef";
    assert(server.resumePendingStreamActivation(&snapshot));
    assert(!server.commitRecovery_.pending());
  }
  {
    // A task that was never created hands the reserved work to the storage worker.
    MapTransferHttpServer server;
    server.installer_.selection = selections[1];
    server.taskStarts = false;
    assert(!server.resumePendingStreamActivation(&snapshot));
    assert(server.retries == 1 && server.commitRecovery_.pending());
  }
}
'''
        with tempfile.TemporaryDirectory(prefix="boot-resume-") as temporary:
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
    bool waiting = false; uint32_t waitingProgress = 0, waitingSinceMs = 0;
    bool pending() const { return !identity.session.empty(); }
  } commitRecovery_;
  uint32_t progress = 0;
  uint32_t storageProgressSequence() const { return progress; }
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
  assert(server.commitRecovery_.waiting && server.commitRecovery_.waitingSinceMs == clockMs);
  const uint32_t waitStarted = clockMs;
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_);
  clockMs += 4999U;
  server.submitPendingOperationTask();
  assert(!server.operationTaskSubmitted_);
  clockMs += 1U;
  server.submitPendingOperationTask();
  assert(server.operationTaskSubmitted_);
  // The wait is measured from the last storage progress, not the last pass.
  server.deferCommitRecoveryRetry();
  assert(server.commitRecovery_.waitingSinceMs == waitStarted);
  ++server.progress;
  clockMs += 5000U;
  server.deferCommitRecoveryRetry();
  assert(server.commitRecovery_.waitingSinceMs == clockMs);
  assert(server.commitRecovery_.waitingProgress == server.progress);
  // A real attempt that fails ends the wait.
  server.pendingRendererAcknowledgement_ = false;
  server.retryAcceptedActivation("accepted");
  assert(!server.commitRecovery_.waiting && server.commitRecovery_.failures == failures + 1);
  server.pendingRendererAcknowledgement_ = true;
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
// Production sets issued once the command is queued: always for ESP_OK,
// never for a refusal, and for a timeout only if it timed out after queueing.
struct Owner {
  Work called=nullptr; int result=ESP_OK; bool issued=true;
  int runMapActivation(Work work,void *,const std::string &,bool,bool *out) {
    called=work; *out=result==ESP_OK || (result==ESP_ERR_TIMEOUT && issued); return result;
  }
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
  std::string finished,lastError;
  void retryAcceptedActivation(const std::string &) {++retries;}
  void finishActivation(const char *status,const char *,const char *,const char *) {finished=status;}
  void setLastError(const char *code,const char *) {lastError=code;}
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
  assert(legacy.lastError=="activation_cleanup_timeout");
  // A timeout before the owner received the command runs nothing, so the
  // storage worker retries it instead of the work waiting for a reboot.
  legacy.owner.issued=false;
  legacy.beginDeferredActivation({"same-content",4},true);
  assert(legacy.retries==2 && legacy.lastError=="activation_cleanup_owner");
  for (const bool issued : {true,false}) {
    MapTransferHttpServer timedOut;
    timedOut.commitRecovery_.identity.operation="new-logical-operation";
    timedOut.owner.result=ESP_ERR_TIMEOUT;
    timedOut.owner.issued=issued;
    timedOut.beginDeferredActivation({"same-content",4},true);
    assert(timedOut.owner.called==MapTransferHttpServer::ownedActivation);
    if (issued) {
      assert(timedOut.retries==0 && timedOut.finished.empty());
      assert(timedOut.lastError=="activation_owner_timeout");
    } else {
      assert(timedOut.retries==1 && timedOut.finished=="recovering");
    }
  }
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
uint32_t clockMs = 2000000U;
uint32_t millis() { return clockMs; }
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
  struct CommitRecovery {
    operation::Identity identity; uint8_t failures = 0;
    bool waiting = false; uint32_t waitingProgress = 0, waitingSinceMs = 0;
  };
  uint32_t progress = 7;
  uint32_t storageProgressSequence() const { return progress; }
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
  // The wait lasts only while storage progress moves. A running state that
  // has not moved for the owner's own deadline belongs to no attempt: the
  // retry takes it over, and past the limit the work fails as before.
  for (int scenario = 0; scenario != 4; ++scenario) {
    MapTransferHttpServer server;
    accepted(server, id);
    server.activationState_.running = true;
    MapTransferHttpServer::CommitRecovery recovery{id};
    recovery.waiting = true;
    recovery.waitingProgress = scenario == 2 ? server.progress - 1 : server.progress;
    recovery.waitingSinceMs = clockMs - (scenario == 1 ? 599999U : 600000U);
    if (scenario == 3) recovery.failures = 3;
    const auto result = server.recoverCommitDisposition(recovery);
    if (scenario == 1 || scenario == 2) {
      assert(result == Result::Deferred && !server.dispatched && server.installer_.calls == 0);
    } else if (scenario == 0) {
      assert(result == Result::Completed && server.dispatched && !server.released);
      assert(server.activationState_.begins == 1 && server.activationState_.step == 3);
    } else {
      assert(result == Result::Completed && !server.dispatched && server.installer_.discarded);
      assert(server.released && server.finishedCode == "activation_retry_limit");
    }
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
