#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "../device_transfer/device_transfer_http.hpp"
#include "map_transfer.hpp"

namespace map_transfer {

using HttpTransferStatus = device_transfer::HttpTransferStatus;

class MapTransferHttpServer : private device_transfer::HttpRequestHandler {
public:
  void configure(std::string storageRoot = "/sdcard", uint16_t port = 8080,
                 device_transfer::HttpTransferServer *sharedServer = nullptr);
  bool setEnabled(bool enabled);
  void setLastError(const std::string &code, const std::string &message);
  void process();
  HttpTransferStatus status() const;
  std::string activationStatusJson(bool compact = false) const;
  bool activationHasError() const;
  bool takeActivatedMapRoot(std::string &root);

private:
  std::string storageRoot_ = "/sdcard";
  device_transfer::HttpTransferServer ownedTransferServer_;
  device_transfer::HttpTransferServer *transferServer_ =
      &ownedTransferServer_;
  MapTransferInstaller installer_{"/sdcard"};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  MapActivationState activationState_;
  std::string pendingMapRoot_;
  bool recoveryBlocked_ = false;

  bool handleRequest(const device_transfer::HttpRequest &request,
                     WiFiClient &client) override;
  bool handlePut(const std::string &path, uint64_t contentLength,
                 WiFiClient &client);
  bool handleHead(const std::string &path, WiFiClient &client);
  bool handleActivate(const std::string &path, WiFiClient &client);
  void handleStatus(WiFiClient &client);
  void sendHead(WiFiClient &client, int status, uint64_t contentLength = 0);
  void sendJson(WiFiClient &client, int status, const std::string &body);
  void sendError(WiFiClient &client, int status, const std::string &code,
                 const std::string &message);
  void lockState() const;
  void unlockState() const;
  void finishActivation(const std::string &status, const std::string &mapId,
                        const std::string &errorCode,
                        const std::string &errorMessage);
  void runActivationTask(const std::string &sessionId);
  static void activationTaskThunk(void *arg);
};

} // namespace map_transfer
