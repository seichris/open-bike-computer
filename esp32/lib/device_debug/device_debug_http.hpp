#pragma once

#include "device_debug_frame_store.hpp"
#include "device_debug_input.hpp"
#include "renderer_diagnostics_request.hpp"
#include "../device_transfer/device_transfer_http.hpp"

#include <atomic>
#include <freertos/queue.h>

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
                     device_transfer::TransferClient &client) override;
  bool allowShortUnauthenticatedResponseCompletion(
      const device_transfer::HttpRequest &request) const override;
  void responseDidComplete(const device_transfer::HttpRequest &request,
                           bool peerClosedCleanly) override;
  void responseDidAbort(
      const device_transfer::HttpRequest &request) override;
  bool takeWakeRequest();
  bool bootPressRequested() const;
  bool takeBootPressRequest();
  bool takeAutomaticExitRequest();
  bool takeRendererRunRequest(RendererRunRequest &request);
  bool initialized() const { return configured_ && runtimeReady_; }

private:
  bool authorize(const device_transfer::HttpRequest &request,
                 device_transfer::TransferClient &client);
  bool requireMode(device_transfer::TransferClient &client);
  bool handleInfo(device_transfer::TransferClient &client);
  bool handleFrame(const device_transfer::HttpRequest &request,
                   device_transfer::TransferClient &client);
  bool handlePointer(const device_transfer::HttpRequest &request,
                     device_transfer::TransferClient &client);
  bool handleWake(device_transfer::TransferClient &client);
  bool handleBootPress(const device_transfer::HttpRequest &request,
                       device_transfer::TransferClient &client);
  bool handleRendererMetrics(device_transfer::TransferClient &client);
  bool handleRendererWindow(const device_transfer::HttpRequest &request,
                            device_transfer::TransferClient &client);
  void updateRendererDebugOverhead();
  bool handleExit(device_transfer::TransferClient &client);

  device_transfer::HttpTransferServer *server_ = nullptr;
  bool configured_ = false;
  bool runtimeReady_ = false;
  std::atomic<bool> wakeRequested_{false};
  OneShotRequestLatch bootPressRequested_;
  std::atomic<bool> exitRequested_{false};
  std::atomic<bool> exitResponsePending_{false};
  QueueHandle_t rendererRunQueue_ = nullptr;
  std::atomic<uint32_t> nextRendererRequestId_{0};
  uint32_t lastMetricsResponseMs_ = 0;
  uint32_t lastRendererWindowRequestMs_ = 0;
  uint32_t lastFrameResponseMs_ = 0;
  uint32_t lastFrameResponseDurationMs_ = 0;
  uint32_t maxFrameResponseDurationMs_ = 0;
  uint32_t lastFrameExpectedBytes_ = 0;
  uint32_t lastFrameActualBytes_ = 0;
  uint32_t lastFrameSnapshotWaitUs_ = 0;
  uint32_t maxFrameSnapshotWaitUs_ = 0;
  uint32_t lastFrameCrcUs_ = 0;
  uint32_t maxFrameCrcUs_ = 0;
  device_transfer::HttpResponseWriteDiagnostics lastFrameWriteDiagnostics_{};
};

} // namespace device_debug
