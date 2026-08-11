#pragma once

#include "device_debug_frame_store.hpp"
#include "device_debug_input.hpp"
#include "../device_transfer/device_transfer_http.hpp"

#include <atomic>

#include "device_debug_request_latch.hpp"
#include <cstdint>
#include <string>

namespace device_debug {

class DeviceDebugHttp : public device_transfer::HttpRequestHandler {
public:
  bool configure(device_transfer::HttpTransferServer *server);
  FrameStoreStartResult beginSession(bool fullFrameRgb565Available);
  void cancelSession();
  void finishSessionTeardown();
  bool handleRequest(const device_transfer::HttpRequest &request,
                     WiFiClient &client) override;
  bool allowShortUnauthenticatedResponseCompletion(
      const device_transfer::HttpRequest &request) const override;
  void responseDidComplete(const device_transfer::HttpRequest &request,
                           bool peerClosedCleanly) override;
  bool takeWakeRequest();
  bool bootPressRequested() const;
  bool takeBootPressRequest();
  bool takeAutomaticExitRequest();
  bool initialized() const { return configured_ && runtimeReady_; }

private:
  bool authorize(const device_transfer::HttpRequest &request,
                 WiFiClient &client);
  bool requireMode(WiFiClient &client);
  bool handleInfo(WiFiClient &client);
  bool handleFrame(const device_transfer::HttpRequest &request,
                   WiFiClient &client);
  bool handlePointer(const device_transfer::HttpRequest &request,
                     WiFiClient &client);
  bool handleWake(WiFiClient &client);
  bool handleBootPress(const device_transfer::HttpRequest &request,
                       WiFiClient &client);
  bool handleExit(WiFiClient &client);

  device_transfer::HttpTransferServer *server_ = nullptr;
  bool configured_ = false;
  bool runtimeReady_ = false;
  std::atomic<bool> wakeRequested_{false};
  OneShotRequestLatch bootPressRequested_;
  std::atomic<bool> exitRequested_{false};
  std::atomic<bool> exitResponsePending_{false};
  uint32_t lastFrameResponseMs_ = 0;
  uint32_t lastFrameResponseDurationMs_ = 0;
  uint32_t maxFrameResponseDurationMs_ = 0;
  uint32_t lastFrameResponseBytes_ = 0;
};

} // namespace device_debug
