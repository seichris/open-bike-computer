#include "map_transfer_http.hpp"
#include "../power_management/power_management.hpp"

#include "../firmware_metadata/firmware_metadata.hpp"
#include "../maps/src/mapBlockFormat.hpp"
#include "map_stream_compiled_trust.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <fstream>
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
constexpr uint64_t kMaxUploadBytes = 128ULL * 1024ULL * 1024ULL;
constexpr uint64_t kMaxArchiveUploadBytes = 512ULL * 1024ULL * 1024ULL;

struct ActivationTaskContext {
  MapTransferHttpServer *server = nullptr;
  std::string sessionId;
  bool automaticExit = false;
  bool streamProtocol = false;
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

static std::string dirnameOf(const std::string &path) {
  size_t slash = path.find_last_of('/');
  if (slash == std::string::npos)
    return "";
  if (slash == 0)
    return "/";
  return path.substr(0, slash);
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

static bool safeRelativePath(const std::string &path) {
  if (path.empty() || path[0] == '/' || path.size() > 240 ||
      path.find('\\') != std::string::npos ||
      path.find("//") != std::string::npos ||
      path.find("..") != std::string::npos) {
    return false;
  }
  std::stringstream stream(path);
  std::string part;
  while (std::getline(stream, part, '/')) {
    if (part.empty() || part == "." || part == ".." || part[0] == '.')
      return false;
  }
  return true;
}

static bool safeUploadPath(const std::string &path) {
  if (path == "manifest.json" || path == "pack.zip")
    return true;
  return startsWith(path, "VECTMAP/") && safeRelativePath(path);
}

static bool fileSize(const std::string &path, uint64_t &size) {
  struct stat st;
  if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode))
    return false;
  size = static_cast<uint64_t>(st.st_size);
  return true;
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
    stateMutex_ = xSemaphoreCreateMutex();
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
  return transferServer_->setEnabled(enabled, enabled ? "map" : "");
}

void MapTransferHttpServer::setLastError(const std::string &code,
                                         const std::string &message) {
  transferServer_->setLastError(code, message);
}

void MapTransferHttpServer::process() { transferServer_->process(); }

HttpTransferStatus MapTransferHttpServer::status() const {
  return transferServer_->status();
}

bool MapTransferHttpServer::handleRequest(
    const device_transfer::HttpRequest &request, WiFiClient &client) {
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
  if (request.method == "HEAD" && handleHead(request.path, client))
    return true;
  if (request.method == "PUT" &&
      handleInstallStream(request, client))
    return true;
  if (request.method == "PUT" &&
      handlePut(request, client))
    return true;
  if (request.method == "POST" && handleActivate(request, client))
    return true;
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
    if (deferred.activationAlreadyBegun) {
      finishActivation("failed", "", "transfer_cancelled",
                       "activation authorization was revoked before the "
                       "response completed");
    }
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

bool MapTransferHttpServer::handleHead(const std::string &path,
                                       WiFiClient &client) {
  std::string sessionId;
  std::string relativePath;
  if (!parseSessionPath(path, sessionId, relativePath))
    return false;
  if (!safeUploadPath(relativePath)) {
    sendHead(client, 400);
    return true;
  }
  lockState();
  const bool acceptsUploads = activationState_.acceptsUploads();
  unlockState();
  if (!acceptsUploads) {
    sendHead(client, 409);
    return true;
  }
  if (installer_.hasInterruptedActivation()) {
    lockState();
    const bool recoveryBlocked = recoveryBlocked_;
    unlockState();
    if (recoveryBlocked) {
      sendHead(client, 500);
      return true;
    }
    // Complete the zero-length response before the exceptional recovery hash.
    // The client uses this explicit 503 to distinguish SD recovery from an
    // ordinary Wi-Fi timeout while this single-threaded server is occupied.
    sendHead(client, 503);
    InstallStatus recovery = installer_.recoverInterruptedActivation();
    lockState();
    recoveryBlocked_ = !recovery.ok;
    unlockState();
    if (!recovery.ok)
      setLastError(recovery.code, recovery.message);
    return true;
  }
  InstallStatus recovery = installer_.recoverInterruptedActivation();
  if (!recovery.ok) {
    sendHead(client, 500);
    return true;
  }
  lockState();
  recoveryBlocked_ = false;
  unlockState();

  if (relativePath == "pack.zip") {
    uint64_t archiveSize = 0;
    if (!fileSize(installer_.stagedArchivePath(sessionId), archiveSize)) {
      sendHead(client, 404);
      return true;
    }
    sendHead(client, 200, archiveSize);
    return true;
  }

  const std::string stagedPath =
      joinPath(installer_.stagingRoot(sessionId), relativePath);
  uint64_t size = 0;
  if (!fileSize(stagedPath, size)) {
    sendHead(client, 404);
    return true;
  }
  if (relativePath == "manifest.json") {
    MapManifest manifest;
    if (!installer_.readStagedManifest(sessionId, manifest).ok) {
      sendHead(client, 404);
      return true;
    }
  } else {
    ManifestFile expected;
    InstallStatus declared =
        installer_.expectedStagedFile(sessionId, relativePath, expected);
    if (!declared.ok || !installer_.stagedFileVerified(sessionId, expected)) {
      sendHead(client, 404);
      return true;
    }
  }
  sendHead(client, 200, size);
  return true;
}

bool MapTransferHttpServer::handleInstallStream(
    const device_transfer::HttpRequest &request, WiFiClient &client) {
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
  const bool acceptsUploads = activationState_.acceptsUploads();
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
  if (!deferActivationUntilResponse(request, sessionId, true,
                                    minimumActivationSequence)) {
    setLastError("activation_handoff",
                 "verified map stream activation could not be deferred");
  }
  return true;
}

bool MapTransferHttpServer::handlePut(
    const device_transfer::HttpRequest &request, WiFiClient &client) {
  const std::string &path = request.path;
  const uint64_t contentLength = request.contentLength;
  std::string sessionId;
  std::string relativePath;
  if (!parseSessionPath(path, sessionId, relativePath))
    return false;
  if (!safeUploadPath(relativePath)) {
    sendError(client, 400, "path", "upload path is invalid");
    return true;
  }
  const bool isArchive = relativePath == "pack.zip";
  const uint64_t maxUploadBytes =
      isArchive ? kMaxArchiveUploadBytes : kMaxUploadBytes;
  if (contentLength == 0 || contentLength > maxUploadBytes) {
    sendError(client, 413, "content_length", "upload size is invalid");
    return true;
  }
  lockState();
  const bool acceptsUploads = activationState_.acceptsUploads();
  unlockState();
  if (!acceptsUploads) {
    sendError(client, 409, "activation_busy",
              "map files cannot change while activation is running");
    return true;
  }
  InstallStatus recovery = installer_.recoverInterruptedActivation();
  if (!recovery.ok) {
    sendError(client, 503, recovery.code, recovery.message);
    return true;
  }

  ManifestFile expectedFile;
  const bool isManifest = relativePath == "manifest.json";
  if (!isManifest && !isArchive) {
    InstallStatus declared =
        installer_.expectedStagedFile(sessionId, relativePath, expectedFile);
    if (!declared.ok) {
      sendError(client, 400, declared.code, declared.message);
      return true;
    }
    if (contentLength != expectedFile.bytes) {
      sendError(client, 400, "file_size",
                "upload size does not match the staged manifest");
      return true;
    }
    installer_.clearStagedFileVerification(sessionId, expectedFile);
  }
  const std::string destination = isArchive
                                      ? installer_.stagedArchivePath(sessionId)
                                      : joinPath(installer_.stagingRoot(sessionId),
                                                 relativePath);
  if (!mkdirs(dirnameOf(destination))) {
    sendError(client, 500, "mkdir", "could not create staging directory");
    return true;
  }

  std::ofstream output(destination, std::ios::binary | std::ios::trunc);
  if (!output) {
    sendError(client, 500, "open", "could not open staged file");
    return true;
  }

  uint8_t buffer[1024];
  Sha256Hasher hasher;
  std::unique_ptr<map_block_format::StreamValidator> rendererValidator;
  if (!isManifest && !isArchive) {
    rendererValidator.reset(
        new (std::nothrow) map_block_format::StreamValidator(relativePath));
    if (!rendererValidator || rendererValidator->failed()) {
      output.close();
      ::unlink(destination.c_str());
      sendError(client, 400, "file_renderer_format",
                "could not initialize map block validation");
      return true;
    }
  }
  uint64_t remaining = contentLength;
  uint32_t lastRead = millis();
  while (remaining > 0) {
    if (!transferServer_->isRequestAuthorized(request)) {
      sendError(client, 409, "transfer_cancelled",
                "map transfer authorization was revoked");
      return true;
    }
    int available = client.available();
    if (available <= 0) {
      if (millis() - lastRead > 10000) {
        sendError(client, 408, "upload_timeout", "upload body timed out");
        return true;
      }
      delay(1);
      continue;
    }
    size_t toRead = std::min<uint64_t>(
        std::min<uint64_t>(remaining, sizeof(buffer)),
        static_cast<uint64_t>(available));
    int read = client.read(buffer, toRead);
    if (read <= 0)
      continue;
    if (!isManifest && !isArchive) {
      hasher.update(buffer, static_cast<size_t>(read));
      if (!rendererValidator->feed(buffer, static_cast<size_t>(read))) {
        output.close();
        ::unlink(destination.c_str());
        sendError(client, 400, "file_renderer_format",
                  "uploaded map file is not renderer-compatible");
        return true;
      }
    }
    output.write(reinterpret_cast<const char *>(buffer), read);
    if (!output) {
      sendError(client, 500, "write", "could not write staged file");
      return true;
    }
    remaining -= static_cast<uint64_t>(read);
    lastRead = millis();
  }
  if (!transferServer_->isRequestAuthorized(request)) {
    sendError(client, 409, "transfer_cancelled",
              "map transfer authorization was revoked");
    return true;
  }
  output.close();
  if (!output.good()) {
    sendError(client, 500, "write", "could not finish staged file");
    return true;
  }
  if (isArchive) {
    if (!installer_.pruneStagingSessions(sessionId) ||
        !installer_.pruneObsoleteInstalledMaps()) {
      ::unlink(destination.c_str());
      sendError(client, 500, "staging_cleanup",
                "could not prune obsolete map transfers");
      return true;
    }
  } else if (isManifest) {
    MapManifest manifest;
    InstallStatus parsed = installer_.readStagedManifest(sessionId, manifest);
    if (!parsed.ok) {
      ::unlink(destination.c_str());
      sendError(client, 400, parsed.code, parsed.message);
      return true;
    }
    if (!installer_.pruneStagingSessions(sessionId) ||
        !installer_.pruneObsoleteInstalledMaps()) {
      ::unlink(destination.c_str());
      sendError(client, 500, "staging_cleanup",
                "could not prune obsolete map transfers");
      return true;
    }
  } else {
    if (!rendererValidator->finish()) {
      ::unlink(destination.c_str());
      sendError(client, 400, "file_renderer_format",
                "uploaded map file is not renderer-compatible");
      return true;
    }
    std::string actualSha = hasher.finalHex();
    std::string expectedSha = expectedFile.sha256;
    std::transform(expectedSha.begin(), expectedSha.end(), expectedSha.begin(),
                   ::tolower);
    if (actualSha != expectedSha) {
      ::unlink(destination.c_str());
      sendError(client, 400, "file_sha256",
                "uploaded map file sha256 mismatch");
      return true;
    }
    if (!installer_.markStagedFileVerified(sessionId, expectedFile)) {
      ::unlink(destination.c_str());
      sendError(client, 500, "file_receipt",
                "could not record uploaded map verification");
      return true;
    }
  }

  if (isArchive && !installer_.markPendingArchiveActivation(sessionId)) {
    installer_.discardStagedSession(sessionId);
    sendError(client, 500, "activation_marker",
              "could not persist pending archive activation");
    return true;
  }

  Serial.printf("MAP_TRANSFER_HTTP: staged session=%s path=%s bytes=%llu\n",
                sessionId.c_str(), relativePath.c_str(),
                static_cast<unsigned long long>(contentLength));
  const bool responseQueued =
      sendJson(client, 200,
               std::string("{\"ok\":true,\"sessionId\":\"") +
                   jsonEscape(sessionId) + "\",\"path\":\"" +
                   jsonEscape(relativePath) + "\"}");
  if (isArchive) {
    // A background URLSession upload can outlive the iOS process that started
    // it. Activation remains device-owned, but starts only after the response
    // has crossed the graceful HTTP-close boundary.
    if (!responseQueued) {
      setLastError("http_response_write",
                   "verified map archive response could not be written");
    } else if (!deferActivationUntilResponse(request, sessionId, false)) {
      setLastError("activation_handoff",
                   "verified map archive activation could not be deferred");
    }
  }
  return true;
}

bool MapTransferHttpServer::handleActivate(
    const device_transfer::HttpRequest &request, WiFiClient &client) {
  std::string sessionId;
  std::string action;
  if (!parseSessionPath(request.path, sessionId, action))
    return false;
  if (action != "activate")
    return false;

  lockState();
  ActivationBeginResult beginResult = activationState_.begin(sessionId);
  if (beginResult == ActivationBeginResult::Started)
    streamStatusActive_ = false;
  const uint32_t activationSequence = activationState_.snapshot().sequence;
  unlockState();
  const auto activatingResponse = [&]() {
    return std::string("{\"ok\":true,\"status\":\"activating\",\"sessionId\":\"") +
           jsonEscape(sessionId) + "\",\"sequence\":" +
           std::to_string(activationSequence) + "}";
  };
  if (beginResult == ActivationBeginResult::AlreadyRunning) {
    sendJson(client, 202, activatingResponse());
    return true;
  }
  if (beginResult == ActivationBeginResult::AlreadyInstalled) {
    sendJson(client, 200,
             std::string("{\"ok\":true,\"status\":\"installed\",\"sessionId\":\"") +
                 jsonEscape(sessionId) + "\",\"sequence\":" +
                 std::to_string(activationSequence) + "}");
    return true;
  }
  if (beginResult == ActivationBeginResult::Busy) {
    sendError(client, 409, "activation_busy",
              "another map activation is already running");
    return true;
  }

  if (!deferActivationUntilResponse(request, sessionId, false,
                                    activationSequence, true, false)) {
    finishActivation("failed", "", "activation_handoff",
                     "activation could not be deferred until the response "
                     "completed");
    sendError(client, 500, "activation_handoff",
              "activation could not be deferred until the response completed");
    return true;
  }
  sendJson(client, 202, activatingResponse());
  return true;
}

InstallStatus MapTransferHttpServer::supersedeRecoverableStreamForArchive() {
  MapStreamInstallSnapshot stream;
  const MapStreamRecoveryResult recovery =
      readRecoverableMapStreamInstall(storageRoot_, stream);
  if (recovery == MapStreamRecoveryResult::None)
    return {true, "stream_none", ""};
  if (recovery != MapStreamRecoveryResult::Found) {
    return installer_.discardAllUnselectedStreamMaps();
  }
  const InstallStatus discarded =
      installer_.discardUnselectedStreamMap(stream.sessionId);
  if (!discarded.ok)
    return discarded;
  updateStreamInstallState(MapStreamInstallSnapshot(), false);
  return discarded;
}

void MapTransferHttpServer::handleStatus(WiFiClient &client) {
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
                     ",\"protocols\":[1" +
                     (streamSupported ? ",2" : "") + "]";
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
      body += activeMap.target.formatVersion == 2 ? "true" : "false";
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

void MapTransferHttpServer::sendHead(WiFiClient &client, int status,
                                     uint64_t contentLength) {
  device_transfer::sendHttpHead(client, status, contentLength);
}

bool MapTransferHttpServer::sendJson(WiFiClient &client, int status,
                                     const std::string &body) {
  return device_transfer::sendHttpJson(client, status, body);
}

void MapTransferHttpServer::sendError(WiFiClient &client, int status,
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

bool MapTransferHttpServer::takeActivatedMapRoot(std::string &root) {
  lockState();
  if (pendingMapRoot_.empty() ||
      (pendingRendererAcknowledgement_ && pendingMapRootTaken_)) {
    unlockState();
    return false;
  }
  root = pendingMapRoot_;
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
  const std::string sessionId = pendingMapSessionId_;
  const std::string mapId = pendingMapId_;
  const bool automaticExit = pendingRendererAutomaticExit_;
  const bool streamProtocol = pendingRendererStreamProtocol_;
  pendingMapRoot_.clear();
  pendingMapSessionId_.clear();
  pendingMapId_.clear();
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = false;
  pendingRendererAutomaticExit_ = false;
  pendingRendererStreamProtocol_ = false;
  unlockState();

  if (loaded) {
    finishActivation("installed", mapId, "", "");
  } else {
    const InstallStatus rollback = installer_.rollbackActiveMap(sessionId);
    const std::string message =
        rollback.ok
            ? std::string("renderer rejected the new map root; ") +
                  rollback.message
            : std::string("renderer rejected the new map root; rollback failed: ") +
                  rollback.message;
    finishActivation("failed", mapId, "renderer_reload", message);
  }
  if (!streamProtocol &&
      !installer_.clearPendingArchiveActivation()) {
    setLastError("activation_marker",
                 "could not clear pending archive activation");
  }
  if (automaticExit)
    requestAutomaticExit();
}

bool MapTransferHttpServer::takeAutomaticExitRequest() {
  lockState();
  const bool requested = pendingAutomaticExit_;
  pendingAutomaticExit_ = false;
  unlockState();
  return requested;
}

bool MapTransferHttpServer::resumePendingArchiveActivation() {
  std::string sessionId;
  if (!installer_.readPendingArchiveActivation(sessionId))
    return false;

  ActiveMapSelection active;
  if (installer_.readActiveMap(active).ok && active.sessionId == sessionId) {
    if (!installer_.discardStagedSession(sessionId) ||
        !installer_.clearPendingArchiveActivation()) {
      setLastError("staging_cleanup",
                   "could not clean completed pending archive");
    }
    return false;
  }

  lockState();
  const ActivationBeginResult beginResult = activationState_.begin(sessionId);
  if (beginResult == ActivationBeginResult::Started)
    streamStatusActive_ = false;
  unlockState();
  if (beginResult == ActivationBeginResult::Started) {
    Serial.printf("MAP_TRANSFER_HTTP: resuming pending archive session=%s\n",
                  sessionId.c_str());
    return startActivationTask(sessionId, true);
  }
  return false;
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
    return startActivationTask(snapshot.sessionId, true, true);
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
  bool archivePending =
      installer_.readPendingArchiveActivation(archiveSessionId);
  bool readyStream = streamRecovery == MapStreamRecoveryResult::Found &&
                     streamSnapshot.state == MapStreamInstallState::Ready;
  if (archivePending && streamRecovery != MapStreamRecoveryResult::None) {
    const InstallStatus discarded =
        streamRecovery == MapStreamRecoveryResult::Found
            ? installer_.discardUnselectedStreamMap(streamSnapshot.sessionId)
            : installer_.discardAllUnselectedStreamMaps();
    if (!discarded.ok) {
      setLastError(discarded.code, discarded.message);
      return;
    }
    updateStreamInstallState(MapStreamInstallSnapshot(), false);
    readyStream = false;
  }
  if (archivePending && resumePendingArchiveActivation())
    return;
  if (readyStream)
    resumePendingStreamActivation(&streamSnapshot);
}

void MapTransferHttpServer::requestAutomaticExit() {
  lockState();
  pendingAutomaticExit_ = true;
  unlockState();
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
}

void MapTransferHttpServer::finishActivation(const std::string &status,
                                             const std::string &mapId,
                                             const std::string &errorCode,
                                             const std::string &errorMessage) {
  lockState();
  activationState_.finish(status, mapId, errorCode, errorMessage);
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
}

bool MapTransferHttpServer::startActivationTask(const std::string &sessionId,
                                                bool automaticExit,
                                                bool streamProtocol) {
  auto *context = new ActivationTaskContext{this, sessionId, automaticExit,
                                            streamProtocol};
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
  Serial.printf("MAP_TRANSFER_HTTP: activation queued session=%s automatic=%d "
                "protocol=%d\n",
                sessionId.c_str(), automaticExit, streamProtocol ? 2 : 1);
  return true;
}

bool MapTransferHttpServer::deferActivationUntilResponse(
    const device_transfer::HttpRequest &request, const std::string &sessionId,
    bool streamProtocol, uint32_t minimumSequence,
    bool activationAlreadyBegun, bool automaticExitOnCleanResponse) {
  lockState();
  if (deferredActivation_.pending()) {
    unlockState();
    return false;
  }
  deferredActivation_.response = {
      request.transferGeneration, request.method, request.path};
  deferredActivation_.sessionId = sessionId;
  deferredActivation_.minimumSequence = minimumSequence;
  deferredActivation_.streamProtocol = streamProtocol;
  deferredActivation_.activationAlreadyBegun = activationAlreadyBegun;
  deferredActivation_.automaticExitOnCleanResponse =
      automaticExitOnCleanResponse;
  unlockState();
  return true;
}

void MapTransferHttpServer::beginDeferredActivation(
    const DeferredActivation &activation, bool peerClosedCleanly) {
  lockState();
  ActivationBeginResult beginResult = ActivationBeginResult::Started;
  if (!activation.activationAlreadyBegun) {
    beginResult = activation.streamProtocol
                      ? activationState_.begin(activation.sessionId, 3,
                                               activation.minimumSequence)
                      : activationState_.begin(activation.sessionId);
  }
  if (beginResult == ActivationBeginResult::Started) {
    if (activation.streamProtocol)
      activationState_.updateProgress({3, 3, 0, 1});
    streamStatusActive_ = false;
  }
  unlockState();

  if (beginResult == ActivationBeginResult::Started) {
    // responseDidComplete runs on the existing 16 KiB transfer worker after
    // the upload handler and stream parser have unwound. Activation needs the
    // same stack budget, so execute it here instead of allocating a second
    // 16 KiB task at the firmware's peak map-transfer memory watermark.
    const bool automaticExit = activation.automaticExitOnCleanResponse &&
                               peerClosedCleanly;
    executeActivation(activation.sessionId, automaticExit,
                      activation.streamProtocol);
    return;
  }
  if (beginResult == ActivationBeginResult::AlreadyInstalled) {
    if (activation.streamProtocol) {
      const InstallStatus cleaned =
          installer_.activateReadyStreamMap(activation.sessionId);
      if (!cleaned.ok)
        setLastError(cleaned.code, cleaned.message);
    } else if (!installer_.discardStagedSession(activation.sessionId) ||
               !installer_.clearPendingArchiveActivation()) {
      setLastError("staging_cleanup",
                   "could not remove redundant installed archive");
    }
    if (activation.automaticExitOnCleanResponse && peerClosedCleanly)
      requestAutomaticExit();
    return;
  }
  if (beginResult == ActivationBeginResult::Busy) {
    setLastError("activation_busy",
                 "another map activation started after upload completion");
  }
}

void MapTransferHttpServer::executeActivation(const std::string &sessionId,
                                              bool automaticExit,
                                              bool streamProtocol) {
  power_management::ScopedLock powerLock(
      power_management::LockDomain::Transfer);
  const bool waitingForRenderer =
      streamProtocol ? runStreamActivationTask(sessionId, automaticExit)
                     : runActivationTask(sessionId, automaticExit);
  if (waitingForRenderer)
    return;
  if (!streamProtocol && !installer_.clearPendingArchiveActivation()) {
    setLastError("activation_marker",
                 "could not clear pending archive activation");
  }
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
  pendingMapRoot_ = selected.root;
  pendingMapSessionId_ = selected.sessionId;
  pendingMapId_ = selected.mapId;
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = true;
  pendingRendererAutomaticExit_ = automaticExit;
  pendingRendererStreamProtocol_ = true;
  activationState_.updateProgress({3, 3, 2, 3});
  unlockState();
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  return true;
}

bool MapTransferHttpServer::runActivationTask(const std::string &sessionId,
                                              bool automaticExit) {
  Serial.printf("MAP_TRANSFER_HTTP: activate start session=%s\n",
                sessionId.c_str());
  InstallStatus recovery = installer_.recoverInterruptedActivation();
  if (!recovery.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: recovery failed code=%s message=%s\n",
                  recovery.code.c_str(), recovery.message.c_str());
    finishActivation("failed", "", recovery.code, recovery.message);
    return false;
  }
  const auto onProgress = [this](const ActivationProgress &progress) {
    updateActivationProgress(progress);
  };
  InstallStatus prepared =
      installer_.prepareStagedArchive(sessionId, onProgress);
  if (!prepared.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: archive preparation failed code=%s message=%s\n",
                  prepared.code.c_str(), prepared.message.c_str());
    finishActivation("failed", "", prepared.code, prepared.message);
    ::unlink(installer_.stagedArchivePath(sessionId).c_str());
    return false;
  }

  MapManifest manifest;
  InstallStatus validated =
      installer_.validateStagedMap(sessionId, manifest, onProgress);
  if (!validated.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: activate validation failed code=%s message=%s\n",
                  validated.code.c_str(), validated.message.c_str());
    finishActivation("failed", "", validated.code, validated.message);
    ::unlink(installer_.stagedArchivePath(sessionId).c_str());
    return false;
  }

  const InstallStatus superseded =
      supersedeRecoverableStreamForArchive();
  if (!superseded.ok) {
    finishActivation("failed", manifest.mapId, superseded.code,
                     superseded.message);
    return false;
  }

  InstallStatus activated =
      installer_.activateStagedMap(sessionId, manifest, onProgress);
  if (!activated.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: activate failed code=%s message=%s\n",
                  activated.code.c_str(), activated.message.c_str());
    finishActivation("failed", manifest.mapId, activated.code,
                     activated.message);
    return false;
  }

  Serial.printf("MAP_TRANSFER_HTTP: activated mapId=%s session=%s\n",
                manifest.mapId.c_str(), sessionId.c_str());
  ActiveMapSelection selected;
  InstallStatus active = installer_.readActiveMap(selected);
  if (!active.ok) {
    finishActivation("failed", manifest.mapId, active.code, active.message);
    return false;
  }
  lockState();
  pendingMapRoot_ = selected.root;
  pendingMapSessionId_ = selected.sessionId;
  pendingMapId_ = selected.mapId;
  pendingMapRootTaken_ = false;
  pendingRendererAcknowledgement_ = true;
  pendingRendererAutomaticExit_ = automaticExit;
  pendingRendererStreamProtocol_ = false;
  activationState_.updateProgress({5, 5, 4, 5});
  unlockState();
  ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
  return true;
}

void MapTransferHttpServer::activationTaskThunk(void *arg) {
  auto *context = static_cast<ActivationTaskContext *>(arg);
  if (context != nullptr && context->server != nullptr) {
    MapTransferHttpServer *server = context->server;
    std::string sessionId = context->sessionId;
    const bool automaticExit = context->automaticExit;
    const bool streamProtocol = context->streamProtocol;
    delete context;
    server->executeActivation(sessionId, automaticExit, streamProtocol);
  } else {
    delete context;
  }
  vTaskDelete(nullptr);
}

} // namespace map_transfer
