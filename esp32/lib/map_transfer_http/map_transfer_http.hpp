#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include <functional>

#include "../device_transfer/device_transfer_http.hpp"
#include "../device_transfer/device_transfer_http_limits.hpp"
#include "map_transfer.hpp"
#include "map_stream_receiver.hpp"

namespace map_transfer {

using HttpTransferStatus = device_transfer::HttpTransferStatus;

class MapTransferHttpServer : private device_transfer::HttpRequestHandler {
public:
  struct ActivatedMapRoot {
    std::string root;
    std::string mapId;
    bool sessionPresent = false;
  };

  void configure(std::string storageRoot = "/sdcard", uint16_t port = 8080,
                 device_transfer::HttpTransferServer *sharedServer = nullptr);
  void setStreamTrustStore(MapStreamTrustStore trustStore);
  void setStreamStorageAvailable(bool available);
  void setStreamStorageProbe(std::function<bool()> probe);
  bool refreshStreamStorageCapability(bool requireWritable = true);
  bool streamInstallSupported() const;
  bool setEnabled(bool enabled);
  void setLastError(const std::string &code, const std::string &message);
  void process();
  HttpTransferStatus status() const;
  MapActivationSnapshot activationSnapshot() const;
  std::string activationStatusJson(bool compact = false) const;
  bool activationHasError() const;
  bool takeActivatedMapRoot(ActivatedMapRoot &activated);
  void acknowledgeActivatedMapRoot(const std::string &root, bool loaded);
  bool takeAutomaticExitRequest();
  void resumePendingActivations();

private:
  std::string storageRoot_ = "/sdcard";
  device_transfer::HttpTransferServer ownedTransferServer_;
  device_transfer::HttpTransferServer *transferServer_ =
      &ownedTransferServer_;
  MapTransferInstaller installer_{"/sdcard"};
  mutable SemaphoreHandle_t stateMutex_ = nullptr;
  MapActivationState activationState_;
  MapStreamTrustStore streamTrustStore_;
  MapStreamInstallSnapshot streamInstallState_;
  bool streamStatusActive_ = false;
  bool streamStorageAvailable_ = false;
  std::function<bool()> streamStorageProbe_;
  std::string pendingMapRoot_;
  std::string pendingMapSessionId_;
  std::string pendingMapId_;
  bool pendingMapRootTaken_ = false;
  bool pendingRendererAcknowledgement_ = false;
  bool pendingRendererAutomaticExit_ = false;
  bool pendingAutomaticExit_ = false;
  struct DeferredActivation {
    device_transfer::HttpResponseCompletionToken response;
    std::string sessionId;
    uint32_t minimumSequence = 0;

    bool pending() const { return !sessionId.empty(); }
  };
  DeferredActivation deferredActivation_;

  bool handleRequest(const device_transfer::HttpRequest &request,
                     device_transfer::TransferClient &client) override;
  void responseDidComplete(const device_transfer::HttpRequest &request,
                           bool peerClosedCleanly) override;
  void responseDidAbort(
      const device_transfer::HttpRequest &request) override;
  bool handleInstallStream(const device_transfer::HttpRequest &request,
                           device_transfer::TransferClient &client);
  void handleStatus(device_transfer::TransferClient &client);
  bool sendJson(device_transfer::TransferClient &client, int status, const std::string &body);
  void sendError(device_transfer::TransferClient &client, int status, const std::string &code,
                 const std::string &message);
  void lockState() const;
  void unlockState() const;
  void finishActivation(const std::string &status, const std::string &mapId,
                        const std::string &errorCode,
                        const std::string &errorMessage);
  void updateActivationProgress(const ActivationProgress &progress);
  bool startActivationTask(const std::string &sessionId, bool automaticExit);
  bool deferActivationUntilResponse(
      const device_transfer::HttpRequest &request, const std::string &sessionId,
      uint32_t minimumSequence = 0);
  void beginDeferredActivation(const DeferredActivation &activation,
                               bool peerClosedCleanly);
  void requestAutomaticExit();
  void executeActivation(const std::string &sessionId, bool automaticExit);
  bool runStreamActivationTask(const std::string &sessionId,
                               bool automaticExit);
  void updateStreamInstallState(const MapStreamInstallSnapshot &snapshot,
                                bool active);
  bool streamStoragePathAccessible() const;
  bool streamStoragePathWritable() const;
  bool resumePendingStreamActivation(
      const MapStreamInstallSnapshot *recovered = nullptr);
  static void activationTaskThunk(void *arg);
};

} // namespace map_transfer
