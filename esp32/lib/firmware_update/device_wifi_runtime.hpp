#pragma once

#include <atomic>
#include <esp_event.h>
#include <esp_netif.h>
#include <esp_wifi.h>
#include "../device_transfer/device_transfer_network_owner.hpp"

namespace firmware_update {

// Boot-lifetime native driver ownership. Mutations run exclusively on the
// internal operation task; readers use IDF snapshots and atomic publication.
// Do not mix this with Arduino WiFi's private started/initialized flags.
class DeviceWiFiRuntime {
public:
  using MemoryReader = device_transfer::NetworkMemorySnapshot (*)();
  device_transfer::NetworkStartResult start(bool station, const char *ssid,
                                            const char *password, MemoryReader memory);
  esp_err_t stop();
  device_transfer::StationState stationState() const;
  uint32_t stationIPAddress() const;
  uint32_t accessPointIPAddress() const;
  uint8_t accessPointClientCount() const;

private:
  bool initialized_ = false;
  bool ramStorageReady_ = false;
  bool initializationFailed_ = false;
  std::atomic<bool> radioStarted_{false};
  std::atomic<bool> stationRequested_{false};
  std::atomic<bool> stationHasIP_{false};
  std::atomic<int> disconnectReason_{0};
  std::atomic<esp_netif_t *> stationNetif_{nullptr};
  std::atomic<esp_netif_t *> apNetif_{nullptr};
  esp_event_handler_instance_t events_ = nullptr;
  esp_event_handler_instance_t ipEvents_ = nullptr;
  esp_err_t initialize();
  esp_err_t clearCredentials();
  static void event(void *context, esp_event_base_t base, int32_t id, void *data);
};

} // namespace firmware_update
