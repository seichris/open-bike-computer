#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include <array>
#include <string>

#include "device_transfer_network_protocol.hpp"
#include "device_transfer_tls.hpp"

namespace device_transfer {

struct HttpTransferStatus {
  bool configured = false;
  bool enabled = false;
  uint16_t port = 8080;
  std::string mode;
  std::string baseUrl;
  std::string apSsid;
  std::string apPassphrase;
  std::string networkTransport;
  std::string networkSsid;
  bool hotspotFallback = false;
  std::string hotspotFallbackReason;
  std::string sessionToken;
  std::string tlsCertificateSha256;
  uint32_t tlsIdentityVersion = 0;
  std::string pendingTlsCertificateSha256;
  uint32_t pendingTlsIdentityVersion = 0;
  uint32_t transferGeneration = 0;
  bool secureTransferV1 = false;
  bool signedMapStreamV1 = false;
  std::string legacyArchivePolicy;
  std::string lastErrorCode;
  std::string lastErrorMessage;
  uint32_t errorSequence = 0;
  uint32_t lastUsefulTrafficMs = 0;
  bool authorizedRequestInProgress = false;
};

struct HttpRequest {
  std::string method;
  std::string path;
  std::string transferToken;
  std::string contentType;
  uint64_t contentLength = 0;
  bool hasContentLength = false;
  bool connectionClose = false;
  bool connectionReuseRequested = false;
  uint32_t transferGeneration = 0;
};

class HttpRequestHandler {
public:
  virtual ~HttpRequestHandler() = default;
  virtual bool handleRequest(const HttpRequest &request,
                             TransferClient &client) = 0;
  virtual bool allowShortUnauthenticatedResponseCompletion(
      const HttpRequest &request) const {
    return false;
  }
  virtual void responseDidComplete(const HttpRequest &request,
                                   bool peerClosedCleanly) {}
  virtual void responseDidAbort(const HttpRequest &request) {}
};

class HttpTransferServer {
public:
  void configure(uint16_t port = 8080,
                 std::string apSsid = "BikeComputer-Transfer");
  void configure(HttpRequestHandler *handler, uint16_t port = 8080,
                 std::string apSsid = "BikeComputer-Transfer");
  bool registerHandler(std::string pathPrefix, HttpRequestHandler *handler);
  bool setEnabled(bool enabled);
  bool setEnabled(bool enabled, std::string mode);
  bool setPreferredNetwork(const LanCredentials &credentials);
  bool forceHotspotFallbackAfterEndpointFailure();
  void clearPreferredNetwork();
  bool bindAuthenticatedBleSession(uint64_t sessionId);
  void clearAuthenticatedBleSession();
  bool prepareTlsIdentityRotation();
  bool commitTlsIdentityRotation(
      const std::string &expectedCertificateSha256);
  bool cancelTlsIdentityRotation();
  void setLastError(const std::string &code, const std::string &message);
  void process();
  HttpTransferStatus status() const;
  bool isRequestAuthorized(const HttpRequest &request);
  bool waitUntilStopped(uint32_t timeoutMs);

private:
  uint16_t port_ = 8080;
  bool configured_ = false;
  bool enabled_ = false;
  bool startedAp_ = false;
  bool startedStation_ = false;
  bool hotspotFallback_ = false;
  std::string hotspotFallbackReason_;
  std::string requestedHotspotFallbackReason_;
  std::string networkTransport_;
  std::string networkSsid_;
  LanCredentials preferredNetwork_;
  std::string mode_;
  std::string apSsid_ = "BikeComputer-Transfer";
  std::string apPassphrase_;
  std::string sessionToken_;
  TransferTlsIdentityStore tlsIdentityStore_;
  uint64_t authenticatedBleSessionId_ = 0;
  WiFiServer server_{8080};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  mutable SemaphoreHandle_t tlsIdentityMutex_ = nullptr;
  std::string lastErrorCode_;
  std::string lastErrorMessage_;
  uint32_t errorSequence_ = 0;
  uint32_t lastUsefulTrafficMs_ = 0;
  bool requestInProgress_ = false;
  bool currentRequestAuthorized_ = false;
  uint32_t transferGeneration_ = 0;
  bool powerLockHeld_ = false;
  struct HandlerRegistration {
    std::string pathPrefix;
    HttpRequestHandler *handler = nullptr;
  };
  std::array<HandlerRegistration, 4> handlers_{};
  size_t handlerCount_ = 0;
  TaskHandle_t workerTask_ = nullptr;
  TransferClient *activeClient_ = nullptr;

  bool handleClient(TransferClient &client, size_t requestIndex);
  void runWorker();
  bool startNetwork();
  void stopNetwork();
  static void workerTaskThunk(void *arg);
  HttpRequestHandler *handlerForPath(const std::string &path) const;
  std::string generateSessionToken() const;
  void sendError(TransferClient &client, int status, const std::string &code,
                 const std::string &message);
  void rememberError(const std::string &code, const std::string &message);
  void lockState() const;
  void unlockState() const;
  void lockTlsIdentity() const;
  void unlockTlsIdentity() const;
  void interruptActiveClientLocked() const;
};

struct HttpResponseHeader {
  const char *name = nullptr;
  const char *value = nullptr;
};

bool sendHttpHead(TransferClient &client, int status,
                  uint64_t contentLength = 0,
                  const char *contentType = nullptr,
                  const HttpResponseHeader *additionalHeaders = nullptr,
                  size_t additionalHeaderCount = 0);
bool writeHttpBytes(TransferClient &client, const uint8_t *data,
                    size_t length,
                    uint32_t timeoutMs = 5000,
                    size_t maximumChunkBytes = 4096,
                    uint32_t interChunkDelayMs = 0);
bool sendHttpJson(TransferClient &client, int status,
                  const std::string &body);
bool sendHttpError(TransferClient &client, int status,
                   const std::string &code,
                   const std::string &message);
bool readHttpBody(TransferClient &client, uint64_t contentLength,
                  uint64_t maxLength, std::string &body,
                  uint32_t timeoutMs = 5000);

} // namespace device_transfer
