#pragma once

#include <Arduino.h>
#include <WiFi.h>
#include <esp_ota_ops.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include "../device_transfer/device_transfer_http.hpp"

#include <string>

namespace firmware_update {

struct FirmwareUpdateStatus {
  std::string status = "idle";
  std::string target;
  std::string runningVersion;
  uint32_t runningBuild = 0;
  std::string runningPartition;
  std::string inactivePartition;
  uint32_t maxImageBytes = 0;
  uint32_t receivedBytes = 0;
  uint32_t totalBytes = 0;
  std::string sha256;
  std::string errorCode;
  std::string errorMessage;
};

class FirmwareUpdateHttpServer : private device_transfer::HttpRequestHandler {
public:
  void configure(device_transfer::HttpTransferServer *sharedServer = nullptr,
                 uint16_t port = 8080);
  bool setEnabled(bool enabled);
  void setLastError(const std::string &code, const std::string &message);
  void process();
  FirmwareUpdateStatus status() const;
  std::string statusJson() const;
  void markRunningAppValid();

private:
  device_transfer::HttpTransferServer ownedTransferServer_;
  device_transfer::HttpTransferServer *transferServer_ =
      &ownedTransferServer_;
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  std::string status_ = "idle";
  uint32_t receivedBytes_ = 0;
  uint32_t totalBytes_ = 0;
  std::string expectedSha256_;
  std::string actualSha256_;
  std::string pendingVersion_;
  uint32_t pendingBuild_ = 0;
  bool allowDowngrade_ = false;
  std::string errorCode_;
  std::string errorMessage_;
  const esp_partition_t *updatePartition_ = nullptr;
  esp_ota_handle_t otaHandle_ = 0;
  bool otaOpen_ = false;

  bool handleRequest(const device_transfer::HttpRequest &request,
                     WiFiClient &client) override;
  void handleStatus(WiFiClient &client);
  void handleBegin(const device_transfer::HttpRequest &request,
                   WiFiClient &client);
  void handleImage(const device_transfer::HttpRequest &request,
                   WiFiClient &client);
  void handleFinalize(WiFiClient &client);
  void handleCancel(WiFiClient &client);
  void resetUploadState();
  void reject(WiFiClient &client, int httpStatus, const std::string &code,
              const std::string &message);
  void fail(WiFiClient &client, int httpStatus, const std::string &code,
            const std::string &message);
  void rememberError(const std::string &code, const std::string &message);
  void lockState() const;
  void unlockState() const;
};

} // namespace firmware_update
