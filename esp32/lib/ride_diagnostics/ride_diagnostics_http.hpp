#pragma once

#include "../device_transfer/device_transfer_http.hpp"

namespace ride_diagnostics {

class RideDiagnosticsHttp final : public device_transfer::HttpRequestHandler {
public:
  explicit RideDiagnosticsHttp(device_transfer::HttpTransferServer *server = nullptr);

  void configure(device_transfer::HttpTransferServer *server);
  bool handleRequest(const device_transfer::HttpRequest &request,
                     WiFiClient &client) override;
  void responseDidComplete(const device_transfer::HttpRequest &request,
                           bool peerClosedCleanly) override;

private:
  device_transfer::HttpTransferServer *server_ = nullptr;
  bool exitAfterResponse_ = false;
};

} // namespace ride_diagnostics
