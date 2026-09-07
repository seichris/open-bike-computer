#include "map_transfer_http.hpp"
#include "../power_management/power_management.hpp"

#include "../firmware_metadata/firmware_metadata.hpp"
#include "map_stream_compiled_trust.hpp"
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
  streamTrustStore_ = compiledMapStreamTrustStore();
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutexStatic(&stateMutexStorage_);
  configASSERT(stateMutex_ != nullptr);
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
}

void MapTransferHttpServer::submitPendingRollback() {
  lockState();
  if (rollbackKind_ != RollbackKind::None && !rollbackSubmitted_ &&
      storageControlSubmit_ != nullptr)
    rollbackSubmitted_ = storageControlSubmit_(rollbackTask, this);
  unlockState();
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
  DeferredActivation deferred;
  lockState();
  if (deferredActivation_.pending() &&
      deferredActivation_.response.matches(
          request.transferGeneration, request.method, request.path)) {
    deferred = std::move(deferredActivation_);
    deferredActivation_ = {};
  }
  unlockState();
  if (!deferred.pending())
    return;
  if (!transferServer_->isRequestAuthorized(request)) {
    Serial.printf("MAP_TRANSFER_HTTP: deferred activation revoked session=%s\n",
                  deferred.sessionId.c_str());
    const InstallStatus discarded =
        installer_.discardUnselectedStreamMap(deferred.sessionId);
    updateStreamInstallState(MapStreamInstallSnapshot(), false);
    setLastError(discarded.ok ? "transfer_cancelled" : discarded.code,
                 discarded.ok
                     ? "activation authorization was revoked before the "
                       "response completed"
                     : discarded.message);
    return;
  }

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
  DeferredActivation deferred;
  lockState();
  if (deferredActivation_.pending() &&
      deferredActivation_.response.matches(
          request.transferGeneration, request.method, request.path)) {
    deferred = std::move(deferredActivation_);
    deferredActivation_ = {};
  }
  unlockState();
  if (!deferred.pending())
    return;
  const InstallStatus discarded =
      installer_.discardUnselectedStreamMap(deferred.sessionId);
  updateStreamInstallState(MapStreamInstallSnapshot(), false);
  setLastError(discarded.ok ? "response_incomplete" : discarded.code,
               discarded.ok
                   ? "map activation was cancelled because the HTTP response "
                     "did not complete"
                   : discarded.message);
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
  lockState();
  const bool acceptsUploads = activationState_.acceptsUploads() &&
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
  const auto publishProgress =
      [this, &lastPublishedBytes, &lastPublishedAt, &lastPublishedProgress](
          const MapStreamInstallSnapshot &snapshot) {
        updateStreamInstallState(snapshot, true);
        lastPublishedBytes = snapshot.receivedPayloadBytes;
        lastPublishedAt = millis();
        lastPublishedProgress = snapshot.progress();
      };
  auto receiver = std::unique_ptr<MapStreamReceiver>(
      new (std::nothrow) MapStreamReceiver(
          trustStore, storageRoot_, sessionId, request.contentLength,
          firmware_metadata::version(), kMaximumParserWorkingBytes, {}, {}, {},
          publishProgress));
  if (!receiver) {
    sendError(client, 503, "stream_resource_unavailable",
              "could not allocate map stream receiver");
    return true;
  }
  updateStreamInstallState(receiver->snapshot(), true);
  std::array<uint8_t, 1024> buffer = {};
  uint64_t remaining = request.contentLength;
  uint32_t lastRead = millis();
  bool cancelled = false;
  while (remaining > 0 && !receiver->failed()) {
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
  if (!cancelled && !transferServer_->isRequestAuthorized(request))
    cancelled = true;
  const MapStreamReceiveResult result = receiver->finish();
  updateStreamInstallState(receiver->snapshot(), !result.ok);
  if (cancelled) {
    sendError(client, 409, "transfer_cancelled",
              "map transfer authorization was revoked");
    return true;
  }
  if (!result.ok) {
    refreshStreamStorageCapability(true);
    sendError(client, result.httpStatus, result.code, result.message);
    return true;
  }

  const MapStreamInstallSnapshot completed = receiver->snapshot();
  const uint32_t minimumActivationSequence =
      completed.sequence == UINT32_MAX ? UINT32_MAX : completed.sequence + 1;
  const bool responseQueued =
      sendJson(client, 200,
               std::string("{\"ok\":true,\"status\":\"ready\",\"sessionId\":\"") +
                   jsonEscape(sessionId) + "\",\"mapId\":\"" +
                   jsonEscape(completed.mapId) +
                   "\",\"manifestReceipt\":\"" + completed.manifestReceipt +
                   "\",\"signedManifestReceipt\":\"" +
                   completed.signedManifestReceipt + "\"}");
  if (!responseQueued) {
    setLastError("http_response_write",
                 "verified map stream response could not be written");
    return true;
  }
  if (!deferActivationUntilResponse(request, sessionId,
                                    minimumActivationSequence)) {
    setLastError("activation_handoff",
                 "verified map stream activation could not be deferred");
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
  const std::string mapId = std::move(pendingMapId_);
  const bool automaticExit = pendingRendererAutomaticExit_;
  pendingMapRoot_.clear();
  pendingMapSessionId_.clear();
  pendingMapId_.clear();
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = false;
  pendingRendererAutomaticExit_ = false;
  unlockState();

  if (loaded) {
    finishActivation("installed", mapId, "", "");
    if (automaticExit)
      requestAutomaticExit();
  } else {
    lockState();
    rollbackKind_ = RollbackKind::Transfer;
    rollbackSession_ = std::move(sessionId);
    rollbackAutomaticExit_ = automaticExit;
    rollbackSubmitted_ = false;
    unlockState();
    // process() retries command admission; no filesystem work on the UI.
  }
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
  try {
    std::string session = rollbackSession_;
    if (session.empty()) {
      ActiveMapSelection failed;
      if (installer_.readActiveMap(failed).ok)
        session = std::move(failed.sessionId);
    }
    succeeded = !session.empty() && installer_.rollbackActiveMap(session).ok;
    if (rollbackKind_ == RollbackKind::Runtime)
      succeeded = succeeded && installer_.readActiveMap(restored).ok;
  } catch (const std::bad_alloc &) {
    Serial.println("MAP_RESOURCE_REJECTED: rollback");
  }
  lockState();
  const bool transfer = rollbackKind_ == RollbackKind::Transfer;
  const bool automaticExit = rollbackAutomaticExit_;
  rollbackSucceeded_ = succeeded;
  rollbackRestored_ = std::move(restored);
  rollbackComplete_ = true;
  if (transfer) {
    // Short fixed error text stays within string small-buffer storage.
    activationState_.finish("failed", "", "renderer_reload", "");
    rollbackKind_ = RollbackKind::None;
  }
  unlockState();
  Serial.printf("MAP_ROLLBACK completed=1 restored=%u\n", succeeded ? 1U : 0U);
  if (transfer && automaticExit)
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
  lockState();
  activationState_.finish(std::move(status), std::move(mapId),
                          std::move(stateCode), std::move(stateMessage));
  unlockState();
  if (!errorCode.empty()) {
    transferServer_->setLastError(errorCode, errorMessage);
  }
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
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
    uint32_t minimumSequence) {
  lockState();
  if (deferredActivation_.pending()) {
    unlockState();
    return false;
  }
  deferredActivation_.response = {
      request.transferGeneration, request.method, request.path};
  deferredActivation_.sessionId = sessionId;
  deferredActivation_.minimumSequence = minimumSequence;
  unlockState();
  return true;
}

void MapTransferHttpServer::beginDeferredActivation(
    const DeferredActivation &activation, bool peerClosedCleanly) {
  lockState();
  const ActivationBeginResult beginResult = activationState_.begin(
      activation.sessionId, 3, activation.minimumSequence);
  if (beginResult == ActivationBeginResult::Started) {
    activationState_.updateProgress({3, 3, 0, 1});
    streamStatusActive_ = false;
  }
  unlockState();

  if (beginResult == ActivationBeginResult::Started) {
    // responseDidComplete runs on the existing 16 KiB transfer worker after
    // the upload handler and stream parser have unwound. Activation needs the
    // same stack budget, so execute it here instead of allocating a second
    // 16 KiB task at the firmware's peak map-transfer memory watermark.
    executeActivation(activation.sessionId, peerClosedCleanly);
    return;
  }
  if (beginResult == ActivationBeginResult::AlreadyInstalled) {
    const InstallStatus cleaned =
        installer_.activateReadyStreamMap(activation.sessionId);
    if (!cleaned.ok)
      setLastError(cleaned.code, cleaned.message);
    if (peerClosedCleanly)
      requestAutomaticExit();
    return;
  }
  if (beginResult == ActivationBeginResult::Busy) {
    setLastError("activation_busy",
                 "another map activation started after upload completion");
  }
}

void MapTransferHttpServer::executeActivation(const std::string &sessionId,
                                              bool automaticExit) try {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Transfer);
  const bool waitingForRenderer =
      runStreamActivationTask(sessionId, automaticExit);
  if (waitingForRenderer)
    return;
  if (automaticExit)
    requestAutomaticExit();
}

catch (const std::bad_alloc &) {
  finishActivation("failed", "", "out_of_memory", "");
  if (automaticExit)
    requestAutomaticExit();
}

bool MapTransferHttpServer::runStreamActivationTask(
    const std::string &sessionId, bool automaticExit) {
  const auto onProgress = [this](const ActivationProgress &progress) {
    updateActivationProgress(progress);
  };
  InstallStatus activated = installer_.recoverPendingStreamActivation(onProgress);
  if (!activated.ok) {
    finishActivation("failed", "", activated.code, activated.message);
    return false;
  }
  ActiveMapSelection selected;
  InstallStatus active = installer_.readActiveMap(selected);
  if (!active.ok || selected.sessionId != sessionId) {
    finishActivation("failed", active.ok ? selected.mapId : "",
                     active.ok ? "stream_activation_identity" : active.code,
                     active.ok ? "activated stream session does not match"
                               : active.message);
    return false;
  }
  lockState();
  pendingMapRoot_ = std::move(selected.root);
  pendingMapSessionId_ = std::move(selected.sessionId);
  pendingMapId_ = std::move(selected.mapId);
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = true;
  pendingRendererAutomaticExit_ = automaticExit;
  activationState_.updateProgress({3, 3, 2, 3});
  unlockState();
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
