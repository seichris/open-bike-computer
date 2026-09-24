#pragma once

#include <cstdint>
#include <string>

namespace device_transfer {

struct NetworkMemorySnapshot {
  uint32_t internalFree = 0;
  uint32_t internalLargest = 0;
  uint32_t dmaFree = 0;
  uint32_t dmaLargest = 0;
};

struct NetworkTransitionMemory {
  NetworkMemorySnapshot before;
  NetworkMemorySnapshot after;
  bool attempted = false;
};

enum class NetworkStartStep : uint8_t {
  None, OwnerCreate, OwnerDispatch, Mode, RamStorage, AccessPoint,
};

struct NetworkStartResult {
  NetworkStartStep failedStep = NetworkStartStep::None;
  int32_t espError = 0;
  NetworkMemorySnapshot before;
  NetworkMemorySnapshot after;
  NetworkTransitionMemory mode;
  NetworkTransitionMemory ramStorage;
  NetworkTransitionMemory accessPoint;
  bool ok() const { return failedStep == NetworkStartStep::None; }
};

inline const char *networkStartCode(NetworkStartStep step) {
  switch (step) {
  case NetworkStartStep::OwnerCreate: return "wifi_owner_create";
  case NetworkStartStep::OwnerDispatch: return "wifi_owner_dispatch";
  case NetworkStartStep::Mode: return "wifi_mode";
  case NetworkStartStep::RamStorage: return "wifi_ram_storage";
  case NetworkStartStep::AccessPoint: return "wifi_softap";
  case NetworkStartStep::None: return "";
  }
  return "wifi_owner_dispatch";
}

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
  virtual NetworkStartResult startAccessPointDetailed(
      const std::string &ssid, const std::string &passphrase) = 0;
  virtual bool stopAccessPoint(bool wifiOff) = 0;
  virtual bool stopWiFi() = 0;
  virtual bool healthy() const = 0;
  virtual uint32_t stackHighWaterBytes() const = 0;
  // Called after the HTTP worker has stopped using the network. A poisoned
  // owner must retain its task and staging buffers for the rest of this boot.
  virtual bool release() = 0;
};

} // namespace device_transfer
