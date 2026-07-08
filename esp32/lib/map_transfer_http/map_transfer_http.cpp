#include "map_transfer_http.hpp"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstring>
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

static std::string trim(const std::string &value) {
  size_t begin = 0;
  while (begin < value.size() &&
         std::isspace(static_cast<unsigned char>(value[begin]))) {
    begin++;
  }
  size_t end = value.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(value[end - 1]))) {
    end--;
  }
  return value.substr(begin, end - begin);
}

static std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
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

static bool readLine(WiFiClient &client, std::string &line,
                     uint32_t timeoutMs = 2000) {
  line.clear();
  uint32_t started = millis();
  while (millis() - started < timeoutMs) {
    while (client.available()) {
      char c = static_cast<char>(client.read());
      if (c == '\r')
        continue;
      if (c == '\n')
        return true;
      if (line.size() < 512)
        line.push_back(c);
    }
    delay(1);
  }
  return false;
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

void MapTransferHttpServer::configure(std::string storageRoot, uint16_t port) {
  storageRoot_ = std::move(storageRoot);
  if (!storageRoot_.empty() && storageRoot_.back() == '/')
    storageRoot_.pop_back();
  port_ = port;
  server_ = WiFiServer(port_);
  installer_ = MapTransferInstaller(storageRoot_);
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutex();
  configured_ = true;
}

bool MapTransferHttpServer::setEnabled(bool enabled) {
  if (!configured_)
    configure(storageRoot_, port_);
  lockState();
  const bool wasEnabled = enabled_;
  const bool wasStartedAp = startedAp_;
  unlockState();

  if (enabled && !wasEnabled) {
    if (WiFi.status() != WL_CONNECTED) {
      const std::string apSsid = "BikeComputer-Map";
      WiFi.mode(WIFI_AP);
      if (!WiFi.softAP(apSsid.c_str())) {
        lockState();
        rememberError("wifi_ap", "could not start transfer Wi-Fi");
        unlockState();
        return false;
      }
      lockState();
      startedAp_ = true;
      apSsid_ = apSsid;
      unlockState();
      Serial.printf("MAP_TRANSFER_HTTP: started AP ssid=%s ip=%s\n",
                    apSsid.c_str(), WiFi.softAPIP().toString().c_str());
    }
    server_.begin();
    server_.setNoDelay(true);
  }
  if (!enabled && wasEnabled) {
    server_.stop();
    if (wasStartedAp) {
      WiFi.softAPdisconnect(true);
      WiFi.mode(WIFI_OFF);
      lockState();
      startedAp_ = false;
      apSsid_.clear();
      unlockState();
    }
  }
  lockState();
  enabled_ = enabled;
  unlockState();
  return true;
}

void MapTransferHttpServer::setLastError(const std::string &code,
                                         const std::string &message) {
  lockState();
  rememberError(code, message);
  unlockState();
}

void MapTransferHttpServer::process() {
  if (!enabled_)
    return;
  WiFiClient client = server_.accept();
  if (!client)
    return;
  handleClient(client);
  client.stop();
}

HttpTransferStatus MapTransferHttpServer::status() const {
  lockState();
  const bool configured = configured_;
  const bool enabled = enabled_;
  const bool startedAp = startedAp_;
  const uint16_t port = port_;
  const std::string apSsid = apSsid_;
  const std::string lastErrorCode = lastErrorCode_;
  const std::string lastErrorMessage = lastErrorMessage_;
  unlockState();

  std::string baseUrl;
  if (enabled) {
    IPAddress ip =
        startedAp ? WiFi.softAPIP() : (WiFi.status() == WL_CONNECTED
                                           ? WiFi.localIP()
                                           : IPAddress());
    if (ip != IPAddress()) {
      baseUrl = std::string("http://") + ip.toString().c_str() + ":" +
                std::to_string(port);
    }
  }
  return {configured, enabled, port, baseUrl, apSsid, lastErrorCode,
          lastErrorMessage};
}

void MapTransferHttpServer::handleClient(WiFiClient &client) {
  std::string requestLine;
  if (!readLine(client, requestLine)) {
    sendError(client, 408, "timeout", "request timed out");
    return;
  }
  std::stringstream requestStream(requestLine);
  std::string method;
  std::string path;
  std::string version;
  requestStream >> method >> path >> version;
  if (method.empty() || path.empty()) {
    sendError(client, 400, "bad_request", "invalid request line");
    return;
  }

  uint64_t contentLength = 0;
  std::string line;
  while (readLine(client, line)) {
    if (line.empty())
      break;
    size_t colon = line.find(':');
    if (colon == std::string::npos)
      continue;
    std::string name = lower(trim(line.substr(0, colon)));
    std::string value = trim(line.substr(colon + 1));
    if (name == "content-length")
      contentLength = strtoull(value.c_str(), nullptr, 10);
  }

  if (method == "GET" && path == kStatusPath) {
    handleStatus(client);
    return;
  }
  if (!enabled_) {
    sendError(client, 403, "transfer_disabled", "map transfer mode is disabled");
    return;
  }
  Serial.printf("MAP_TRANSFER_HTTP: %s %s length=%llu\n", method.c_str(),
                path.c_str(), static_cast<unsigned long long>(contentLength));
  if (method == "HEAD" && handleHead(path, client))
    return;
  if (method == "PUT" && handlePut(path, contentLength, client))
    return;
  if (method == "POST" && handleActivate(path, client))
    return;
  sendError(client, 404, "not_found", "map transfer endpoint not found");
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

  const std::string stagedPath =
      joinPath(installer_.stagingRoot(sessionId), relativePath);
  uint64_t size = 0;
  if (!fileSize(stagedPath, size)) {
    sendHead(client, 404);
    return true;
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
  if (activationRunning_) {
    const bool sameSession = activationSessionId_ == sessionId;
    unlockState();
    if (sameSession) {
      sendJson(client, 202,
               std::string("{\"ok\":true,\"status\":\"activating\",\"sessionId\":\"") +
                   jsonEscape(sessionId) + "\"}");
      return true;
    }
    sendError(client, 409, "activation_busy",
              "another map activation is already running");
    return true;
  }
  activationRunning_ = true;
  activationSessionId_ = sessionId;
  activationStatus_ = "activating";
  activationMapId_.clear();
  activationErrorCode_.clear();
  activationErrorMessage_.clear();
  unlockState();

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
  sendJson(client, 202,
           std::string("{\"ok\":true,\"status\":\"activating\",\"sessionId\":\"") +
               jsonEscape(sessionId) + "\"}");
  return true;
}

void MapTransferHttpServer::handleStatus(WiFiClient &client) {
  std::string activeMapId;
  InstallStatus active = installer_.readActiveMapId(activeMapId);
  lockState();
  const bool configured = configured_;
  const bool enabled = enabled_;
  const uint16_t port = port_;
  const std::string lastErrorCode = lastErrorCode_;
  const std::string lastErrorMessage = lastErrorMessage_;
  unlockState();

  std::string body = std::string("{\"configured\":") +
                     (configured ? "true" : "false") + ",\"enabled\":" +
                     (enabled ? "true" : "false") + ",\"port\":" +
                     std::to_string(port);
  if (active.ok) {
    body += ",\"activeMapId\":\"" + jsonEscape(activeMapId) + "\"";
  } else {
    body += ",\"activeError\":{\"code\":\"" + jsonEscape(active.code) +
            "\",\"message\":\"" + jsonEscape(active.message) + "\"}";
  }
  body += ",\"activation\":" + activationStatusJson();
  if (!lastErrorCode.empty()) {
    body += ",\"lastError\":{\"code\":\"" + jsonEscape(lastErrorCode) +
            "\",\"message\":\"" + jsonEscape(lastErrorMessage) + "\"}";
  }
  body += "}";
  sendJson(client, 200, body);
}

void MapTransferHttpServer::sendHead(WiFiClient &client, int status,
                                     uint64_t contentLength) {
  const char *reason = status == 200   ? "OK"
                       : status == 400 ? "Bad Request"
                       : status == 403 ? "Forbidden"
                       : status == 404 ? "Not Found"
                                       : "Internal Server Error";
  client.printf("HTTP/1.1 %d %s\r\n", status, reason);
  client.print("Connection: close\r\n");
  client.printf("Content-Length: %llu\r\n\r\n",
                static_cast<unsigned long long>(contentLength));
}

void MapTransferHttpServer::sendJson(WiFiClient &client, int status,
                                     const std::string &body) {
  const char *reason = status == 200   ? "OK"
                       : status == 202 ? "Accepted"
                       : status == 400 ? "Bad Request"
                       : status == 403 ? "Forbidden"
                       : status == 404 ? "Not Found"
                       : status == 409 ? "Conflict"
                       : status == 408 ? "Request Timeout"
                       : status == 413 ? "Payload Too Large"
                                       : "Internal Server Error";
  client.printf("HTTP/1.1 %d %s\r\n", status, reason);
  client.print("Content-Type: application/json\r\n");
  client.print("Connection: close\r\n");
  client.printf("Content-Length: %u\r\n\r\n",
                static_cast<unsigned>(body.size()));
  client.print(body.c_str());
}

void MapTransferHttpServer::sendError(WiFiClient &client, int status,
                                      const std::string &code,
                                      const std::string &message) {
  lockState();
  rememberError(code, message);
  unlockState();
  sendJson(client, status,
           std::string("{\"ok\":false,\"error\":{\"code\":\"") +
               jsonEscape(code) + "\",\"message\":\"" + jsonEscape(message) +
               "\"}}");
}

void MapTransferHttpServer::rememberError(const std::string &code,
                                          const std::string &message) {
  lastErrorCode_ = code;
  lastErrorMessage_ = message;
}

void MapTransferHttpServer::lockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreTake(stateMutex_, portMAX_DELAY);
}

void MapTransferHttpServer::unlockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreGive(stateMutex_);
}

std::string MapTransferHttpServer::activationStatusJson() const {
  lockState();
  std::string body = std::string("{\"status\":\"") +
                     jsonEscape(activationStatus_) + "\"";
  if (!activationSessionId_.empty())
    body += ",\"sessionId\":\"" + jsonEscape(activationSessionId_) + "\"";
  if (!activationMapId_.empty())
    body += ",\"mapId\":\"" + jsonEscape(activationMapId_) + "\"";
  if (!activationErrorCode_.empty()) {
    body += ",\"error\":{\"code\":\"" + jsonEscape(activationErrorCode_) +
            "\",\"message\":\"" + jsonEscape(activationErrorMessage_) + "\"}";
  }
  body += "}";
  unlockState();
  return body;
}

void MapTransferHttpServer::finishActivation(const std::string &status,
                                             const std::string &mapId,
                                             const std::string &errorCode,
                                             const std::string &errorMessage) {
  lockState();
  activationRunning_ = false;
  activationStatus_ = status;
  activationMapId_ = mapId;
  activationErrorCode_ = errorCode;
  activationErrorMessage_ = errorMessage;
  if (!errorCode.empty()) {
    lastErrorCode_ = errorCode;
    lastErrorMessage_ = errorMessage;
  }
  unlockState();
}

void MapTransferHttpServer::runActivationTask(const std::string &sessionId) {
  Serial.printf("MAP_TRANSFER_HTTP: activate start session=%s\n",
                sessionId.c_str());
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
