#include "map_transfer_http.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <freertos/task.h>

namespace map_transfer {
namespace {

constexpr const char *kStatusPath = "/map-transfer/status";
constexpr const char *kSessionPrefix = "/map-transfer/sessions/";
constexpr uint64_t kMaxUploadBytes = 128ULL * 1024ULL * 1024ULL;

struct ActivationTaskContext {
  MapTransferHttpServer *server = nullptr;
  std::string sessionId;
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
  if (path == "manifest.json")
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
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutex();
  transferServer_ = sharedServer == nullptr ? &ownedTransferServer_ : sharedServer;
  if (sharedServer == nullptr)
    transferServer_->configure(port, "BikeComputer-Transfer");
  transferServer_->registerHandler("/map-transfer", this);
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
  if (request.method == "GET" && request.path == kStatusPath) {
    handleStatus(client);
    return true;
  }
  if (status().mode != "map") {
    sendError(client, 403, "transfer_mode_mismatch",
              "map transfer mode is not active");
    return true;
  }
  Serial.printf("MAP_TRANSFER_HTTP: %s %s length=%llu\n",
                request.method.c_str(), request.path.c_str(),
                static_cast<unsigned long long>(request.contentLength));
  if (request.method == "HEAD" && handleHead(request.path, client))
    return true;
  if (request.method == "PUT" &&
      handlePut(request.path, request.contentLength, client))
    return true;
  if (request.method == "POST" && handleActivate(request.path, client))
    return true;
  return false;
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

bool MapTransferHttpServer::handlePut(const std::string &path,
                                      uint64_t contentLength,
                                      WiFiClient &client) {
  std::string sessionId;
  std::string relativePath;
  if (!parseSessionPath(path, sessionId, relativePath))
    return false;
  if (!safeUploadPath(relativePath)) {
    sendError(client, 400, "path", "upload path is invalid");
    return true;
  }
  if (contentLength == 0 || contentLength > kMaxUploadBytes) {
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
  if (!isManifest) {
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
  const std::string destination =
      joinPath(installer_.stagingRoot(sessionId), relativePath);
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
  uint64_t remaining = contentLength;
  uint32_t lastRead = millis();
  while (remaining > 0) {
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
    if (!isManifest)
      hasher.update(buffer, static_cast<size_t>(read));
    output.write(reinterpret_cast<const char *>(buffer), read);
    if (!output) {
      sendError(client, 500, "write", "could not write staged file");
      return true;
    }
    remaining -= static_cast<uint64_t>(read);
    lastRead = millis();
  }
  output.close();
  if (!output.good()) {
    sendError(client, 500, "write", "could not finish staged file");
    return true;
  }
  if (isManifest) {
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

  Serial.printf("MAP_TRANSFER_HTTP: staged session=%s path=%s bytes=%llu\n",
                sessionId.c_str(), relativePath.c_str(),
                static_cast<unsigned long long>(contentLength));
  sendJson(client, 200,
           std::string("{\"ok\":true,\"sessionId\":\"") +
               jsonEscape(sessionId) + "\",\"path\":\"" +
               jsonEscape(relativePath) + "\"}");
  return true;
}

bool MapTransferHttpServer::handleActivate(const std::string &path,
                                           WiFiClient &client) {
  std::string sessionId;
  std::string action;
  if (!parseSessionPath(path, sessionId, action))
    return false;
  if (action != "activate")
    return false;

  lockState();
  ActivationBeginResult beginResult = activationState_.begin(sessionId);
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
  if (beginResult == ActivationBeginResult::Busy) {
    sendError(client, 409, "activation_busy",
              "another map activation is already running");
    return true;
  }

  auto *context = new ActivationTaskContext{this, sessionId};
  BaseType_t created = xTaskCreate(activationTaskThunk, "map_activate", 16384,
                                   context, 1, nullptr);
  if (created != pdPASS) {
    delete context;
    finishActivation("failed", "", "activation_task",
                     "could not start activation task");
    sendError(client, 500, "activation_task",
              "could not start activation task");
    return true;
  }

  Serial.printf("MAP_TRANSFER_HTTP: activation queued session=%s\n",
                sessionId.c_str());
  sendJson(client, 202, activatingResponse());
  return true;
}

void MapTransferHttpServer::handleStatus(WiFiClient &client) {
  ActiveMapSelection activeMap;
  InstallStatus active = installer_.readActiveMap(activeMap);
  HttpTransferStatus transferStatus = status();

  std::string body = std::string("{\"configured\":") +
                     (transferStatus.configured ? "true" : "false") +
                     ",\"enabled\":" +
                     (transferStatus.enabled ? "true" : "false") +
                     ",\"port\":" + std::to_string(transferStatus.port);
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

void MapTransferHttpServer::sendJson(WiFiClient &client, int status,
                                     const std::string &body) {
  device_transfer::sendHttpJson(client, status, body);
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
  std::string body = activationState_.json(compact);
  unlockState();
  return body;
}

bool MapTransferHttpServer::activationHasError() const {
  lockState();
  const bool hasError = !activationState_.snapshot().errorCode.empty();
  unlockState();
  return hasError;
}

bool MapTransferHttpServer::takeActivatedMapRoot(std::string &root) {
  lockState();
  if (pendingMapRoot_.empty()) {
    unlockState();
    return false;
  }
  root = pendingMapRoot_;
  pendingMapRoot_.clear();
  unlockState();
  return true;
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
}

void MapTransferHttpServer::runActivationTask(const std::string &sessionId) {
  Serial.printf("MAP_TRANSFER_HTTP: activate start session=%s\n",
                sessionId.c_str());
  InstallStatus recovery = installer_.recoverInterruptedActivation();
  if (!recovery.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: recovery failed code=%s message=%s\n",
                  recovery.code.c_str(), recovery.message.c_str());
    finishActivation("failed", "", recovery.code, recovery.message);
    return;
  }
  MapManifest manifest;
  InstallStatus validated = installer_.validateStagedMap(sessionId, manifest);
  if (!validated.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: activate validation failed code=%s message=%s\n",
                  validated.code.c_str(), validated.message.c_str());
    finishActivation("failed", "", validated.code, validated.message);
    return;
  }

  InstallStatus activated = installer_.activateStagedMap(sessionId, manifest);
  if (!activated.ok) {
    Serial.printf("MAP_TRANSFER_HTTP: activate failed code=%s message=%s\n",
                  activated.code.c_str(), activated.message.c_str());
    finishActivation("failed", manifest.mapId, activated.code,
                     activated.message);
    return;
  }

  Serial.printf("MAP_TRANSFER_HTTP: activated mapId=%s session=%s\n",
                manifest.mapId.c_str(), sessionId.c_str());
  ActiveMapSelection selected;
  InstallStatus active = installer_.readActiveMap(selected);
  if (!active.ok) {
    finishActivation("failed", manifest.mapId, active.code, active.message);
    return;
  }
  lockState();
  pendingMapRoot_ = selected.root;
  unlockState();
  finishActivation("installed", manifest.mapId, "", "");
}

void MapTransferHttpServer::activationTaskThunk(void *arg) {
  auto *context = static_cast<ActivationTaskContext *>(arg);
  if (context != nullptr && context->server != nullptr) {
    MapTransferHttpServer *server = context->server;
    std::string sessionId = context->sessionId;
    delete context;
    server->runActivationTask(sessionId);
  } else {
    delete context;
  }
  vTaskDelete(nullptr);
}

} // namespace map_transfer
