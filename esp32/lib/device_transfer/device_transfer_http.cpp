#include "device_transfer_http.hpp"
#include "../power_management/power_management.hpp"
#include "../ui_scheduler/ui_scheduler.hpp"
#include "device_transfer_http_limits.hpp"

#include <algorithm>
#include <cctype>
#include <esp_system.h>
#include <sstream>

namespace device_transfer {
namespace {

// Map activation is handed off to this worker after the HTTP response completes
// so the transfer and activation phases do not allocate two large stacks at
// once. Activation reaches substantially deeper than the idle accept loop;
// retain the 16 KiB budget required by that handoff path. Remote debugging now
// also performs Wi-Fi station setup and hotspot fallback on this worker. Keep
// its existing effective 16 KiB budget rather than reducing stack headroom on
// the fully initialized device.
constexpr uint32_t kTransferHttpWorkerStackBytes = 16384;
constexpr uint32_t kDebugHttpWorkerStackBytes = 16384;
constexpr uint32_t kLanConnectTimeoutMs = 6000;
constexpr uint32_t kLanConnectPollMs = 50;

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

static bool constantTimeEqual(const std::string &left,
                              const std::string &right) {
  const size_t maximumLength = std::max(left.size(), right.size());
  size_t difference = left.size() ^ right.size();
  for (size_t index = 0; index < maximumLength; ++index) {
    const unsigned char leftByte =
        index < left.size() ? static_cast<unsigned char>(left[index]) : 0;
    const unsigned char rightByte =
        index < right.size() ? static_cast<unsigned char>(right[index]) : 0;
    difference |= leftByte ^ rightByte;
  }
  return difference == 0;
}

static const char *httpReason(int status) {
  switch (status) {
  case 200:
    return "OK";
  case 202:
    return "Accepted";
  case 204:
    return "No Content";
  case 400:
    return "Bad Request";
  case 401:
    return "Unauthorized";
  case 403:
    return "Forbidden";
  case 404:
    return "Not Found";
  case 408:
    return "Request Timeout";
  case 409:
    return "Conflict";
  case 413:
    return "Payload Too Large";
  case 415:
    return "Unsupported Media Type";
  case 426:
    return "Upgrade Required";
  case 429:
    return "Too Many Requests";
  case 431:
    return "Request Header Fields Too Large";
  case 503:
    return "Service Unavailable";
  default:
    return "Internal Server Error";
  }
}

enum class ReadLineResult { Complete, Timeout, TooLarge, Disconnected };

static ReadLineResult readLine(TransferClient &client, std::string &line,
                               HttpHeaderBudget &budget,
                               uint32_t requestStartedMs) {
  line.clear();
  while (!HttpHeaderBudget::timedOut(millis() - requestStartedMs)) {
    while (client.available()) {
      const int raw = client.read();
      if (raw < 0)
        break;
      const char c = static_cast<char>(raw);
      if (c == '\r') {
        if (!budget.acceptDelimiterByte())
          return ReadLineResult::TooLarge;
        continue;
      }
      if (c == '\n') {
        if (!budget.acceptDelimiterByte() || !budget.finishLine())
          return ReadLineResult::TooLarge;
        return ReadLineResult::Complete;
      }
      if (!budget.acceptDataByte())
        return ReadLineResult::TooLarge;
      line.push_back(c);
    }
    if (!client.connected() && client.available() <= 0)
      return ReadLineResult::Disconnected;
    delay(1);
  }
  return ReadLineResult::Timeout;
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

constexpr uint32_t kHttpResponseCloseTimeoutMs = 5000;

static bool writeHttpResponse(TransferClient &client, const std::string &response) {
  if (response.empty())
    return false;
  return writeHttpBytes(client,
                        reinterpret_cast<const uint8_t *>(response.data()),
                        response.size());
}

static bool finishHttpResponse(TransferClient &client, uint32_t timeoutMs) {
  return client.finishResponse(timeoutMs);
}

} // namespace

void HttpTransferServer::configure(HttpRequestHandler *handler, uint16_t port,
                                   std::string apSsid) {
  configure(port, std::move(apSsid));
  registerHandler("/", handler);
}

void HttpTransferServer::configure(uint16_t port, std::string apSsid) {
  port_ = port;
  if (!apSsid.empty())
    apSsid_ = std::move(apSsid);
  server_ = WiFiServer(port_);
  if (stateMutex_ == nullptr)
    stateMutex_ = xSemaphoreCreateMutex();
  if (tlsIdentityMutex_ == nullptr)
    tlsIdentityMutex_ = xSemaphoreCreateMutex();
  configured_ = stateMutex_ != nullptr && tlsIdentityMutex_ != nullptr &&
                tlsIdentityStore_.begin();
  if (!configured_) {
    rememberError(stateMutex_ == nullptr || tlsIdentityMutex_ == nullptr
                      ? "transfer_mutex"
                      : tlsIdentityStore_.lastError(),
                  stateMutex_ == nullptr || tlsIdentityMutex_ == nullptr
                      ? "could not allocate transfer state lock"
                      : "device TLS identity is unavailable");
  }
}

bool HttpTransferServer::registerHandler(std::string pathPrefix,
                                         HttpRequestHandler *handler) {
  if (handler == nullptr || pathPrefix.empty())
    return false;
  for (size_t i = 0; i < handlerCount_; ++i) {
    if (handlers_[i].pathPrefix == pathPrefix) {
      handlers_[i].handler = handler;
      return true;
    }
  }
  if (handlerCount_ >= handlers_.size())
    return false;
  handlers_[handlerCount_++] = {std::move(pathPrefix), handler};
  return true;
}

bool HttpTransferServer::setEnabled(bool enabled) {
  return setEnabled(enabled, enabled ? mode_ : "");
}

bool HttpTransferServer::setPreferredNetwork(
    const LanCredentials &credentials) {
  if (!validLanCredentials(credentials))
    return false;
  lockState();
  if (enabled_) {
    unlockState();
    return false;
  }
  preferredNetwork_ = credentials;
  requestedHotspotFallbackReason_.clear();
  unlockState();
  return true;
}

bool HttpTransferServer::forceHotspotFallbackAfterEndpointFailure() {
  lockState();
  if (enabled_) {
    unlockState();
    return false;
  }
  preferredNetwork_ = {};
  requestedHotspotFallbackReason_ = "endpoint_unreachable";
  unlockState();
  return true;
}

void HttpTransferServer::clearPreferredNetwork() {
  lockState();
  if (!enabled_) {
    preferredNetwork_ = {};
    requestedHotspotFallbackReason_.clear();
  }
  unlockState();
}

bool HttpTransferServer::bindAuthenticatedBleSession(uint64_t sessionId) {
  if (sessionId == 0)
    return false;
  lockState();
  if (enabled_ && authenticatedBleSessionId_ != sessionId) {
    rememberError("ble_session_changed",
                  "transfer is bound to another BLE session");
    unlockState();
    return false;
  }
  if (authenticatedBleSessionId_ != sessionId) {
    authenticatedBleSessionId_ = sessionId;
    transferGeneration_ = nextHttpTransferGeneration(transferGeneration_);
  }
  unlockState();
  return true;
}

void HttpTransferServer::clearAuthenticatedBleSession() {
  lockState();
  const bool hadBinding = authenticatedBleSessionId_ != 0;
  const bool wasEnabled = enabled_;
  authenticatedBleSessionId_ = 0;
  enabled_ = false;
  sessionToken_.clear();
  apPassphrase_.clear();
  preferredNetwork_ = {};
  requestedHotspotFallbackReason_.clear();
  currentRequestAuthorized_ = false;
  if (hadBinding || wasEnabled)
    transferGeneration_ = nextHttpTransferGeneration(transferGeneration_);
  unlockState();
  if (wasEnabled)
    server_.stop();
}

bool HttpTransferServer::prepareTlsIdentityRotation() {
  lockState();
  const uint64_t bleSessionId = authenticatedBleSessionId_;
  const bool allowed = !enabled_ && bleSessionId != 0;
  unlockState();
  if (!allowed)
    return false;
  lockTlsIdentity();
  const bool prepared = tlsIdentityStore_.prepareRotation();
  unlockTlsIdentity();
  if (!prepared)
    return false;
  lockState();
  const bool stillAllowed = !enabled_ && authenticatedBleSessionId_ == bleSessionId;
  unlockState();
  if (!stillAllowed) {
    lockTlsIdentity();
    tlsIdentityStore_.cancelRotation();
    unlockTlsIdentity();
    return false;
  }
  return true;
}

bool HttpTransferServer::commitTlsIdentityRotation(
    const std::string &expectedCertificateSha256) {
  lockState();
  const bool allowed = !enabled_ && authenticatedBleSessionId_ != 0;
  unlockState();
  if (!allowed)
    return false;
  lockTlsIdentity();
  const bool committed =
      tlsIdentityStore_.commitRotation(expectedCertificateSha256);
  unlockTlsIdentity();
  return committed;
}

bool HttpTransferServer::cancelTlsIdentityRotation() {
  lockState();
  const bool allowed = !enabled_ && authenticatedBleSessionId_ != 0;
  unlockState();
  if (!allowed)
    return false;
  lockTlsIdentity();
  const bool cancelled = tlsIdentityStore_.cancelRotation();
  unlockTlsIdentity();
  return cancelled;
}

bool HttpTransferServer::setEnabled(bool enabled, std::string mode) {
  lockState();
  const bool configured = configured_;
  const bool wasEnabled = enabled_;
  const std::string previousMode = mode_;
  const std::string previousSessionToken = sessionToken_;
  const uint64_t authenticatedBleSessionId = authenticatedBleSessionId_;
  unlockState();
  const std::string requestedMode = mode;

  if (!configured || handlerCount_ == 0) {
    lockState();
    rememberError("not_configured", "device transfer server is not configured");
    unlockState();
    return false;
  }
  if (enabled && authenticatedBleSessionId == 0) {
    lockState();
    rememberError("ble_authentication_required",
                  "an authenticated owner BLE session is required");
    unlockState();
    return false;
  }
  lockTlsIdentity();
  const bool tlsIdentityValid = tlsIdentityStore_.active().valid();
  unlockTlsIdentity();
  if (enabled && !tlsIdentityValid) {
    lockState();
    rememberError("tls_identity_invalid",
                  "device TLS identity is unavailable");
    unlockState();
    return false;
  }
  if (enabled && wasEnabled && previousMode != requestedMode) {
    lockState();
    rememberError("transfer_busy", "another transfer mode is active");
    unlockState();
    return false;
  }

  // A prior mode can revoke the service while its worker is still unwinding
  // an HTTP request. Do not publish a new enabled session until that task has
  // cleared its handle; otherwise a stale handle snapshot can suppress the
  // replacement worker and leave an advertised service with no listener.
  if (enabled && !wasEnabled && !waitUntilStopped(2000)) {
    lockState();
    rememberError("http_worker_stopping",
                  "previous transfer HTTP worker is still stopping");
    unlockState();
    return false;
  }

  bool acquiredPowerLock = false;
  if (enabled && !wasEnabled) {
    if (!power_management::acquire(
            power_management::LockDomain::Transfer)) {
      lockState();
      rememberError("power_lock", "could not protect transfer from light sleep");
      unlockState();
      return false;
    }
    acquiredPowerLock = true;
  }
  if (!enabled && wasEnabled) {
    // Revoke the request generation before stopping the listener/AP. Network
    // teardown can take long enough for a nearly complete handler to advance;
    // it must observe cancellation before it can publish or activate anything.
    lockState();
    enabled_ = false;
    mode_.clear();
    apPassphrase_.clear();
    hotspotFallback_ = false;
    hotspotFallbackReason_.clear();
    requestedHotspotFallbackReason_.clear();
    sessionToken_.clear();
    transferGeneration_ = nextHttpTransferGeneration(transferGeneration_);
    unlockState();
    server_.stop();
  }
  if (enabled || !wasEnabled) {
    lockState();
    const bool transferBoundary = enabled_ != enabled ||
                                  (enabled && mode_ != mode);
    enabled_ = enabled;
    mode_ = enabled ? std::move(mode) : "";
    if (enabled) {
      if (!wasEnabled || previousMode != mode_ || previousSessionToken.empty()) {
        sessionToken_ = generateSessionToken();
        apPassphrase_ = generateSessionToken().substr(0, 24);
      }
      if (!wasEnabled) {
        if (requestedMode != "debug" && requestedMode != "diagnostics")
          preferredNetwork_ = {};
        startedAp_ = false;
        startedStation_ = false;
        hotspotFallback_ = false;
        hotspotFallbackReason_.clear();
        networkTransport_ = "starting";
        networkSsid_ = preferredNetwork_.ssid;
      }
    } else {
      apPassphrase_.clear();
      sessionToken_.clear();
      preferredNetwork_ = {};
      requestedHotspotFallbackReason_.clear();
    }
    if (transferBoundary) {
      transferGeneration_ = nextHttpTransferGeneration(transferGeneration_);
      lastUsefulTrafficMs_ = millis();
    }
    unlockState();
  }

  if (enabled && !wasEnabled) {
    TaskHandle_t worker = nullptr;
    const uint32_t workerStackBytes =
        requestedMode == "debug" ? kDebugHttpWorkerStackBytes
                                  : kTransferHttpWorkerStackBytes;
    // Publish the worker handle and persistent power-lock ownership before the
    // new task can observe state. Holding the mutex across xTaskCreate makes
    // an immediately scheduled worker wait until both fields are coherent.
    lockState();
    const BaseType_t created =
        xTaskCreate(workerTaskThunk, "device_http", workerStackBytes, this, 1,
                    &worker);
    if (created == pdPASS) {
      workerTask_ = worker;
      powerLockHeld_ = acquiredPowerLock;
    }
    unlockState();
    Serial.printf(
        "DEVICE_TRANSFER_HTTP: worker create result=%ld handle=%p "
        "stack_bytes=%u free_heap=%u\n",
        static_cast<long>(created), static_cast<void *>(worker),
        static_cast<unsigned>(workerStackBytes),
        static_cast<unsigned>(ESP.getFreeHeap()));
    if (created != pdPASS) {
      server_.stop();
      lockState();
      enabled_ = false;
      startedAp_ = false;
      startedStation_ = false;
      hotspotFallback_ = false;
      hotspotFallbackReason_.clear();
      networkTransport_.clear();
      networkSsid_.clear();
      preferredNetwork_ = {};
      requestedHotspotFallbackReason_.clear();
      mode_.clear();
      apPassphrase_.clear();
      sessionToken_.clear();
      rememberError("http_worker", "could not start transfer HTTP worker");
      unlockState();
      if (acquiredPowerLock) {
        power_management::release(power_management::LockDomain::Transfer);
      }
      return false;
    }
  }
  return true;
}

void HttpTransferServer::setLastError(const std::string &code,
                                      const std::string &message) {
  lockState();
  rememberError(code, message);
  unlockState();
}

void HttpTransferServer::process() {}

bool HttpTransferServer::startNetwork() {
  lockState();
  const bool enabled = enabled_;
  const LanCredentials preferredNetwork = preferredNetwork_;
  preferredNetwork_ = {};
  const std::string requestedHotspotFallbackReason =
      requestedHotspotFallbackReason_;
  requestedHotspotFallbackReason_.clear();
  const std::string apSsid = apSsid_;
  const std::string apPassphrase = apPassphrase_;
  const std::string mode = mode_;
  unlockState();
  if (!enabled)
    return false;

  const bool preferLan = validLanCredentials(preferredNetwork);
  if (preferLan) {
    lockState();
    networkTransport_ = "connecting";
    networkSsid_ = preferredNetwork.ssid;
    unlockState();

    WiFi.persistent(false);
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(false);
    WiFi.begin(preferredNetwork.ssid.c_str(),
               preferredNetwork.password.c_str());
    const uint32_t started = millis();
    while (millis() - started < kLanConnectTimeoutMs) {
      lockState();
      const bool stillEnabled = enabled_;
      unlockState();
      if (!stillEnabled) {
        WiFi.disconnect(true, false);
        return false;
      }
      if (WiFi.status() == WL_CONNECTED && WiFi.localIP() != IPAddress()) {
        lockState();
        startedStation_ = true;
        networkTransport_ = "lan";
        networkSsid_ = preferredNetwork.ssid;
        unlockState();
        Serial.printf(
            "DEVICE_TRANSFER_HTTP: joined LAN ssid_bytes=%u ip=%s\n",
            static_cast<unsigned>(preferredNetwork.ssid.size()),
            WiFi.localIP().toString().c_str());
        break;
      }
      vTaskDelay(pdMS_TO_TICKS(kLanConnectPollMs));
    }
  }

  lockState();
  const bool lanReady = startedStation_;
  const bool stillEnabled = enabled_;
  unlockState();
  if (!stillEnabled) {
    WiFi.disconnect(true, false);
    return false;
  }

  if (!lanReady) {
    std::string fallbackReason = requestedHotspotFallbackReason;
    if (preferLan) {
      const wl_status_t stationStatus = WiFi.status();
      fallbackReason = lanFallbackReasonForStatus(
          static_cast<int>(stationStatus), static_cast<int>(WL_NO_SSID_AVAIL),
          static_cast<int>(WL_CONNECT_FAILED));
      WiFi.disconnect(true, false);
      vTaskDelay(pdMS_TO_TICKS(50));
    }
    WiFi.mode(WIFI_AP);
    const bool apStarted =
        WiFi.softAP(apSsid.c_str(), apPassphrase.c_str());
    if (!apStarted) {
      lockState();
      rememberError("wifi_ap", "could not start transfer Wi-Fi fallback");
      unlockState();
      WiFi.mode(WIFI_OFF);
      return false;
    }
    lockState();
    startedAp_ = true;
    hotspotFallback_ = !fallbackReason.empty();
    hotspotFallbackReason_ = fallbackReason;
    networkTransport_ = "hotspot";
    networkSsid_ = apSsid;
    unlockState();
    Serial.printf(
        "DEVICE_TRANSFER_HTTP: started AP fallback=%d reason=%s ssid=%s "
        "ip=%s\n",
        !fallbackReason.empty(), fallbackReason.c_str(), apSsid.c_str(),
        WiFi.softAPIP().toString().c_str());
  }

  server_.begin();
  server_.setNoDelay(true);
  Serial.printf(
      "DEVICE_TRANSFER_HTTP: listener started port=%u transport=%s "
      "free_heap=%u\n",
      static_cast<unsigned>(port_), lanReady ? "lan" : "hotspot",
      static_cast<unsigned>(ESP.getFreeHeap()));
  return true;
}

void HttpTransferServer::stopNetwork() {
  lockState();
  const bool startedAp = startedAp_;
  const bool startedStation = startedStation_;
  const bool hadNetworkActivity = !networkTransport_.empty();
  startedAp_ = false;
  startedStation_ = false;
  hotspotFallback_ = false;
  hotspotFallbackReason_.clear();
  networkTransport_.clear();
  networkSsid_.clear();
  apPassphrase_.clear();
  preferredNetwork_ = {};
  requestedHotspotFallbackReason_.clear();
  unlockState();

  server_.stop();
  if (startedAp)
    WiFi.softAPdisconnect(true);
  if (startedStation)
    WiFi.disconnect(true, false);
  if (hadNetworkActivity)
    WiFi.mode(WIFI_OFF);
}

void HttpTransferServer::runWorker() {
  Serial.printf(
      "DEVICE_TRANSFER_HTTP: worker started core=%d free_heap=%u stack_words=%u\n",
      xPortGetCoreID(), static_cast<unsigned>(ESP.getFreeHeap()),
      static_cast<unsigned>(uxTaskGetStackHighWaterMark(nullptr)));
  if (!startNetwork()) {
    lockState();
    const bool startupFailed = enabled_;
    enabled_ = false;
    mode_.clear();
    apPassphrase_.clear();
    sessionToken_.clear();
    transferGeneration_ = nextHttpTransferGeneration(transferGeneration_);
    if (startupFailed && lastErrorCode_.empty()) {
      rememberError("wifi_unavailable",
                    "could not start LAN or device hotspot");
    }
    unlockState();
    stopNetwork();
    lockState();
    workerTask_ = nullptr;
    const bool releasePowerLock = powerLockHeld_;
    powerLockHeld_ = false;
    unlockState();
    if (releasePowerLock)
      power_management::release(power_management::LockDomain::Transfer);
    return;
  }
  uint32_t lastHealthLogMs = 0;
  while (true) {
    lockState();
    const bool enabled = enabled_;
    unlockState();
    if (!enabled) {
      lockState();
      if (enabled_) {
        unlockState();
        continue;
      }
      unlockState();
      stopNetwork();
      lockState();
      workerTask_ = nullptr;
      const bool releasePowerLock = powerLockHeld_;
      powerLockHeld_ = false;
      unlockState();
      if (releasePowerLock) {
        power_management::release(power_management::LockDomain::Transfer);
      }
      return;
    }
    WiFiClient acceptedClient = server_.accept();
    if (acceptedClient) {
      const HttpTransferStatus networkStatus = status();
      Serial.printf(
          "DEVICE_TRANSFER_HTTP: accepted client transport=%s stations=%u "
          "free_heap=%u stack_words=%u\n",
          networkStatus.networkTransport.c_str(),
          static_cast<unsigned>(networkStatus.networkTransport == "hotspot"
                                    ? WiFi.softAPgetStationNum()
                                    : 0),
          static_cast<unsigned>(ESP.getFreeHeap()),
          static_cast<unsigned>(uxTaskGetStackHighWaterMark(nullptr)));
      TransferClient client;
      lockTlsIdentity();
      const TransferTlsIdentity tlsIdentity = tlsIdentityStore_.active();
      unlockTlsIdentity();
      if (!client.begin(acceptedClient, tlsIdentity)) {
        Serial.println(
            "DEVICE_TRANSFER_HTTP: rejected client before secure request");
        vTaskDelay(pdMS_TO_TICKS(2));
        continue;
      }
      lockState();
      requestInProgress_ = true;
      currentRequestAuthorized_ = false;
      unlockState();
      handleClient(client);
      client.stop();
      lockState();
      if (currentRequestAuthorized_) {
        lastUsefulTrafficMs_ = millis();
      }
      requestInProgress_ = false;
      currentRequestAuthorized_ = false;
      unlockState();
      ui_scheduler::notify(ui_scheduler::WakeReason::Transfer);
    } else {
      const uint32_t now = millis();
      if (now - lastHealthLogMs >= 1000) {
        lastHealthLogMs = now;
        const HttpTransferStatus networkStatus = status();
        Serial.printf(
            "DEVICE_TRANSFER_HTTP: waiting transport=%s clients=%u url=%s "
            "free_heap=%u stack_words=%u\n",
            networkStatus.networkTransport.c_str(),
            static_cast<unsigned>(networkStatus.networkTransport == "hotspot"
                                      ? WiFi.softAPgetStationNum()
                                      : 0),
            networkStatus.baseUrl.c_str(),
            static_cast<unsigned>(ESP.getFreeHeap()),
            static_cast<unsigned>(uxTaskGetStackHighWaterMark(nullptr)));
      }
      vTaskDelay(pdMS_TO_TICKS(2));
    }
  }
}

void HttpTransferServer::workerTaskThunk(void *arg) {
  auto *server = static_cast<HttpTransferServer *>(arg);
  if (server != nullptr)
    server->runWorker();
  vTaskDelete(nullptr);
}

HttpTransferStatus HttpTransferServer::status() const {
  lockState();
  const bool configured = configured_;
  const bool enabled = enabled_;
  const bool startedAp = startedAp_;
  const bool startedStation = startedStation_;
  const uint16_t port = port_;
  const std::string mode = mode_;
  const std::string apSsid = apSsid_;
  const std::string apPassphrase = apPassphrase_;
  const std::string networkTransport = networkTransport_;
  const std::string networkSsid = networkSsid_;
  const bool hotspotFallback = hotspotFallback_;
  const std::string hotspotFallbackReason = hotspotFallbackReason_;
  const std::string sessionToken = sessionToken_;
  const uint32_t transferGeneration = transferGeneration_;
  const std::string lastErrorCode = lastErrorCode_;
  const std::string lastErrorMessage = lastErrorMessage_;
  const uint32_t errorSequence = errorSequence_;
  const uint32_t lastUsefulTrafficMs = lastUsefulTrafficMs_;
  // Only authenticated work may extend the transfer lifetime. A client that
  // stalls before authorization must not keep the AP awake indefinitely.
  const bool authorizedRequestInProgress =
      requestInProgress_ && currentRequestAuthorized_;
  unlockState();
  lockTlsIdentity();
  const std::string tlsCertificateSha256 =
      tlsIdentityStore_.active().certificateSha256;
  const uint32_t tlsIdentityVersion = tlsIdentityStore_.active().version;
  const std::string pendingTlsCertificateSha256 =
      tlsIdentityStore_.pending().certificateSha256;
  const uint32_t pendingTlsIdentityVersion =
      tlsIdentityStore_.pending().version;
  unlockTlsIdentity();

  std::string baseUrl;
  if (enabled) {
    IPAddress ip =
        startedAp ? WiFi.softAPIP()
                  : (startedStation && WiFi.status() == WL_CONNECTED
                         ? WiFi.localIP()
                         : IPAddress());
    if (ip != IPAddress()) {
      baseUrl = std::string("https://") + ip.toString().c_str() + ":" +
                std::to_string(port);
    }
  }
  HttpTransferStatus result;
  result.configured = configured;
  result.enabled = enabled;
  result.port = port;
  result.mode = mode;
  result.baseUrl = std::move(baseUrl);
  result.apSsid = startedAp ? apSsid : "";
  result.apPassphrase = startedAp ? apPassphrase : "";
  result.networkTransport = networkTransport;
  result.networkSsid = networkSsid;
  result.hotspotFallback = hotspotFallback;
  result.hotspotFallbackReason = hotspotFallbackReason;
  result.sessionToken = sessionToken;
  result.tlsCertificateSha256 = tlsCertificateSha256;
  result.tlsIdentityVersion = tlsIdentityVersion;
  result.pendingTlsCertificateSha256 = pendingTlsCertificateSha256;
  result.pendingTlsIdentityVersion = pendingTlsIdentityVersion;
  result.transferGeneration = transferGeneration;
  result.secureTransferV1 =
      tlsIdentityVersion != 0 &&
      validTlsCertificateSha256(tlsCertificateSha256);
  result.signedMapStreamV1 = true;
  result.legacyArchivePolicy = "disabled";
  result.lastErrorCode = lastErrorCode;
  result.lastErrorMessage = lastErrorMessage;
  result.errorSequence = errorSequence;
  result.lastUsefulTrafficMs = lastUsefulTrafficMs;
  result.authorizedRequestInProgress = authorizedRequestInProgress;
  return result;
}

bool HttpTransferServer::isRequestAuthorized(
    const HttpRequest &request) {
  lockState();
  const bool enabled = enabled_;
  const std::string sessionToken = sessionToken_;
  const uint32_t transferGeneration = transferGeneration_;
  const uint64_t authenticatedBleSessionId = authenticatedBleSessionId_;
  const bool authorized =
      isHttpTransferGenerationCurrent(enabled, transferGeneration,
                                      request.transferGeneration) &&
      authenticatedBleSessionId != 0 && !sessionToken.empty() &&
      constantTimeEqual(request.transferToken, sessionToken);
  currentRequestAuthorized_ = authorized;
  if (authorized) {
    lastUsefulTrafficMs_ = millis();
  }
  unlockState();
  return authorized;
}

bool HttpTransferServer::waitUntilStopped(uint32_t timeoutMs) {
  const uint32_t started = millis();
  while (true) {
    lockState();
    const bool stopped = workerTask_ == nullptr;
    unlockState();
    if (stopped)
      return true;
    if (millis() - started >= timeoutMs)
      return false;
    vTaskDelay(pdMS_TO_TICKS(2));
  }
}

void HttpTransferServer::handleClient(TransferClient &client) {
  const uint32_t requestStartedMs = millis();
  HttpHeaderBudget headerBudget;
  std::string requestLine;
  const ReadLineResult requestLineResult =
      readLine(client, requestLine, headerBudget, requestStartedMs);
  if (requestLineResult == ReadLineResult::Timeout) {
    sendError(client, 408, "timeout", "request timed out");
    return;
  }
  if (requestLineResult == ReadLineResult::TooLarge) {
    sendError(client, 431, "headers_too_large",
              "request headers exceed device limits");
    return;
  }
  if (requestLineResult != ReadLineResult::Complete) {
    sendError(client, 400, "bad_request", "request line is incomplete");
    return;
  }

  HttpRequest request;
  std::stringstream requestStream(requestLine);
  std::string version;
  requestStream >> request.method >> request.path >> version;
  std::string requestLineTrailing;
  requestStream >> requestLineTrailing;
  if (request.method.empty() || request.path.empty() ||
      version != "HTTP/1.1" || !requestLineTrailing.empty()) {
    sendError(client, 400, "bad_request", "invalid request line");
    return;
  }

  std::string line;
  HttpSecurityHeaders securityHeaders;
  while (true) {
    const ReadLineResult headerResult =
        readLine(client, line, headerBudget, requestStartedMs);
    if (headerResult == ReadLineResult::Timeout) {
      sendError(client, 408, "timeout", "request headers timed out");
      return;
    }
    if (headerResult == ReadLineResult::TooLarge) {
      sendError(client, 431, "headers_too_large",
                "request headers exceed device limits");
      return;
    }
    if (headerResult != ReadLineResult::Complete) {
      sendError(client, 400, "bad_request", "request headers are incomplete");
      return;
    }
    if (line.empty())
      break;
    const size_t colon = line.find(':');
    if (colon == std::string::npos || colon == 0) {
      sendError(client, 400, "bad_header", "request header is invalid");
      return;
    }
    const std::string rawName = line.substr(0, colon);
    std::string name = lower(rawName);
    std::string value = trim(line.substr(colon + 1));
    if (rawName != trim(rawName) || !validHttpHeaderName(name)) {
      sendError(client, 400, "bad_header", "request header name is invalid");
      return;
    }
    securityHeaders.accept(name, name == "content-type" ? lower(value) : value);
  }
  if (securityHeaders.hasAmbiguousFraming()) {
    sendError(client, 400, "ambiguous_framing",
              "transfer encoding is not supported");
    return;
  }
  request.transferToken = std::move(securityHeaders.transferToken);
  request.contentType = std::move(securityHeaders.contentType);
  request.contentLength = securityHeaders.contentLength;
  request.hasContentLength = securityHeaders.hasContentLength;
  lockState();
  request.transferGeneration = transferGeneration_;
  unlockState();

  HttpRequestHandler *handler = handlerForPath(request.path);
  if (handler != nullptr && handler->handleRequest(request, client)) {
    lockState();
    const bool authorized = currentRequestAuthorized_;
    unlockState();
    // An unauthenticated client must not occupy the single transfer worker for
    // the graceful-close deadline. Authenticated requests receive the durable
    // response boundary needed before a handler may change transfer state.
    const bool shortUnauthenticatedCompletion =
        !authorized &&
        handler->allowShortUnauthenticatedResponseCompletion(request);
    const bool peerClosedCleanly =
        (authorized || shortUnauthenticatedCompletion) &&
        finishHttpResponse(client, authorized ? kHttpResponseCloseTimeoutMs
                                              : 250U);
    client.stop();
    handler->responseDidComplete(request, peerClosedCleanly);
    return;
  }

  sendError(client, 404, "not_found", "device transfer endpoint not found");
}

HttpRequestHandler *
HttpTransferServer::handlerForPath(const std::string &path) const {
  HttpRequestHandler *best = nullptr;
  size_t bestLength = 0;
  for (size_t i = 0; i < handlerCount_; ++i) {
    const HandlerRegistration &registration = handlers_[i];
    if (registration.handler == nullptr)
      continue;
    const std::string &prefix = registration.pathPrefix;
    if (path.compare(0, prefix.size(), prefix) == 0 &&
        prefix.size() >= bestLength) {
      best = registration.handler;
      bestLength = prefix.size();
    }
  }
  return best;
}

std::string HttpTransferServer::generateSessionToken() const {
  static constexpr char kHex[] = "0123456789abcdef";
  std::string token;
  token.reserve(32);
  for (int i = 0; i < 4; ++i) {
    uint32_t value = esp_random();
    for (int shift = 28; shift >= 0; shift -= 4) {
      token.push_back(kHex[(value >> shift) & 0x0F]);
    }
  }
  return token;
}

void HttpTransferServer::sendError(TransferClient &client, int status,
                                   const std::string &code,
                                   const std::string &message) {
  setLastError(code, message);
  sendHttpError(client, status, code, message);
}

void HttpTransferServer::rememberError(const std::string &code,
                                       const std::string &message) {
  lastErrorCode_ = code;
  lastErrorMessage_ = message;
  errorSequence_ = nextHttpTransferGeneration(errorSequence_);
}

void HttpTransferServer::lockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreTake(stateMutex_, portMAX_DELAY);
}

void HttpTransferServer::unlockState() const {
  if (stateMutex_ != nullptr)
    xSemaphoreGive(stateMutex_);
}

void HttpTransferServer::lockTlsIdentity() const {
  if (tlsIdentityMutex_ != nullptr)
    xSemaphoreTake(tlsIdentityMutex_, portMAX_DELAY);
}

void HttpTransferServer::unlockTlsIdentity() const {
  if (tlsIdentityMutex_ != nullptr)
    xSemaphoreGive(tlsIdentityMutex_);
}

bool sendHttpHead(TransferClient &client, int status, uint64_t contentLength,
                  const char *contentType,
                  const HttpResponseHeader *additionalHeaders,
                  size_t additionalHeaderCount) {
  std::string response = std::string("HTTP/1.1 ") + std::to_string(status) +
                         " " + httpReason(status) + "\r\n";
  if (contentType != nullptr && contentType[0] != '\0') {
    const std::string value(contentType);
    if (value.find('\r') != std::string::npos ||
        value.find('\n') != std::string::npos)
      return false;
    response += "Content-Type: " + value + "\r\n";
  }
  for (size_t index = 0; index < additionalHeaderCount; ++index) {
    if (additionalHeaders == nullptr || additionalHeaders[index].name == nullptr ||
        additionalHeaders[index].value == nullptr)
      return false;
    const std::string name(additionalHeaders[index].name);
    const std::string value(additionalHeaders[index].value);
    if (!validHttpHeaderName(name) || value.find('\r') != std::string::npos ||
        value.find('\n') != std::string::npos)
      return false;
    response += name + ": " + value + "\r\n";
  }
  response += "Connection: close\r\nContent-Length: " +
              std::to_string(contentLength) +
              "\r\nCache-Control: no-store\r\nPragma: no-cache\r\n\r\n";
  return writeHttpResponse(client, response);
}

bool writeHttpBytes(TransferClient &client, const uint8_t *data, size_t length,
                    uint32_t timeoutMs) {
  if (data == nullptr && length != 0)
    return false;
  size_t offset = 0;
  uint32_t lastProgressMs = millis();
  while (offset < length && millis() - lastProgressMs < timeoutMs) {
    if (!client.connected())
      return false;
    const size_t chunk = std::min<size_t>(4096, length - offset);
    const size_t written = client.write(data + offset, chunk);
    if (written == 0) {
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }
    offset += written;
    lastProgressMs = millis();
  }
  return offset == length;
}

bool sendHttpJson(TransferClient &client, int status, const std::string &body) {
  const std::string response =
      std::string("HTTP/1.1 ") + std::to_string(status) + " " +
      httpReason(status) +
      "\r\nContent-Type: application/json\r\nConnection: close\r\nCache-Control: no-store\r\nPragma: no-cache\r\nContent-Length: " +
      std::to_string(body.size()) + "\r\n\r\n" + body;
  return writeHttpResponse(client, response);
}

bool sendHttpError(TransferClient &client, int status, const std::string &code,
                   const std::string &message) {
  return sendHttpJson(
      client, status,
      std::string("{\"ok\":false,\"error\":{\"code\":\"") + jsonEscape(code) +
          "\",\"message\":\"" + jsonEscape(message) + "\"}}");
}

bool readHttpBody(TransferClient &client, uint64_t contentLength,
                  uint64_t maxLength, std::string &body,
                  uint32_t timeoutMs) {
  body.clear();
  if (contentLength > maxLength)
    return false;
  body.reserve(static_cast<size_t>(contentLength));
  uint8_t buffer[256];
  uint64_t remaining = contentLength;
  uint32_t lastReadMs = millis();
  while (remaining > 0 && millis() - lastReadMs < timeoutMs) {
    int available = client.available();
    if (available <= 0) {
      if (!client.connected())
        return false;
      delay(1);
      continue;
    }
    size_t toRead = std::min<uint64_t>(sizeof(buffer), remaining);
    toRead = std::min<size_t>(toRead, static_cast<size_t>(available));
    int read = client.read(buffer, toRead);
    if (read <= 0) {
      delay(1);
      continue;
    }
    body.append(reinterpret_cast<const char *>(buffer),
                static_cast<size_t>(read));
    remaining -= static_cast<uint64_t>(read);
    lastReadMs = millis();
  }
  return remaining == 0;
}

} // namespace device_transfer
