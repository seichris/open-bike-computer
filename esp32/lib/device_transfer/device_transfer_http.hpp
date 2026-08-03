#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include <array>
#include <string>

namespace device_transfer {

struct HttpTransferStatus {
  bool configured = false;
  bool enabled = false;
  uint16_t port = 8080;
  std::string mode;
  std::string baseUrl;
  std::string apSsid;
  std::string sessionToken;
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
  uint32_t transferGeneration = 0;
};

class HttpRequestHandler {
public:
  virtual ~HttpRequestHandler() = default;
  virtual bool handleRequest(const HttpRequest &request,
                             WiFiClient &client) = 0;
  virtual void responseDidComplete(const HttpRequest &request,
                                   bool peerClosedCleanly) {}
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
  std::string mode_;
  std::string apSsid_ = "BikeComputer-Transfer";
  std::string sessionToken_;
  WiFiServer server_{8080};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
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

  void handleClient(WiFiClient &client);
  void runWorker();
  static void workerTaskThunk(void *arg);
  HttpRequestHandler *handlerForPath(const std::string &path) const;
  std::string generateSessionToken() const;
  void sendError(WiFiClient &client, int status, const std::string &code,
                 const std::string &message);
  void rememberError(const std::string &code, const std::string &message);
  void lockState() const;
  void unlockState() const;
};

bool sendHttpHead(WiFiClient &client, int status,
                  uint64_t contentLength = 0);
bool sendHttpJson(WiFiClient &client, int status, const std::string &body);
bool sendHttpError(WiFiClient &client, int status, const std::string &code,
                   const std::string &message);
bool readHttpBody(WiFiClient &client, uint64_t contentLength,
                  uint64_t maxLength, std::string &body,
                  uint32_t timeoutMs = 5000);

} // namespace device_transfer
