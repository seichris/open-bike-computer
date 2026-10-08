#include "../firmware_update/firmware_metadata_compatibility.hpp"
#include "map_transfer_http.hpp"
#include "../power_management/power_management.hpp"
#include "../firmware_update/device_operation_owner.hpp"

#include "../firmware_metadata/firmware_metadata.hpp"
#include "map_stream_compiled_trust.hpp"
#include "map_activation_workspace.hpp"
#include "../ride_diagnostics/ride_diagnostics.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <fcntl.h>
#include <memory>
#include <new>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>
#include <freertos/task.h>
#include <esp_random.h>

namespace map_transfer {
namespace {

constexpr const char *kStatusPath = "/map-transfer/status";
constexpr const char *kSessionPrefix = "/map-transfer/sessions/";
constexpr const char *kInstallStreamAction = "install-stream";
constexpr const char *kMapStreamMediaType =
    "application/vnd.openbikecomputer.map-stream";

struct ActivationTaskContext {
  MapTransferHttpServer *server = nullptr;
  std::string sessionId;
  bool automaticExit = false;
};

static std::string joinPath(const std::string &a, const std::string &b) {
  if (a.empty())
    return b;
  if (b.empty())
    return a;
  if (a.back() == '/')
    return a + (b.front() == '/' ? b.substr(1) : b);
  return a + "/" + (b.front() == '/' ? b.substr(1) : b);
}

static bool startsWith(const std::string &value, const std::string &prefix) {
  return value.size() >= prefix.size() &&
         value.compare(0, prefix.size(), prefix) == 0;
}

static bool safeId(const std::string &value) {
  if (value.empty() || value.size() > 80 || value[0] == '.')
    return false;
  for (char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) {
      return false;
    }
  }
  return value.find("..") == std::string::npos;
}

static bool mkdirs(const std::string &path) {
  if (path.empty())
    return false;
  std::string current;
  size_t i = 0;
  if (path[0] == '/') {
    current = "/";
    i = 1;
  }
  while (i <= path.size()) {
    size_t slash = path.find('/', i);
    std::string part =
        path.substr(i, slash == std::string::npos ? slash : slash - i);
    if (!part.empty()) {
      if (current.size() > 1)
        current += "/";
      current += part;
      if (::mkdir(current.c_str(), 0755) != 0 && errno != EEXIST)
        return false;
    }
    if (slash == std::string::npos)
      break;
    i = slash + 1;
  }
  return true;
}

static std::string urlDecode(const std::string &value) {
  std::string out;
  out.reserve(value.size());
  for (size_t i = 0; i < value.size(); i++) {
    char c = value[i];
    if (c == '%' && i + 2 < value.size()) {
      char hex[3] = {value[i + 1], value[i + 2], '\0'};
      char *end = nullptr;
      long decoded = strtol(hex, &end, 16);
      if (end && *end == '\0') {
        out.push_back(static_cast<char>(decoded));
        i += 2;
        continue;
      }
    }
    out.push_back(c == '+' ? ' ' : c);
  }
  return out;
}

static bool parseSessionPath(const std::string &path, std::string &sessionId,
                             std::string &relativePath) {
  if (!startsWith(path, kSessionPrefix))
    return false;
  std::string rest = path.substr(strlen(kSessionPrefix));
  size_t slash = rest.find('/');
  if (slash == std::string::npos)
    return false;
  sessionId = urlDecode(rest.substr(0, slash));
  relativePath = urlDecode(rest.substr(slash + 1));
  return safeId(sessionId);
}

static std::string jsonEscape(const std::string &value) {
  std::string out;
  out.reserve(value.size() + 8);
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(c);
    } else if (c == '\n') {
      out += "\\n";
    } else if (c == '\r') {
      out += "\\r";
    } else {
      out.push_back(c);
    }
  }
  return out;
}

} // namespace

void MapTransferHttpServer::configure(
    std::string storageRoot, uint16_t port,
    device_transfer::HttpTransferServer *sharedServer) {
  storageRoot_ = std::move(storageRoot);
  if (!storageRoot_.empty() && storageRoot_.back() == '/')
    storageRoot_.pop_back();
  installer_ = MapTransferInstaller(storageRoot_);
  installer_.setOperationDeviceID(operationDeviceID_);
  installer_.setStorageProgressCallback([](void *context) {
    auto *server = static_cast<MapTransferHttpServer *>(context);
    server->storageProgressSequence_.fetch_add(1, std::memory_order_relaxed);
    // Hashing runs on the storage owner; yield only after verified byte progress.
    vTaskDelay(1);
  }, this);
  streamTrustStore_ = compiledMapStreamTrustStore();
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutexStatic(&stateMutexStorage_);
  configASSERT(stateMutex_ != nullptr);
  if (operationStoreMutex_ == nullptr)
    operationStoreMutex_ = xSemaphoreCreateRecursiveMutexStatic(&operationStoreMutexStorage_);
  configASSERT(operationStoreMutex_ != nullptr);
  transferServer_ = sharedServer == nullptr ? &ownedTransferServer_ : sharedServer;
  if (sharedServer == nullptr)
    transferServer_->configure(port, "BikeComputer-Transfer");
  transferServer_->registerHandler("/map-transfer", this);
}

void MapTransferHttpServer::setStreamTrustStore(
    MapStreamTrustStore trustStore) {
  lockState();
  streamTrustStore_ = std::move(trustStore);
  unlockState();
}

void MapTransferHttpServer::setStreamStorageAvailable(bool available) {
  lockState();
  streamStorageAvailable_ = available;
  unlockState();
}

void MapTransferHttpServer::setStreamStorageProbe(
    std::function<bool()> probe) {
  lockState();
  streamStorageProbe_ = std::move(probe);
  unlockState();
}

bool MapTransferHttpServer::streamStoragePathAccessible() const {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  struct stat storage = {};
  struct stat mapNamespace = {};
  return ::stat(storageRoot_.c_str(), &storage) == 0 &&
         S_ISDIR(storage.st_mode) &&
         ::stat(joinPath(storageRoot_, "VECTMAP").c_str(), &mapNamespace) ==
             0 &&
         S_ISDIR(mapNamespace.st_mode);
}

bool MapTransferHttpServer::streamStoragePathWritable() const {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Storage);
  struct stat storage = {};
  if (::stat(storageRoot_.c_str(), &storage) != 0 ||
      !S_ISDIR(storage.st_mode))
    return false;
  const std::string mapNamespace = joinPath(storageRoot_, "VECTMAP");
  if (!mkdirs(mapNamespace))
    return false;
  const std::string probePath =
      joinPath(mapNamespace, ".stream-write-probe");
  const int descriptor =
      ::open(probePath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (descriptor < 0)
    return false;
  const uint8_t marker = 1;
  const bool wrote = ::write(descriptor, &marker, sizeof(marker)) ==
                     static_cast<ssize_t>(sizeof(marker));
  const bool synced = wrote && ::fsync(descriptor) == 0;
  const bool closed = ::close(descriptor) == 0;
  const bool removed = ::unlink(probePath.c_str()) == 0;
  return wrote && synced && closed && removed;
}

bool MapTransferHttpServer::refreshStreamStorageCapability(
    bool requireWritable) {
  lockState();
  const std::function<bool()> probe = streamStorageProbe_;
  unlockState();
  const bool mounted = !probe || probe();
  const bool available =
      mounted && (requireWritable ? streamStoragePathWritable()
                                  : streamStoragePathAccessible());
  setStreamStorageAvailable(available);
  return available;
}

bool MapTransferHttpServer::streamInstallSupported() const {
  lockState();
  const bool available = streamStorageAvailable_;
  const bool trusted = streamTrustStore_.size() > 0;
  const std::function<bool()> probe = streamStorageProbe_;
  unlockState();
  return firmware_metadata::hasImmutableGitIdentity() && available && trusted &&
         (!probe || probe()) &&
         streamStoragePathAccessible();
}

bool MapTransferHttpServer::setEnabled(bool enabled) {
  lockState();
  const bool rollbackBusy = rollbackKind_ != RollbackKind::None;
  unlockState();
  if (enabled && rollbackBusy)
    return false;
  return transferServer_->setEnabled(enabled, enabled ? "map" : "");
}

void MapTransferHttpServer::setLastError(const std::string &code,
                                         const std::string &message) {
  transferServer_->setLastError(code, message);
}

void MapTransferHttpServer::process() {
  transferServer_->process();
  submitPendingRollback();
  submitPendingOperationTask();
}

bool MapTransferHttpServer::shutdownQuiescent() const {
  lockState();
  const bool quiet = terminalOperationID_.empty() && operationQuery_.empty() &&
      !operationTaskSubmitted_ && !commitRecovery_.pending() && pendingCommitGrant_ == 0 && !deferredActivation_.pending() &&
      !activationState_.snapshot().running && !pendingRendererAcknowledgement_ &&
      pendingMapRoot_.empty() && rollbackKind_ == RollbackKind::None &&
      !(streamStatusActive_ &&
        (streamInstallState_.state == MapStreamInstallState::Receiving ||
         streamInstallState_.state == MapStreamInstallState::Finalizing));
  unlockState();
  return quiet;
}

void MapTransferHttpServer::releaseCommitGrant() {
  lockState();
  const auto grant = pendingCommitGrant_;
  pendingCommitGrant_ = 0;
  commitRecovery_ = {};
  unlockState();
  if (grant != 0)
    transferServer_->endAuthorizedCommit(grant);
}

void MapTransferHttpServer::submitPendingRollback() {
  lockState();
  if (rollbackKind_ != RollbackKind::None && !rollbackSubmitted_ &&
      storageControlSubmit_ != nullptr)
    rollbackSubmitted_ = storageControlSubmit_(rollbackTask, this);
  unlockState();
}

void MapTransferHttpServer::setOperationDeviceID(const std::string &device) {
  // Called once after ownership initialization, before request admission.
  StateGuard guard(*this);
  operationDeviceID_ = device;
  if (operationAdmission_.epoch().empty()) {
    uint8_t random[16]; esp_fill_random(random,sizeof(random));
    constexpr char hex[]="0123456789abcdef";
    std::string epoch; epoch.reserve(32);
    for (uint8_t byte : random) { epoch+=hex[byte>>4]; epoch+=hex[byte&15]; }
    operationAdmission_=operation::AdmissionFence(std::move(epoch));
  }
  installer_.setOperationDeviceID(device);
}

bool MapTransferHttpServer::observeOperationRevision(uint64_t revision) const {
  StateGuard guard(*this); return operationAdmission_.observe(revision);
}
bool MapTransferHttpServer::permitsOperationAdmission(const std::string &epoch,uint64_t revision) const {
  StateGuard guard(*this); return operationAdmission_.permits(epoch,revision);
}
bool MapTransferHttpServer::operationsSupported() const {
  StateGuard guard(*this);
  const bool supported = MAP_OPERATIONS_V1_ENABLED &&
      operationDeviceID_.size() == 32 && streamStorageAvailable_;
  return supported;
}

std::string MapTransferHttpServer::readOperationStatus(const std::string &id) const {
  OperationStoreGuard operationStoreGuard(*this);
  MapOperationStorage storage(storageRoot_);
  operation::Store store(storage, operationDeviceID_);
  operation::Record record;
  const auto restored = store.restore();
  const bool observed=restored==operation::Result::Ok && observeOperationRevision(store.admissionRevision());
  if (observed &&
      store.queryID(id,record) == operation::Result::Ok)
    return operationReceiptJson(record);
  return "{\"schemaVersion\":1,\"deviceID\":\"" + operationDeviceID_ +
      "\",\"operationID\":\"" + id + "\",\"status\":\"" +
      (observed ? "result_unavailable" : "storage_unavailable") + "\"}";
}

bool MapTransferHttpServer::requestOperationStatus(const std::string &id) {
  if (!operationsSupported() || id.size()!=32 ||
      !std::all_of(id.begin(),id.end(),[](char c) { return (c>='0' && c<='9') || (c>='a' && c<='f'); }))
    return false;
  StateGuard guard(*this);
  if (!operationQuery_.empty() || operationTaskSubmitted_) { return false; }
  operationQuery_ = id;
  // Never answer a new query with an earlier operation's cached receipt.
  operationStatus_.clear();
  return true;
}
std::string MapTransferHttpServer::operationStatusJson() const {
  StateGuard guard(*this); const auto result=operationStatus_; return result;
}
bool MapTransferHttpServer::takeOperationStatusNotification() {
  StateGuard guard(*this); const bool result=operationStatusNotification_;
  operationStatusNotification_=false; return result;
}
void MapTransferHttpServer::submitPendingOperationTask() {
  lockState();
  if ((!operationQuery_.empty() || !terminalOperationID_.empty() || commitRecovery_.armed) &&
      !operationTaskSubmitted_ && storageControlSubmit_ != nullptr)
    operationTaskSubmitted_ = storageControlSubmit_(operationTask,this);
  unlockState();
}
void MapTransferHttpServer::operationTask(void *context) {
  static_cast<MapTransferHttpServer *>(context)->executeOperationTask();
}
void MapTransferHttpServer::executeOperationTask() try {
  CommitRecovery recovery;
  std::string terminal, session, map, query;
  bool automaticExit = false, failed = false;
  {
    StateGuard guard(*this);
    recovery = commitRecovery_;
    terminal = terminalOperationID_;
    session = terminalSessionID_;
    map = terminalMapID_;
    automaticExit = terminalAutomaticExit_;
    failed = terminalFailed_;
    query = operationQuery_;
  }
  const bool recoveryCompleted = recovery.armed && recoverCommitDisposition(recovery);
  bool completed=terminal.empty();
  std::string body;
  if (!terminal.empty()) {
    OperationStoreGuard operationStoreGuard(*this);
    MapOperationStorage storage(storageRoot_);
    operation::Store store(storage,operationDeviceID_);
    operation::Record record;
    ActiveMapSelection selected;
    const bool restored=store.restore()==operation::Result::Ok &&
        observeOperationRevision(store.admissionRevision());
    bool found=restored && store.queryID(terminal,record)==operation::Result::Ok;
    if (restored && !found) {
      for (const auto &retained : store.records()) {
        if (retained.identity.operation==terminal && retained.acknowledged &&
            (retained.phase==operation::Phase::Installed || retained.phase==operation::Phase::Failed)) {
          record=retained; found=true; break;
        }
      }
    }
    if (found &&
        (failed || (installer_.readActiveMap(selected).ok && selected.sessionId==session &&
        selected.mapId==map && selected.manifestReceipt==record.identity.manifest &&
        selected.signedManifestReceipt==record.identity.signedManifest))) {
      const auto result=record.acknowledged ? operation::Result::Replay :
          (failed ? store.fail(record.identity) : store.rendererAcknowledged(record.identity,
          selected.manifestReceipt,selected.signedManifestReceipt));
      completed=result==operation::Result::Ok || result==operation::Result::Replay;
      if (completed) completed=observeOperationRevision(store.admissionRevision());
      if (completed && !failed && result==operation::Result::Ok) transferServer_->sampleResources("map_terminal");
      if (completed) completed=installer_.finalizeOperation(session,terminal).ok;
      if (completed && store.queryID(terminal,record)==operation::Result::Ok)
        body=operationReceiptJson(record);
    }
  }
  if (!query.empty()) body=readOperationStatus(query);
  lockState();
  if (!body.empty()) { operationStatus_=std::move(body); operationStatusNotification_=true; }
  if (!query.empty() && operationQuery_==query) operationQuery_.clear();
  if (recoveryCompleted && commitRecovery_.identity == recovery.identity)
    commitRecovery_ = {};
  operationTaskSubmitted_=false;
  unlockState();
  if (completed && !terminal.empty()) {
    finishActivation(failed ? "failed" : "installed",map,failed ? "renderer_reload" : "","");
    {
      StateGuard guard(*this);
      terminalOperationID_.clear(); terminalSessionID_.clear(); terminalMapID_.clear();
    }
    releaseCommitGrant();
    if (automaticExit) requestAutomaticExit();
  }
  // Failed persistence leaves activation pending and retains the grant. A
  // subsequent storage-control pass may recover an ambiguous accepted write.
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
}
 catch (const std::bad_alloc &) {
  // Preserve disposition and retry after memory pressure; never strand a mutex.
  { StateGuard guard(*this); operationTaskSubmitted_ = false; }
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
}

void MapTransferHttpServer::armCommitRecovery(
    const device_transfer::HttpRequest &request) {
  StateGuard guard(*this);
  if (commitRecovery_.pending() && !commitRecovery_.responseCompleted &&
      commitRecovery_.response.matches(request.transferGeneration, request.method,
                                      request.path, request.requestSequence)) {
    commitRecovery_.responseCompleted = true;
    const bool deferredOwnsDispatch = deferredActivation_.pending() &&
        deferredActivation_.response.matches(request.transferGeneration, request.method,
                                            request.path, request.requestSequence);
    // A duplicate response callback must not race the internal activation owner.
    if (!deferredOwnsDispatch) commitRecovery_.armed = true;
    ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  }
}

void MapTransferHttpServer::retryAcceptedActivation(const std::string &sessionId) {
  StateGuard guard(*this);
  if (commitRecovery_.pending() && commitRecovery_.identity.session == sessionId &&
      !pendingRendererAcknowledgement_) {
    // Allocation-free: the identity was reserved before granting authority.
    // Called only after the actual activation body has returned/unwound, never
    // merely because dispatch timed out while its owner might still be writing.
    commitRecovery_.responseCompleted = true;
    commitRecovery_.armed = true;
    ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  }
}

bool MapTransferHttpServer::recoverCommitDisposition(const CommitRecovery &recovery) {
  // ENOENT on an absent card must not be mistaken for verified cleanup.
  if (!refreshStreamStorageCapability(true)) return false;
  const auto &identity = recovery.identity;
  OperationStoreGuard operationStoreGuard(*this);
  MapOperationStorage storage(storageRoot_);
  operation::Store store(storage, operationDeviceID_);
  operation::Record record;
  bool accepted = identity.operation.empty(); // Legacy grant is the authority.
  bool hasRecord = false;
  if (!identity.operation.empty()) {
    if (store.restore() != operation::Result::Ok ||
        !observeOperationRevision(store.admissionRevision())) return false;
    const auto result = store.query(identity, record);
    if (result != operation::Result::Ok && result != operation::Result::Unavailable)
      return false;
    hasRecord = result == operation::Result::Ok;
    accepted = hasRecord && (record.phase == operation::Phase::Accepted ||
                             record.phase == operation::Phase::Installed);
  }
  if (accepted && !identity.operation.empty()) {
    // Accepted precedes every boot-eligible mutation. A crash before promotion
    // leaves only .operation-prepared; finish that same granted transaction.
    const auto promoted=installer_.promotePreparedOperation(identity.session,identity.operation);
    if (!promoted.ok && promoted.code!="stream_ready_invalid" &&
        promoted.code!="stream_manifest_receipt" && promoted.code!="stream_installed_receipt")
      return false;
  }
  ReadyStreamMap ready;
  const bool readyMatches = installer_.readReadyStreamMap(identity.session, ready).ok &&
      ready.operationID == identity.operation && ready.mapId == identity.map &&
      ready.manifestReceipt == identity.manifest &&
      ready.signedManifestReceipt == identity.signedManifest;
  if (accepted && readyMatches) {
    // This is the same serialized storage owner used by rollback and receipt
    // writes. Hand off to the renderer only after exact ready identity agrees.
    {
      StateGuard guard(*this);
      const auto begun = activationState_.begin(identity.session, 3);
      if (begun == ActivationBeginResult::Busy) return false;
      streamStatusActive_ = false;
    }
    return runStreamActivationTask(identity.session, false);
  }
  // No pointer mutation was issued by the upload finalizer. Discard checks both
  // active and rollback roots and fails closed on unreadable selection metadata.
  // Cleanup precedes a failed receipt so reboot cannot reactivate a ready root.
  if (!installer_.discardUnselectedStreamMap(identity.session).ok) return false;
  if (hasRecord && record.phase != operation::Phase::Failed &&
      record.phase != operation::Phase::Cancelled) {
    const auto result = store.fail(identity);
    if (result != operation::Result::Ok && result != operation::Result::Replay)
      return false;
    if (!observeOperationRevision(store.admissionRevision())) return false;
  }
  {
    StateGuard guard(*this);
    streamStatusActive_ = false;
  }
  finishActivation("failed", identity.map, "stream_finalization",
                   "map finalization failed; unselected staging was removed");
  releaseCommitGrant();
  return true;
}

bool MapTransferHttpServer::admitReceivingOperation(
    const device_transfer::HttpRequest &request,
    const MapStreamInstallSnapshot &snapshot) {
  if (request.mapOperationID.empty()) return true;
  operation::Identity identity{operationDeviceID_, request.mapOperationID,
      snapshot.manifestReceipt, snapshot.signedManifestReceipt, request.mapStreamSHA256,
      request.contentLength, snapshot.sessionId, snapshot.mapId};
  OperationStoreGuard guard(*this);
  MapOperationStorage storage(storageRoot_);
  operation::Store store(storage,operationDeviceID_);
  if (store.restore()!=operation::Result::Ok || !observeOperationRevision(store.admissionRevision())) return false;
  operation::Record previous;
  const auto found=store.query(identity,previous);
  if (found==operation::Result::Ok)
    return previous.phase==operation::Phase::Receiving;
  if (found!=operation::Result::Unavailable ||
      !permitsOperationAdmission(request.mapOperationAdmissionEpoch,request.mapOperationAdmissionRevision)) return false;
  const auto admitted=store.admit(identity,request.mapOperationAdmissionRevision);
  return admitted==operation::Result::Ok && observeOperationRevision(store.admissionRevision());
}

bool MapTransferHttpServer::handleOperationControl(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  constexpr const char *prefix="/map-transfer/operations/";
  if (request.method!="POST" || !startsWith(request.path,prefix)) return false;
  const auto tail=request.path.substr(std::strlen(prefix));
  if (tail.size()!=39) return false;
  const auto suffix=tail.substr(32);
  const bool cancel=suffix=="/cancel";
  if (!cancel && suffix!="/commit") return false;
  const auto id=tail.substr(0,32);
  const auto hex=[](const std::string &value,size_t n) {
    return value.size()==n && std::all_of(value.begin(),value.end(),[](char c) {
      return (c>='0' && c<='9') || (c>='a' && c<='f'); });
  };
  if (!operationsSupported() || !hex(id,32) || request.mapOperationID!=id ||
      !hex(request.mapStreamSHA256,64) || (request.hasContentLength && request.contentLength!=0)) {
    sendError(client,400,"operation_control","invalid operation control identity"); return true;
  }
  if (!refreshStreamStorageCapability(true)) {
    sendError(client,503,"operation_storage","map operation storage unavailable"); return true;
  }
  OperationStoreGuard guard(*this);
  MapOperationStorage storage(storageRoot_);
  operation::Store store(storage,operationDeviceID_);
  if (store.restore()!=operation::Result::Ok || !observeOperationRevision(store.admissionRevision())) {
    sendError(client,503,"operation_storage","map operation history needs recovery"); return true;
  }
  operation::Record record;
  auto found=store.queryID(id,record);
  if (found==operation::Result::Unavailable && cancel) {
    bool busy=false;
    { StateGuard state(*this); busy=pendingCommitGrant_!=0 || commitRecovery_.pending() || !terminalOperationID_.empty(); }
    if (busy || installer_.hasInterruptedActivation()) {
      sendError(client,409,"operation_busy","accepted cleanup must finish before admitting cancellation"); return true;
    }
    for (const auto &pending : store.records()) {
      if (!pending.identity.operation.empty() &&
          (pending.phase==operation::Phase::Receiving || pending.phase==operation::Phase::Prepared || pending.phase==operation::Phase::Accepted)) {
        sendError(client,409,"operation_busy","another unresolved operation owns admission"); return true;
      }
    }
    // A stopped upload may not yet have reached its signed manifest. Consume
    // the original creation token into a full-identity cancelled tombstone so
    // a late original PUT cannot recreate Prepared state for this attempt.
    uint64_t streamBytes=0;
    if (!request.hasMapOperationAdmissionRevision ||
        !permitsOperationAdmission(request.mapOperationAdmissionEpoch,request.mapOperationAdmissionRevision) ||
        !device_transfer::parseHttpUint64(request.mapStreamBytes,streamBytes)) {
      sendJson(client,409,readOperationStatus(id)); return true;
    }
    operation::Identity identity{operationDeviceID_,id,request.mapManifestReceipt,
        request.mapSignedManifestReceipt,request.mapStreamSHA256,streamBytes,
        request.mapContentSession,request.mapLogicalID};
    if (store.admit(identity,request.mapOperationAdmissionRevision)!=operation::Result::Ok ||
        !observeOperationRevision(store.admissionRevision())) {
      sendJson(client,409,readOperationStatus(id)); return true;
    }
    found=store.queryID(id,record);
  }
  if (found!=operation::Result::Ok) { sendJson(client,409,readOperationStatus(id)); return true; }
  if (record.identity.stream!=request.mapStreamSHA256) {
    sendError(client,409,"operation_conflict","operation ID is bound to another artifact"); return true;
  }
  if (cancel) {
    const auto cancelled=store.cancel(record.identity);
    if (cancelled!=operation::Result::Ok && cancelled!=operation::Result::Replay) {
      sendJson(client,409,readOperationStatus(id)); return true;
    }
    if (!observeOperationRevision(store.admissionRevision())) {
      sendError(client,503,"operation_storage","cancellation receipt needs recovery"); return true;
    }
    // The durable cancellation already prevents promotion. Cleanup may be
    // retried without changing that fact and never deletes selected/rollback roots.
    (void)installer_.cancelOperationStaging(record.identity.session,id);
    updateStreamInstallState(MapStreamInstallSnapshot{},false);
    sendJson(client,200,readOperationStatus(id)); return true;
  }
  if (record.phase==operation::Phase::Accepted || record.phase==operation::Phase::Installed) {
    sendJson(client,200,operationReceiptJson(record)); return true;
  }
  if (record.phase!=operation::Phase::Prepared) {
    sendJson(client,409,operationReceiptJson(record)); return true;
  }
  ReadyStreamMap prepared;
  if (!installer_.readPreparedOperation(record.identity.session,prepared).ok ||
      prepared.operationID!=id || prepared.mapId!=record.identity.map ||
      prepared.manifestReceipt!=record.identity.manifest ||
      prepared.signedManifestReceipt!=record.identity.signedManifest) {
    sendError(client,409,"operation_prepared_missing","verified prepared map requires reconciliation"); return true;
  }
  bool busy=false;
  {
    StateGuard state(*this);
    busy=pendingCommitGrant_!=0 || commitRecovery_.pending() ||
        !activationState_.acceptsUploads() || rollbackKind_!=RollbackKind::None;
  }
  if (busy) { sendError(client,409,"operation_busy","another map commit is in progress"); return true; }
  if (operationOwner_ == nullptr || operationOwner_->protectMetadataReaderFloor(1) != ESP_OK) {
    firmware_update::metadata_compatibility::noteUncertain();
    sendError(client,503,"metadata_floor_unavailable","could not protect map metadata compatibility"); return true;
  }
  CommitRecovery recovery;
  recovery.identity=record.identity;
  recovery.response={request.transferGeneration,request.method,request.path,request.requestSequence};
  const auto grant=transferServer_->beginAuthorizedCommit(request,"map",request.path,record.identity.signedManifest);
  if (!grant) { sendError(client,409,"transfer_cancelled","map commit authorization was revoked"); return true; }
  {
    StateGuard state(*this);
    pendingCommitGrant_=grant; commitRecovery_=std::move(recovery);
  }
  client.requestHttpResponseClose();
  const auto accepted=store.accept(record.identity);
  if ((accepted!=operation::Result::Ok && accepted!=operation::Result::Replay) ||
      !observeOperationRevision(store.admissionRevision())) {
    sendError(client,503,"operation_acceptance","commit receipt requires recovery"); return true;
  }
  const auto promoted=installer_.promotePreparedOperation(record.identity.session,id);
  if (!promoted.ok) { sendError(client,503,promoted.code,promoted.message); return true; }
  if (!deferActivationUntilResponse(request,record.identity.session)) {
    sendError(client,503,"activation_handoff","accepted activation requires recovery"); return true;
  }
  // Keep the preallocated identity dormant until the renderer owns completion.
  sendJson(client,200,readOperationStatus(id));
  return true;
}

bool MapTransferHttpServer::recordPreparedOperation(
    const device_transfer::HttpRequest &request,
    const MapStreamInstallSnapshot &snapshot,const std::string &streamHash) {
  if (request.mapOperationID.empty()) return true;
  if (streamHash!=request.mapStreamSHA256) return false;
  operation::Identity identity{operationDeviceID_,request.mapOperationID,
      snapshot.manifestReceipt,snapshot.signedManifestReceipt,streamHash,
      request.contentLength,snapshot.sessionId,snapshot.mapId};
  OperationStoreGuard operationStoreGuard(*this);
  MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
  if (store.restore()!=operation::Result::Ok || !observeOperationRevision(store.admissionRevision())) return false;
  operation::Record known;
  if (store.queryID(identity.operation,known)==operation::Result::Unavailable &&
      !permitsOperationAdmission(request.mapOperationAdmissionEpoch,request.mapOperationAdmissionRevision)) return false;
  const auto admitted=store.admit(identity,request.mapOperationAdmissionRevision);
  if (admitted!=operation::Result::Ok && admitted!=operation::Result::Replay) return false;
  operation::Record previous;
  if (store.query(identity,previous)==operation::Result::Ok &&
      previous.phase!=operation::Phase::Receiving && previous.phase!=operation::Phase::Prepared) return false;
  const auto prepared=store.prepare(identity);
  if (prepared!=operation::Result::Ok && prepared!=operation::Result::Replay) return false;
  observeOperationRevision(store.admissionRevision());
  operation::Record record;
  if (store.query(identity,record)!=operation::Result::Ok) return false;
  auto body=operationReceiptJson(record);
  { StateGuard guard(*this); operationStatus_=std::move(body); }
  return true;
}

HttpTransferStatus MapTransferHttpServer::status() const {
  return transferServer_->status();
}

bool MapTransferHttpServer::handleRequest(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  if (status().mode != "map") {
    sendError(client, 403, "transfer_mode_mismatch",
              "map transfer mode is not active");
    return true;
  }
  if (!transferServer_->isRequestAuthorized(request)) {
    sendError(client, 401, "transfer_token_invalid",
              "map transfer token is missing or invalid");
    return true;
  }
  if (handleOperationControl(request,client)) return true;
  constexpr const char *operationPrefix = "/map-transfer/operations/";
  if (request.method == "GET" && request.path == "/map-transfer/operations/admission") {
    if (!operationsSupported()) { sendError(client,400,"operation_unsupported","map operation admission unavailable"); return true; }
    OperationStoreGuard operationStoreGuard(*this);
    MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
    if (store.restore()!=operation::Result::Ok) { sendError(client,503,"operation_storage","map operation storage unavailable"); return true; }
    if (!observeOperationRevision(store.admissionRevision())) { sendError(client,503,"operation_storage","operation history regressed"); return true; }
    const bool capacity=std::any_of(store.records().begin(),store.records().end(),
        [](const operation::Record &record) { return record.identity.operation.empty() || record.acknowledged; });
    if (!capacity) { sendError(client,409,"operation_capacity","acknowledge a retained terminal result before starting another operation"); return true; }
    if (store.admissionRevision()==0) {
      const uint64_t seed=((uint64_t(esp_random())<<32)|esp_random()) & UINT64_C(0x7fffffffffffffff);
      if (store.initializeAdmission(seed ? seed : 1)!=operation::Result::Ok) {
        sendError(client,503,"operation_storage","map operation admission initialization failed"); return true;
      }
    }
    if (!observeOperationRevision(store.admissionRevision())) { sendError(client,503,"operation_storage","operation history regressed"); return true; }
    sendJson(client,200,"{\"schemaVersion\":1,\"deviceID\":\""+operationDeviceID_+
        "\",\"admissionEpoch\":\""+operationAdmission_.epoch()+"\",\"admissionRevision\":"+
        std::to_string(store.admissionRevision())+"}"); return true;
  }
  if (request.method == "POST" && startsWith(request.path,operationPrefix) &&
      request.path.size()==std::strlen(operationPrefix)+32+12 &&
      request.path.substr(request.path.size()-12)=="/acknowledge") {
    const auto id=request.path.substr(std::strlen(operationPrefix),32);
    if (!operationsSupported()) { sendError(client,400,"operation_unsupported","map operation acknowledgement unavailable"); return true; }
    OperationStoreGuard operationStoreGuard(*this);
    MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
    operation::Record record;
    if (store.restore()!=operation::Result::Ok) { sendError(client,503,"operation_storage","map operation storage unavailable"); return true; }
    if (!observeOperationRevision(store.admissionRevision())) { sendError(client,503,"operation_storage","operation history regressed"); return true; }
    const auto found=store.queryID(id,record);
    if (found==operation::Result::Ok) {
      const auto acknowledged=store.acknowledgeResult(record.identity);
      if (acknowledged!=operation::Result::Ok && acknowledged!=operation::Result::Replay) {
        sendError(client,409,"operation_unresolved","only a terminal operation may be acknowledged"); return true;
      }
    } else if (found!=operation::Result::Unavailable) {
      sendError(client,400,"operation_id","invalid map operation ID"); return true;
    }
    observeOperationRevision(store.admissionRevision());
    sendJson(client,200,readOperationStatus(id)); return true;
  }

  if (request.method == "GET" && startsWith(request.path,operationPrefix)) {
    const auto id=request.path.substr(std::strlen(operationPrefix));
    if (!operationsSupported() || id.size()!=32 ||
        !std::all_of(id.begin(),id.end(),[](char c) { return (c>='0' && c<='9') || (c>='a' && c<='f'); }))
      sendError(client,400,"operation_unsupported","invalid or unsupported map operation query");
    else sendJson(client,200,readOperationStatus(id));
    return true;
  }
  if (request.method == "GET" && request.path == kStatusPath) {
    handleStatus(client);
    return true;
  }
  Serial.printf("MAP_TRANSFER_HTTP: %s %s length=%llu\n",
                request.method.c_str(), request.path.c_str(),
                static_cast<unsigned long long>(request.contentLength));
  if (request.method == "PUT" &&
      handleInstallStream(request, client))
    return true;
  if (startsWith(request.path, kSessionPrefix)) {
    sendError(client, 426, "signed_stream_required",
              "unsigned map archives are disabled; regenerate this map and "
              "install its signed stream");
    return true;
  }
  return false;
}

void MapTransferHttpServer::responseDidComplete(
    const device_transfer::HttpRequest &request, bool peerClosedCleanly) {
  armCommitRecovery(request);
  DeferredActivation deferred;
  lockState();
  if (deferredActivation_.pending() &&
      deferredActivation_.response.matches(
          request.transferGeneration, request.method, request.path,
          request.requestSequence)) {
    deferred = std::move(deferredActivation_);
    deferredActivation_ = {};
  }
  unlockState();
  if (!deferred.pending())
    return;
  Serial.printf("MAP_TRANSFER_HTTP: response complete session=%s peer_closed=%d\n",
                deferred.sessionId.c_str(), peerClosedCleanly ? 1 : 0);
  // If the peer did not complete the close handshake, keep the AP available.
  // The iPhone can still reconcile the durable activation over HTTP/BLE and
  // explicitly exit transfer mode; the ordinary inactivity timeout remains a
  // bounded fallback.
  beginDeferredActivation(deferred, peerClosedCleanly);
}

void MapTransferHttpServer::responseDidAbort(
    const device_transfer::HttpRequest &request) {
  armCommitRecovery(request);
  DeferredActivation deferred;
  lockState();
  if (deferredActivation_.pending() &&
      deferredActivation_.response.matches(
          request.transferGeneration, request.method, request.path,
          request.requestSequence)) {
    deferred = std::move(deferredActivation_);
    deferredActivation_ = {};
  }
  unlockState();
  if (!deferred.pending())
    return;
  // Response transport cannot revoke an accepted grant. The same owner
  // dispatches exactly once after either response outcome.
  beginDeferredActivation(deferred, false);
}

bool MapTransferHttpServer::handleInstallStream(
    const device_transfer::HttpRequest &request, device_transfer::TransferClient &client) {
  std::string sessionId;
  std::string action;
  if (!parseSessionPath(request.path, sessionId, action) ||
      action != kInstallStreamAction) {
    return false;
  }
  if (!refreshStreamStorageCapability(true)) {
    sendError(client, 503, "stream_storage_unavailable",
              "map stream storage is not mounted and writable");
    return true;
  }
  if (!streamInstallSupported()) {
    sendError(client, 503, "stream_capability_unavailable",
              "map stream trust keys are not provisioned");
    return true;
  }
  if (request.contentType != kMapStreamMediaType) {
    sendError(client, 415, "stream_content_type",
              "map stream content type is invalid");
    return true;
  }
  constexpr uint64_t kMaximumStreamBytes =
      MAP_STREAM_MAX_PAYLOAD_BYTES + MAP_STREAM_MAX_MANIFEST_BYTES + 1024;
  if (!request.hasContentLength || request.contentLength == 0 ||
      request.contentLength > kMaximumStreamBytes) {
    sendError(client, 413, "stream_content_length",
              "map stream content length is invalid");
    return true;
  }
  if (request.mapOperationHeadersPresent) {
    const auto hex=[](const std::string &value,size_t n) {
      return value.size()==n && std::all_of(value.begin(),value.end(),[](char c) {
        return (c>='0' && c<='9') || (c>='a' && c<='f'); });
    };
    if (!operationsSupported() || !hex(request.mapOperationID,32) ||
        !hex(request.mapStreamSHA256,64) || !hex(request.mapOperationAdmissionEpoch,32) || !request.hasMapOperationAdmissionRevision) {
      sendError(client,400,"operation_unsupported","map operation headers are invalid or unsupported");
      return true;
    }
    OperationStoreGuard operationStoreGuard(*this);
    MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
    operation::Record existing;
    if (store.restore()!=operation::Result::Ok || !observeOperationRevision(store.admissionRevision())) {
      sendError(client,503,"operation_storage","map operation history needs recovery"); return true;
    }
    for (const auto &record : store.records()) {
      if (record.identity.operation==request.mapOperationID && record.acknowledged) {
        sendJson(client,409,readOperationStatus(request.mapOperationID)); return true;
      }
    }
    const auto existingResult=store.queryID(request.mapOperationID,existing);
    if (existingResult==operation::Result::Unavailable &&
        !std::any_of(store.records().begin(),store.records().end(),
            [](const operation::Record &record) { return record.identity.operation.empty() || record.acknowledged; })) {
      sendError(client,409,"operation_capacity","map operation history is full"); return true;
    }
    if (existingResult==operation::Result::Unavailable &&
        (!permitsOperationAdmission(request.mapOperationAdmissionEpoch,request.mapOperationAdmissionRevision))) {
      sendJson(client,409,readOperationStatus(request.mapOperationID)); return true;
    }
    if (existingResult==operation::Result::Ok) {
      if (existing.identity.stream!=request.mapStreamSHA256 ||
          existing.identity.streamBytes!=request.contentLength || existing.identity.session!=sessionId) {
        sendError(client,409,"operation_conflict","operation ID is bound to another artifact"); return true;
      }
      if (existing.phase!=operation::Phase::Receiving) {
        client.requestHttpResponseClose();
        sendJson(client,200,"{\"ok\":true,\"status\":\"operation_replay\",\"operation\":"+
            operationReceiptJson(existing)+"}"); return true;
      }
    }
    for (const auto &record : store.records()) {
      if (!record.identity.operation.empty() && record.identity.operation!=request.mapOperationID &&
          (record.phase==operation::Phase::Accepted || record.phase==operation::Phase::Prepared ||
           record.phase==operation::Phase::Receiving)) {
        sendError(client,409,"operation_busy","an unresolved map operation must be reconciled first"); return true;
      }
    }
  }
  if (!request.mapOperationHeadersPresent && !operationDeviceID_.empty()) {
    OperationStoreGuard operationStoreGuard(*this);
    MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
    const auto restored=store.restore();
    if (restored!=operation::Result::Ok && restored!=operation::Result::ForeignDevice) {
      sendError(client,503,"operation_storage","map operation history needs recovery"); return true;
    }
    if (restored==operation::Result::Ok) for (const auto &record : store.records()) {
      if (!record.identity.operation.empty() && (record.phase==operation::Phase::Accepted || record.phase==operation::Phase::Prepared || record.phase==operation::Phase::Receiving)) {
        sendError(client,409,"operation_busy","an accepted operation must be reconciled first"); return true;
      }
    }
  }
  lockState();
  const bool acceptsUploads = pendingCommitGrant_ == 0 &&
                              activationState_.acceptsUploads() &&
                              rollbackKind_ == RollbackKind::None;
  MapStreamTrustStore trustStore = streamTrustStore_;
  unlockState();
  if (!acceptsUploads) {
    sendError(client, 409, "activation_busy",
              "map stream cannot change while activation is running");
    return true;
  }
  InstallStatus recovered = installer_.recoverInterruptedActivation();
  if (!recovered.ok) {
    sendError(client, 503, recovered.code, recovered.message);
    return true;
  }
  MapStreamInstallSnapshot recoverableStream;
  const MapStreamRecoveryResult streamRecovery =
      readRecoverableMapStreamInstall(storageRoot_, recoverableStream);
  if (streamRecovery == MapStreamRecoveryResult::Invalid) {
    const InstallStatus discarded =
        installer_.discardAllUnselectedStreamMaps();
    if (!discarded.ok) {
      sendError(client, 503, discarded.code, discarded.message);
      return true;
    }
    updateStreamInstallState(MapStreamInstallSnapshot(), false);
  } else if (streamRecovery == MapStreamRecoveryResult::Ambiguous) {
    sendError(client, 503, "stream_recovery_blocked",
              "existing map stream state must be reconciled first");
    return true;
  }
  if (!request.mapOperationID.empty() && streamRecovery==MapStreamRecoveryResult::Found &&
      recoverableStream.state==MapStreamInstallState::Ready) {
    ReadyStreamMap prior;
    if (!installer_.readReadyStreamMap(recoverableStream.sessionId,prior).ok ||
        prior.operationID!=request.mapOperationID) {
      sendError(client,409,"stream_ready_pending","a previously granted map must reconcile before a new operation");
      return true;
    }
  }
  if (streamRecovery == MapStreamRecoveryResult::Found &&
      recoverableStream.state == MapStreamInstallState::Ready &&
      recoverableStream.sessionId != sessionId) {
    sendError(client, 409, "stream_ready_pending",
              "another verified stream is pending activation");
    return true;
  }
  if (!installer_.pruneObsoleteInstalledMaps(sessionId)) {
    sendError(client, 500, "stream_prune",
              "could not prune obsolete stream installations");
    return true;
  }

  constexpr size_t kMaximumParserWorkingBytes = 6U * 1024U * 1024U;
  constexpr uint64_t kProgressPublishBytes = 256U * 1024U;
  constexpr uint32_t kProgressPublishMilliseconds = 500;
  uint64_t lastPublishedBytes = 0;
  uint32_t lastPublishedAt = millis();
  uint8_t lastPublishedProgress = UINT8_MAX;
  bool operationAdmissionFailed = false;
  bool operationAdmitted = request.mapOperationID.empty();
  const auto publishProgress =
      [this, &request, &operationAdmissionFailed, &operationAdmitted, &lastPublishedBytes, &lastPublishedAt, &lastPublishedProgress](
          const MapStreamInstallSnapshot &snapshot) {
        if (!operationAdmitted && snapshot.manifestReceipt.size()==64 &&
            snapshot.signedManifestReceipt.size()==64 && !snapshot.mapId.empty()) {
          operationAdmitted=admitReceivingOperation(request,snapshot);
          operationAdmissionFailed=!operationAdmitted;
        }
        updateStreamInstallState(snapshot, true);
        lastPublishedBytes = snapshot.receivedPayloadBytes;
        lastPublishedAt = millis();
        lastPublishedProgress = snapshot.progress();
      };
  if (!request.mapOperationID.empty() &&
      (operationOwner_ == nullptr || operationOwner_->protectMetadataReaderFloor(1) != ESP_OK)) {
    firmware_update::metadata_compatibility::noteUncertain();
    sendError(client,503,"metadata_floor_unavailable","could not protect map metadata compatibility");
    return true;
  }
  auto receiver = std::unique_ptr<MapStreamReceiver>(
      new (std::nothrow) MapStreamReceiver(
          trustStore, storageRoot_, sessionId, request.contentLength,
          firmware_metadata::version(), kMaximumParserWorkingBytes, {}, {}, {},
          publishProgress, request.mapOperationID));
  if (!receiver) {
    sendError(client, 503, "stream_resource_unavailable",
              "could not allocate map stream receiver");
    return true;
  }
  updateStreamInstallState(receiver->snapshot(), true);
  std::array<uint8_t, 1024> buffer = {};
  Sha256Hasher operationHasher;
  uint64_t remaining = request.contentLength;
  uint32_t lastRead = millis();
  bool cancelled = false;
  while (remaining > 0 && !receiver->failed() && !operationAdmissionFailed) {
    if (!transferServer_->isRequestAuthorized(request)) {
      cancelled = true;
      break;
    }
    const int available = client.available();
    if (available <= 0) {
      if (millis() - lastRead > 10000)
        break;
      delay(1);
      continue;
    }
    const size_t count = static_cast<size_t>(std::min<uint64_t>(
        std::min<uint64_t>(remaining, buffer.size()),
        static_cast<uint64_t>(available)));
    const int read = client.read(buffer.data(), count);
    if (read <= 0)
      continue;
    if (!receiver->feed(buffer.data(), static_cast<size_t>(read)))
      break;
    if (request.mapOperationHeadersPresent) operationHasher.update(buffer.data(),static_cast<size_t>(read));
    remaining -= static_cast<uint64_t>(read);
    lastRead = millis();
    const MapStreamInstallSnapshot &snapshot = receiver->snapshot();
    const uint8_t progress = snapshot.progress();
    const uint32_t now = millis();
    if (progress != lastPublishedProgress &&
        (snapshot.receivedPayloadBytes - lastPublishedBytes >=
             kProgressPublishBytes ||
         now - lastPublishedAt >= kProgressPublishMilliseconds)) {
      publishProgress(snapshot);
    }
    delay(0);
  }
  // A complete signed body is only prepared. Socket EOF/truncation and
  // cancellation must never finalize a truncated body. Legacy finish publishes
  // boot-eligible state under its grant; operation-aware finish is prepared-only.
  if (operationAdmissionFailed) {
    receiver->abort();
    sendError(client,409,"operation_admission","map operation admission was cancelled or conflicted");
    return true;
  }
  if (cancelled || !receiver->readyToFinish()) {
    const auto result = receiver->abort();
    updateStreamInstallState(receiver->snapshot(), true);
    sendError(client, cancelled ? 409 : result.httpStatus,
              cancelled ? "transfer_cancelled" : result.code,
              cancelled ? "map transfer authorization was revoked" : result.message);
    return true;
  }
  const std::string operationHash = request.mapOperationHeadersPresent ? operationHasher.finalHex() : "";
  if (request.mapOperationHeadersPresent && operationHash!=request.mapStreamSHA256) {
    receiver->abort();
    sendError(client,409,"operation_digest","map stream does not match operation digest");
    return true;
  }
  if (!request.mapOperationID.empty()) {
    if (!transferServer_->isRequestAuthorized(request)) {
      receiver->abort(); sendError(client,409,"transfer_cancelled","map preparation authorization was revoked"); return true;
    }
    const auto result=receiver->finish();
    updateStreamInstallState(receiver->snapshot(),true);
    if (!result.ok) { sendError(client,result.httpStatus,result.code,result.message); return true; }
    if (!recordPreparedOperation(request,receiver->snapshot(),operationHash)) {
      sendError(client,503,"operation_prepare","prepared receipt requires reconciliation"); return true;
    }
    client.requestHttpResponseClose();
    sendJson(client,200,"{\"ok\":true,\"status\":\"prepared\",\"operation\":"+
        readOperationStatus(request.mapOperationID)+"}");
    return true;
  }
  // Allocate the recovery identity before publishing a grant. Only the response
  // callback arms it, after this receiver (and its FILEs) has unwound.
  CommitRecovery recovery;
  const auto &preparedSnapshot = receiver->snapshot();
  recovery.identity = {operationDeviceID_, request.mapOperationID,
      preparedSnapshot.manifestReceipt, preparedSnapshot.signedManifestReceipt,
      operationHash, request.contentLength, sessionId, preparedSnapshot.mapId};
  recovery.response = {request.transferGeneration, request.method, request.path,
                      request.requestSequence};
  const auto grant = transferServer_->beginAuthorizedCommit(
      request, "map", request.path, receiver->snapshot().signedManifestReceipt);
  if (grant == 0) {
    receiver->abort();
    updateStreamInstallState(receiver->snapshot(), true);
    sendError(client, 409, "transfer_cancelled",
              "map commit authorization is unavailable");
    return true;
  }
  lockState();
  pendingCommitGrant_ = grant;
  commitRecovery_ = std::move(recovery);
  unlockState();
  // Every post-grant failure must reach its completion callback; a reusable
  // response skips that callback and would otherwise leave recovery unarmed.
  client.requestHttpResponseClose();
  const MapStreamReceiveResult result = receiver->finish();
  updateStreamInstallState(receiver->snapshot(), !result.ok);
  if (!result.ok) {
    // Finalization may have partially published recovery metadata. Retain
    // ownership until a verified disposition, rather than allow unsafe stop.
    refreshStreamStorageCapability(true);
    sendError(client, result.httpStatus, result.code, result.message);
    return true;
  }

  const MapStreamInstallSnapshot completed = receiver->snapshot();
  const uint32_t minimumActivationSequence =
      completed.sequence == UINT32_MAX ? UINT32_MAX : completed.sequence + 1;
  // Reserve the callback handoff BEFORE writing any response. Enqueue/write
  // failure reaches responseDidAbort and still dispatches the granted work.
  if (!deferActivationUntilResponse(request, sessionId,
                                    minimumActivationSequence)) {
    setLastError("activation_handoff",
                 "accepted map activation is pending recovery");
    return true;
  }
  // Deferred activation now owns disposition, including response write failure.
  // Keep the preallocated identity dormant until the renderer owns completion.
  client.requestHttpResponseClose();
  const bool responseQueued =
      sendJson(client, 200,
               std::string("{\"ok\":true,\"status\":\"ready\",\"sessionId\":\"") +
                   jsonEscape(sessionId) + "\",\"mapId\":\"" +
                   jsonEscape(completed.mapId) +
                   "\",\"manifestReceipt\":\"" + completed.manifestReceipt +
                   "\",\"signedManifestReceipt\":\"" +
                   completed.signedManifestReceipt + "\"" +
                   (request.mapOperationID.empty() ? std::string() : ",\"operation\":" + readOperationStatus(request.mapOperationID)) + "}");
  if (!responseQueued) {
    setLastError("http_response_write",
                 "verified map stream response could not be written");
    return true;
  }
  return true;
}

void MapTransferHttpServer::handleStatus(device_transfer::TransferClient &client) {
  ActiveMapSelection activeMap;
  InstallStatus active = installer_.readActiveMap(activeMap);
  HttpTransferStatus transferStatus = status();
  const bool streamSupported = streamInstallSupported();

  std::string body = std::string("{\"configured\":") +
                     (transferStatus.configured ? "true" : "false") +
                     ",\"enabled\":" +
                     (transferStatus.enabled ? "true" : "false") +
                     ",\"port\":" + std::to_string(transferStatus.port) +
                     ",\"firmwareVersion\":\"" +
                     jsonEscape(firmware_metadata::version()) +
                     "\",\"firmwareBuild\":" +
                     std::to_string(firmware_metadata::build()) +
                     ",\"firmwareGitSha\":\"" +
                     jsonEscape(firmware_metadata::gitSha()) + "\"" +
                     ",\"protocols\":" +
                     (streamSupported ? "[2]" : "[]");
  if (streamSupported) {
    body += ",\"streamFormatVersions\":[1],\"streamTrust\":" +
            compiledMapStreamTrustCapabilitiesJson();
  }
  if (!transferStatus.baseUrl.empty()) {
    body += ",\"baseUrl\":\"" + jsonEscape(transferStatus.baseUrl) + "\"";
  }
  if (!transferStatus.apSsid.empty()) {
    body += ",\"apSsid\":\"" + jsonEscape(transferStatus.apSsid) + "\"";
  }
  if (active.ok) {
    body += ",\"activeMapId\":\"" + jsonEscape(activeMap.mapId) + "\"";
    body += ",\"activeRoot\":\"" + jsonEscape(activeMap.root) + "\"";
    if (!activeMap.sessionId.empty()) {
      body += ",\"activeSessionId\":\"" +
              jsonEscape(activeMap.sessionId) + "\"";
    }
    if (!activeMap.manifestReceipt.empty()) {
      body += ",\"activeManifestReceipt\":\"" +
              jsonEscape(activeMap.manifestReceipt) + "\"";
    }
    if (activeMap.target.formatVersion != 0) {
      body += ",\"activeRendererFormat\":" +
              std::to_string(activeMap.target.formatVersion) +
              ",\"labelProfileVersion\":" +
              std::to_string(activeMap.target.labelProfileVersion) +
              ",\"labelLanguages\":[";
      for (size_t index = 0; index < activeMap.target.labelLanguages.size();
           ++index) {
        if (index != 0)
          body += ",";
        body +=
            "\"" + jsonEscape(activeMap.target.labelLanguages[index]) + "\"";
      }
      body += "],\"fontAssetHealthy\":";
      body += activeMap.target.formatVersion >= 2 ? "true" : "false";
    }
  } else {
    body += ",\"activeError\":{\"code\":\"" + jsonEscape(active.code) +
            "\",\"message\":\"" + jsonEscape(active.message) + "\"}";
  }
  body += ",\"mapOperationsV1\":" + std::string(operationsSupported() ? "true" : "false");
  body += ",\"selectionHealth\":" + selectionHealthJson();
  body += ",\"activation\":" + activationStatusJson();
  if (!transferStatus.lastErrorCode.empty()) {
    body += ",\"lastError\":{\"code\":\"" +
            jsonEscape(transferStatus.lastErrorCode) + "\",\"message\":\"" +
            jsonEscape(transferStatus.lastErrorMessage) + "\"}";
  }
  body += "}";
  sendJson(client, 200, body);
}

bool MapTransferHttpServer::sendJson(device_transfer::TransferClient &client, int status,
                                     const std::string &body) {
  return device_transfer::sendHttpJson(client, status, body);
}

void MapTransferHttpServer::sendError(device_transfer::TransferClient &client, int status,
                                      const std::string &code,
                                      const std::string &message) {
  transferServer_->setLastError(code, message);
  device_transfer::sendHttpError(client, status, code, message);
}

void MapTransferHttpServer::lockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreTake(stateMutex_, portMAX_DELAY);
}

void MapTransferHttpServer::unlockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreGive(stateMutex_);
}

std::string MapTransferHttpServer::activationStatusJson(bool compact) const {
  lockState();
  const bool activationRunning = activationState_.snapshot().running;
  std::string body = streamStatusActive_ && !activationRunning
                         ? streamInstallState_.json(compact)
                         : activationState_.json(compact);
  unlockState();
  return body;
}

MapActivationSnapshot MapTransferHttpServer::activationSnapshot() const {
  lockState();
  MapActivationSnapshot snapshot = activationState_.snapshot();
  if (streamStatusActive_ && !snapshot.running) {
    snapshot.running = streamInstallState_.state ==
                           MapStreamInstallState::Receiving ||
                       streamInstallState_.state ==
                           MapStreamInstallState::Finalizing;
    snapshot.sequence = streamInstallState_.sequence;
    snapshot.status = mapStreamInstallStateCode(streamInstallState_.state);
    snapshot.sessionId = streamInstallState_.sessionId;
    snapshot.mapId = streamInstallState_.mapId;
    snapshot.step = streamInstallState_.step();
    snapshot.totalSteps = streamInstallState_.totalSteps();
    snapshot.progress = streamInstallState_.progress();
    snapshot.errorCode = streamInstallState_.errorCode;
    snapshot.errorMessage = streamInstallState_.errorMessage;
    snapshot.ownerRecoveryCode.fill(0);
    snapshot.terminalCode.fill(0);
  }
  unlockState();
  return snapshot;
}

bool MapTransferHttpServer::activationHasError() const {
  lockState();
  const MapActivationSnapshot activation = activationState_.snapshot();
  const bool hasError = streamStatusActive_ && !activation.running
                            ? !streamInstallState_.errorCode.empty()
                            : !activation.errorCode.empty();
  unlockState();
  return hasError;
}

void MapTransferHttpServer::updateStreamInstallState(
    const MapStreamInstallSnapshot &snapshot, bool active) {
  lockState();
  streamInstallState_ = snapshot;
  streamStatusActive_ = active;
  unlockState();
}

bool MapTransferHttpServer::takeActivatedMapRoot(ActivatedMapRoot &activated) {
  lockState();
  if (pendingMapRoot_.empty() ||
      (pendingRendererAcknowledgement_ && pendingMapRootTaken_)) {
    unlockState();
    return false;
  }
  activated.root = pendingMapRoot_;
  activated.mapId = pendingMapId_;
  activated.sessionPresent = !pendingMapSessionId_.empty();
  if (pendingRendererAcknowledgement_)
    pendingMapRootTaken_ = true;
  else
    pendingMapRoot_.clear();
  unlockState();
  return true;
}

void MapTransferHttpServer::acknowledgeActivatedMapRoot(
    const std::string &root, bool loaded) {
  lockState();
  if (!pendingRendererAcknowledgement_ || !pendingMapRootTaken_ ||
      pendingMapRoot_ != root) {
    unlockState();
    return;
  }
  std::string sessionId = std::move(pendingMapSessionId_);
  std::string mapId = std::move(pendingMapId_);
  const bool automaticExit = pendingRendererAutomaticExit_;
  std::string operationID=std::move(pendingMapOperationID_);
  selectionHealth_.select(root,operationID,mapId,sessionId,loaded);
  operationStatusNotification_=true;
  const bool hasOperation=!operationID.empty();
  if (loaded && !operationID.empty()) {
    terminalOperationID_=std::move(operationID); terminalSessionID_=std::move(sessionId);
    terminalMapID_=std::move(mapId); terminalAutomaticExit_=automaticExit; terminalFailed_=false;
  }
  pendingMapRoot_.clear();
  pendingMapSessionId_.clear();
  pendingMapId_.clear();
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = false;
  pendingRendererAutomaticExit_ = false;
  unlockState();

  if (loaded && hasOperation) {
    return; // process() persists the renderer receipt on the storage worker
  }
  if (loaded) {
    finishActivation("installed", mapId, "", "");
    releaseCommitGrant();
    if (automaticExit)
      requestAutomaticExit();
  } else {
    lockState();
    rollbackKind_ = RollbackKind::Transfer;
    rollbackOperationID_=std::move(operationID);
    rollbackSession_ = std::move(sessionId);
    rollbackAutomaticExit_ = automaticExit;
    rollbackSubmitted_ = false;
    unlockState();
    // process() retries command admission; no filesystem work on the UI.
  }
}

std::string MapTransferHttpServer::selectionOperationID(const ActiveMapSelection &selected) const {
  OperationStoreGuard guard(*this);
  MapOperationStorage storage(storageRoot_);
  operation::Store store(storage,operationDeviceID_);
  if (store.restore()!=operation::Result::Ok) return {};
  std::string latest;
  uint64_t revision=0;
  for (const auto &record : store.records()) {
    if (record.phase==operation::Phase::Installed && record.revision>revision &&
        record.identity.session==selected.sessionId && record.identity.map==selected.mapId &&
        record.identity.manifest==selected.manifestReceipt &&
        record.identity.signedManifest==selected.signedManifestReceipt) {
      latest=record.identity.operation; revision=record.revision;
    }
  }
  return latest;
}
void MapTransferHttpServer::observeBootSelection(const ActiveMapSelection &selected, bool loaded, bool preserveAffected) {
  const auto operation=selectionOperationID(selected);
  StateGuard guard(*this);
  selectionHealth_.select(selected.root,operation,selected.mapId,selected.sessionId,loaded,preserveAffected);
  if (!loaded && !selected.root.empty()) {
    if (selectionHealth_.affectedOperationID.empty()) selectionHealth_.affectedOperationID=operation;
    selectionHealth_.failRollback();
  }
}
void MapTransferHttpServer::markSelectionDegraded() {
  StateGuard guard(*this);
  if (selectionHealth_.degrade(selectionHealth_.root)) operationStatusNotification_=true;
}
void MapTransferHttpServer::acknowledgeRuntimeRollback(const std::string &root,bool loaded) {
  StateGuard guard(*this);
  if (selectionHealth_.acknowledge(root,loaded)) operationStatusNotification_=true;
}
std::string MapTransferHttpServer::selectionHealthJson() const {
  StateGuard guard(*this);
  const auto &health=selectionHealth_;
  return "{\"schemaVersion\":1,\"bootID\":\""+jsonEscape(operationAdmission_.epoch())+
      "\",\"revision\":"+std::to_string(health.revision)+
      ",\"state\":\""+health.state+"\",\"root\":\""+jsonEscape(health.root)+
      "\",\"operationID\":\""+jsonEscape(health.operationID)+
      "\",\"mapID\":\""+jsonEscape(health.mapID)+
      "\",\"sessionID\":\""+jsonEscape(health.sessionID)+
      "\",\"affectedOperationID\":\""+jsonEscape(health.affectedOperationID)+"\"}";
}

bool MapTransferHttpServer::requestRuntimeRollback() {
  // UI owns mode changes; do not race a live upload or an enabled listener.
  if (transferServer_->status().enabled)
    return false;
  lockState();
  if (rollbackKind_ != RollbackKind::None ||
      !activationState_.acceptsUploads() || streamStatusActive_) {
    unlockState();
    return false;
  }
  selectionHealth_.beginRollback();
  rollbackKind_ = RollbackKind::Runtime;
  rollbackSubmitted_ = false;
  rollbackComplete_ = false;
  rollbackSession_.clear();
  unlockState();
  return true;
}

bool MapTransferHttpServer::takeRuntimeRollback(ActiveMapSelection &restored,
                                               bool &succeeded) {
  lockState();
  if (rollbackKind_ != RollbackKind::Runtime || !rollbackComplete_) {
    unlockState();
    return false;
  }
  restored = std::move(rollbackRestored_);
  succeeded = rollbackSucceeded_;
  rollbackKind_ = RollbackKind::None;
  rollbackComplete_ = false;
  unlockState();
  return true;
}

void MapTransferHttpServer::rollbackTask(void *context) {
  static_cast<MapTransferHttpServer *>(context)->executeRollback();
}

void MapTransferHttpServer::executeRollback() {
  // A single admitted command owns these fields until completion. Admission
  // blocks uploads and the UI only polls the completion under stateMutex_.
  bool succeeded = false;
  ActiveMapSelection restored;
  std::string restoredOperation;
  try {
    std::string session = rollbackSession_;
    if (session.empty()) {
      ActiveMapSelection failed;
      if (installer_.readActiveMap(failed).ok)
        session = std::move(failed.sessionId);
    }
    succeeded = !session.empty() && installer_.rollbackActiveMap(session).ok;
    if (rollbackKind_ == RollbackKind::Runtime) {
      succeeded = succeeded && installer_.readActiveMap(restored).ok;
      if (succeeded) restoredOperation = selectionOperationID(restored);
    }
  } catch (const std::bad_alloc &) {
    succeeded = false;
    Serial.println("MAP_RESOURCE_REJECTED: rollback");
  }
  lockState();
  const bool transfer = rollbackKind_ == RollbackKind::Transfer;
  if (!transfer) {
    operationStatusNotification_=true;
    if (succeeded) selectionHealth_.select(restored.root,restoredOperation,
        restored.mapId,restored.sessionId,false,true);
    else selectionHealth_.failRollback();
  }
  const bool automaticExit = rollbackAutomaticExit_;
  rollbackSucceeded_ = succeeded;
  rollbackRestored_ = std::move(restored);
  rollbackComplete_ = true;
  const bool needsReceipt=transfer && succeeded && !rollbackOperationID_.empty();
  if (needsReceipt) {
    terminalOperationID_=std::move(rollbackOperationID_);
    terminalSessionID_=rollbackSession_; terminalMapID_.clear();
    terminalAutomaticExit_=automaticExit; terminalFailed_=true;
  }
  if (transfer) {
    // Short fixed error text stays within string small-buffer storage.
    if (!needsReceipt) activationState_.finish("failed", "", "renderer_reload", "");
    rollbackKind_ = RollbackKind::None;
  }
  unlockState();
  Serial.printf("MAP_ROLLBACK completed=1 restored=%u\n", succeeded ? 1U : 0U);
  if (transfer && succeeded && !needsReceipt)
    releaseCommitGrant();
  if (transfer && automaticExit && succeeded && !needsReceipt)
    requestAutomaticExit();
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
}

bool MapTransferHttpServer::takeAutomaticExitRequest() {
  lockState();
  const bool requested = pendingAutomaticExit_;
  pendingAutomaticExit_ = false;
  unlockState();
  return requested;
}

bool MapTransferHttpServer::resumePendingStreamActivation(
    const MapStreamInstallSnapshot *recovered) {
  MapStreamInstallSnapshot snapshot;
  if (recovered != nullptr) {
    snapshot = *recovered;
  } else {
    const MapStreamRecoveryResult recovery =
        readRecoverableMapStreamInstall(storageRoot_, snapshot);
    if (recovery != MapStreamRecoveryResult::Found)
      return false;
  }
  updateStreamInstallState(snapshot, true);
  if (snapshot.state != MapStreamInstallState::Ready)
    return false;

  lockState();
  const ActivationBeginResult beginResult =
      activationState_.begin(
          snapshot.sessionId, 3,
          snapshot.sequence == UINT32_MAX ? UINT32_MAX : snapshot.sequence + 1);
  if (beginResult == ActivationBeginResult::Started) {
    activationState_.updateProgress({3, 3, 0, 1});
    streamStatusActive_ = false;
  }
  unlockState();
  if (beginResult == ActivationBeginResult::Started) {
    Serial.printf("MAP_TRANSFER_HTTP: resuming ready stream session=%s\n",
                  snapshot.sessionId.c_str());
    return startActivationTask(snapshot.sessionId, true);
  }
  return false;
}

void MapTransferHttpServer::resumePendingActivations() {
  // Latch copied/earlier experimental new-format state before any later OTA
  // maintenance boot, which deliberately does not mount the SD card.
  bool newMetadata = false;
  for (const char *slot : {"/VECTMAP/.operations-v1-0", "/VECTMAP/.operations-v1-1"}) {
    struct stat info = {};
    if (::stat((storageRoot_ + slot).c_str(), &info) == 0) newMetadata = true;
    else if (errno != ENOENT) {
      firmware_update::metadata_compatibility::noteUncertain();
      setLastError("metadata_floor_unavailable", "map metadata presence is unknown");
      return;
    }
  }
  const bool floorOwnerWasStarted = operationOwner_ != nullptr && operationOwner_->started();
  if (newMetadata && (operationOwner_ == nullptr ||
      operationOwner_->protectMetadataReaderFloor(1) != ESP_OK)) {
    firmware_update::metadata_compatibility::noteUncertain();
    setLastError("metadata_floor_unavailable", "could not protect existing map metadata");
    return;
  }
  if (newMetadata && !floorOwnerWasStarted && operationOwner_ != nullptr &&
      operationOwner_->started() && !operationOwner_->release()) {
    firmware_update::metadata_compatibility::noteUncertain();
    setLastError("metadata_floor_unavailable", "metadata protection owner could not drain");
    return;
  }
  if (!operationDeviceID_.empty()) {
    OperationStoreGuard operationStoreGuard(*this);
    MapOperationStorage storage(storageRoot_); operation::Store store(storage,operationDeviceID_);
    if (store.restore()==operation::Result::Ok) {
      for (const auto &record : store.records()) {
        if (record.phase!=operation::Phase::Accepted || record.identity.operation.empty()) continue;
        CommitRecovery recovery;
        recovery.identity=record.identity;
        recovery.armed=true;
        { StateGuard guard(*this); commitRecovery_=std::move(recovery); }
        submitPendingOperationTask();
        return;
      }
    }
  }
  MapStreamInstallSnapshot streamSnapshot;
  const MapStreamRecoveryResult streamRecovery =
      readRecoverableMapStreamInstall(storageRoot_, streamSnapshot);
  if (streamRecovery == MapStreamRecoveryResult::Found) {
    updateStreamInstallState(streamSnapshot, true);
  } else if (streamRecovery != MapStreamRecoveryResult::None) {
    setLastError(streamRecovery == MapStreamRecoveryResult::Ambiguous
                     ? "stream_recovery_ambiguous"
                     : "stream_recovery_invalid",
                 "map stream recovery state requires a new matching upload");
  }

  std::string archiveSessionId;
  const bool archivePending =
      installer_.readPendingArchiveActivation(archiveSessionId);
  const bool readyStream = streamRecovery == MapStreamRecoveryResult::Found &&
                           streamSnapshot.state == MapStreamInstallState::Ready;
  if (archivePending) {
    const bool stagedDiscarded =
        installer_.discardStagedSession(archiveSessionId);
    const bool markerCleared = installer_.clearPendingArchiveActivation();
    setLastError(
        stagedDiscarded && markerCleared ? "legacy_archive_disabled"
                                         : "legacy_archive_cleanup",
        stagedDiscarded && markerCleared
            ? "an unsigned pending map archive was discarded; regenerate it "
              "as a signed stream"
            : "an unsigned pending map archive could not be fully discarded");
  }
  if (readyStream)
    resumePendingStreamActivation(&streamSnapshot);
}

void MapTransferHttpServer::requestAutomaticExit() {
  lockState();
  pendingAutomaticExit_ = true;
  unlockState();
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
}

void MapTransferHttpServer::finishActivation(std::string status, std::string mapId,
              std::string errorCode, std::string errorMessage) {
  // Reserve report copies before entering the state mutex. Moving the
  // prepared fields into the state is allocation-free.
  std::string stateCode = errorCode;
  std::string stateMessage = errorMessage;
  const bool terminal = status == "failed" || status == "installed";
  const std::string phase = status;
  lockState();
  activationState_.finish(std::move(status), std::move(mapId),
                          std::move(stateCode), std::move(stateMessage));
  unlockState();
  if (terminal) recordActivationOutcome(phase, errorCode);
  if (!errorCode.empty()) {
    transferServer_->setLastError(errorCode, errorMessage);
  }
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
}

void MapTransferHttpServer::rememberOwnerRecovery(const char *code) noexcept {
  StateGuard guard(*this);
  activationState_.rememberOwnerRecovery(code);
}

void MapTransferHttpServer::recordActivationOutcome(const std::string &phase,
                                                     const std::string &code) try {
  struct Workspace {
    std::array<char, 64> first{}, terminal{};
    std::array<char, 33> operation{};
    char fields[384]{};
  };
  const auto workspace = makeActivationWorkspace<Workspace>();
  {
    StateGuard guard(*this);
    workspace->first = activationState_.ownerRecoveryCode();
    workspace->terminal = activationState_.terminalCode();
    const auto &operation = !terminalOperationID_.empty() ? terminalOperationID_ :
        commitRecovery_.identity.operation;
    std::copy_n(operation.data(), std::min(operation.size(), workspace->operation.size() - 1),
                workspace->operation.data());
  }
  const int bytes = std::snprintf(workspace->fields, sizeof(workspace->fields),
      "{\"operationId\":\"%s\",\"phase\":\"%s\",\"code\":\"%s\",\"reason\":\"%s\"}",
      workspace->operation.data(), phase.c_str(), workspace->terminal.data(), workspace->first.data());
  if (bytes > 0 && static_cast<size_t>(bytes) < sizeof(workspace->fields))
    (void)ride_diagnostics::record(code.empty() ? ride_diagnostics::Level::Info : ride_diagnostics::Level::Error,
        "transfer", "map_activation_result", workspace->fields);
} catch (const std::bad_alloc &) {
  // Authenticated status retains the bounded codes even if recording is lost.
}

void MapTransferHttpServer::updateActivationProgress(
    const ActivationProgress &progress) {
  lockState();
  activationState_.updateProgress(progress);
  unlockState();
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  // Stream finalization can otherwise keep a priority-1 worker runnable long
  // enough to starve the CPU0 idle task and trip the task WDT.
  vTaskDelay(pdMS_TO_TICKS(1));
}

bool MapTransferHttpServer::startActivationTask(const std::string &sessionId,
                                                bool automaticExit) try {
  auto *context =
      new ActivationTaskContext{this, sessionId, automaticExit};
  BaseType_t created = xTaskCreate(activationTaskThunk, "map_activate", 16384,
                                   context, 1, nullptr);
  if (created != pdPASS) {
    delete context;
    finishActivation("failed", "", "activation_task",
                     "could not start activation task");
    if (automaticExit)
      requestAutomaticExit();
    return false;
  }
  Serial.printf("MAP_TRANSFER_HTTP: signed activation queued session=%s "
                "automatic=%d protocol=2\n",
                sessionId.c_str(), automaticExit);
  return true;
}

catch (const std::bad_alloc &) {
  finishActivation("failed", "", "out_of_memory", "");
  return false;
}

bool MapTransferHttpServer::deferActivationUntilResponse(
    const device_transfer::HttpRequest &request, const std::string &sessionId,
    uint32_t minimumSequence) try {
  // Allocate before the mutex so an OOM cannot strand the accepted owner.
  DeferredActivation pending;
  pending.response = {request.transferGeneration, request.method, request.path,
                      request.requestSequence};
  pending.sessionId = sessionId;
  pending.minimumSequence = minimumSequence;
  lockState();
  if (deferredActivation_.pending()) {
    unlockState();
    return false;
  }
  deferredActivation_ = std::move(pending);
  unlockState();
  return true;
} catch (const std::bad_alloc &) {
  return false;
}

void MapTransferHttpServer::beginDeferredActivation(
    const DeferredActivation &activation, bool peerClosedCleanly) {
  ActivationBeginResult beginResult;
  try {
    StateGuard guard(*this);
    beginResult = activationState_.begin(activation.sessionId, 3, activation.minimumSequence);
    if (beginResult == ActivationBeginResult::AlreadyInstalled &&
        !commitRecovery_.identity.operation.empty()) {
      // Same content is a different logical installation when its operation ID
      // is new. Historical renderer success cannot complete this new receipt.
      activationState_.finish("prepared", "", "", "");
      beginResult = activationState_.begin(activation.sessionId, 3, activation.minimumSequence);
    }
    if (beginResult == ActivationBeginResult::Started) {
      activationState_.updateProgress({3, 3, 0, 1});
      streamStatusActive_ = false;
    }
  } catch (const std::bad_alloc &) {
    retryAcceptedActivation(activation.sessionId);
    return; // No owner command was issued.
  }

  if (beginResult == ActivationBeginResult::Started) {
    // The HTTP response and stream parser have unwound. Only the internal
    // operation owner may now run the durable activation/rollback transaction;
    // the TLS worker's stack is in PSRAM and must never be the flash caller.
    transferServer_->sampleResources("before_map_activation");
    const esp_err_t dispatch = operationOwner_ == nullptr
        ? ESP_ERR_INVALID_STATE
        : operationOwner_->runMapActivation(ownedActivation, this,
                                            activation.sessionId,
                                            peerClosedCleanly);
    if (dispatch == ESP_ERR_TIMEOUT) {
      // The internal task may still be committing the journal. Keep its
      // activation state live and poison the owner; a late completion must
      // never be reported as a cancelled or safely retryable map switch.
      setLastError("activation_owner_timeout",
                   "map activation is still resolving on the device");
    } else if (dispatch != ESP_OK) {
      retryAcceptedActivation(activation.sessionId);
      rememberOwnerRecovery("activation_owner");
      finishActivation("recovering", "", "activation_owner",
                       "accepted map activation requires recovery");
    }
    transferServer_->sampleResources("after_map_activation");
    return;
  }
  if (beginResult == ActivationBeginResult::AlreadyInstalled) {
    const esp_err_t dispatch = operationOwner_ == nullptr
        ? ESP_ERR_INVALID_STATE
        : operationOwner_->runMapActivation(ownedInstalledCleanup, this,
                                            activation.sessionId,
                                            peerClosedCleanly);
    if (dispatch != ESP_OK) {
      if (dispatch != ESP_ERR_TIMEOUT) retryAcceptedActivation(activation.sessionId);
      setLastError(dispatch == ESP_ERR_TIMEOUT ? "activation_cleanup_timeout"
                                               : "activation_cleanup_owner",
                   "installed map cleanup could not complete safely");
    }
    return;
  }
  if (beginResult == ActivationBeginResult::Busy) {
    setLastError("activation_busy",
                 "another map activation started after upload completion");
  }
}

void MapTransferHttpServer::ownedActivation(void *context,
                                            const char *sessionId,
                                            bool automaticExit) {
  static_cast<MapTransferHttpServer *>(context)->executeActivation(
      sessionId, automaticExit);
}

void MapTransferHttpServer::ownedInstalledCleanup(void *context,
                                                  const char *sessionId,
                                                  bool automaticExit) {
  auto *server = static_cast<MapTransferHttpServer *>(context);
  const InstallStatus cleaned = server->installer_.activateReadyStreamMap(sessionId);
  if (!cleaned.ok) {
    server->rememberOwnerRecovery(cleaned.code.c_str());
    server->retryAcceptedActivation(sessionId);
    server->setLastError(cleaned.code, cleaned.message);
  } else {
    server->releaseCommitGrant();
    if (automaticExit) server->requestAutomaticExit();
  }
}

void MapTransferHttpServer::executeActivation(const std::string &sessionId,
                                              bool automaticExit) try {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Transfer);
  const bool waitingForRenderer =
      runStreamActivationTask(sessionId, automaticExit, true);
  if (waitingForRenderer) {
    StateGuard guard(*this);
    if (commitRecovery_.identity.session == sessionId) commitRecovery_ = {};
    return;
  }
  retryAcceptedActivation(sessionId);
  // Failure before renderer ownership is not terminal; do not request exit.
}

catch (const std::bad_alloc &) {
  rememberOwnerRecovery("out_of_memory");
  retryAcceptedActivation(sessionId);
  // Do not allocate another error report while recovering from allocation
  // failure. Durable accepted state remains queryable and the worker retries.
}

bool MapTransferHttpServer::runStreamActivationTask(
    const std::string &sessionId, bool automaticExit, bool internalOwner) {
  const auto onProgress = [this](const ActivationProgress &progress) {
    updateActivationProgress(progress);
  };
  const auto onRecovery = [](void *context, const char *code) {
    static_cast<MapTransferHttpServer *>(context)->rememberOwnerRecovery(code);
  };
  InstallStatus activated = installer_.recoverPendingStreamActivation(onProgress,
      internalOwner ? +onRecovery : nullptr, this);
  if (!activated.ok) {
    if (internalOwner) rememberOwnerRecovery(activated.code.c_str());
    finishActivation("recovering", "", activated.code, activated.message);
    return false;
  }
  ActiveMapSelection selected;
  InstallStatus active = installer_.readActiveMap(selected);
  if (!active.ok || selected.sessionId != sessionId) {
    if (internalOwner) rememberOwnerRecovery(active.ok ? "stream_activation_identity" : active.code.c_str());
    finishActivation("recovering", active.ok ? selected.mapId : "",
                     active.ok ? "stream_activation_identity" : active.code,
                     active.ok ? "activated stream session does not match"
                               : active.message);
    return false;
  }
  ReadyStreamMap ready;
  const auto readyStatus=installer_.readReadyStreamMap(sessionId,ready);
  if (!readyStatus.ok) {
    if (internalOwner) rememberOwnerRecovery(readyStatus.code.c_str());
    finishActivation("recovering","",readyStatus.code,readyStatus.message); return false;
  }
  std::string operationID = ready.operationID; // Allocate before taking the mutex.
  StateGuard guard(*this);
  pendingMapOperationID_=std::move(operationID);
  pendingMapRoot_ = std::move(selected.root);
  pendingMapSessionId_ = std::move(selected.sessionId);
  pendingMapId_ = std::move(selected.mapId);
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = true;
  pendingRendererAutomaticExit_ = automaticExit;
  activationState_.updateProgress({3, 3, 2, 3});
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  return true;
}

void MapTransferHttpServer::activationTaskThunk(void *arg) {
  auto *context = static_cast<ActivationTaskContext *>(arg);
  if (context != nullptr && context->server != nullptr) {
    MapTransferHttpServer *server = context->server;
    std::string sessionId = std::move(context->sessionId);
    const bool automaticExit = context->automaticExit;
    delete context;
    server->executeActivation(sessionId, automaticExit);
  } else {
    delete context;
  }
  vTaskDelete(nullptr);
}

} // namespace map_transfer
