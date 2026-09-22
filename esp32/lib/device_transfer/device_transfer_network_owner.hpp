#pragma once

#include <cstdint>
#include <string>

namespace device_transfer {

// Runs Wi-Fi operations that may initialize, deinitialize, or update the
// driver configuration on an internal-RAM stack. Transfer protocol and TLS
// work can then remain on a PSRAM-backed worker without becoming the caller
// of an indirect flash-cache-disabling operation.
class NetworkOperationOwner {
public:
  virtual ~NetworkOperationOwner() = default;

  virtual bool startStation(const std::string &ssid,
                            const std::string &password) = 0;
  virtual bool disconnectStation(bool wifiOff) = 0;
  virtual bool startAccessPoint(const std::string &ssid,
                                const std::string &passphrase) = 0;
  virtual bool stopAccessPoint(bool wifiOff) = 0;
  virtual bool stopWiFi() = 0;
  virtual bool healthy() const = 0;
  virtual uint32_t stackHighWaterBytes() const = 0;
};

} // namespace device_transfer
