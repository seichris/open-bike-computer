#pragma once

#include <Arduino.h>
#include <esp_ota_ops.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

#include <cstddef>
#include <cstdint>
#include <atomic>
#include <string>

#include "../device_transfer/device_transfer_network_owner.hpp"
#include "firmware_internal_owner_policy.hpp"
#include "firmware_operation_receipt.hpp"
#include "device_wifi_runtime.hpp"

namespace firmware_update {

struct FirmwarePartitionSnapshot {
  const esp_partition_t *running = nullptr;
  const esp_partition_t *inactive = nullptr;
  esp_err_t runningStateResult = ESP_FAIL;
  esp_ota_img_states_t runningState = ESP_OTA_IMG_UNDEFINED;
};

// Serializes Wi-Fi driver changes, OTA flash writes, and durable map activation
// on one internal-RAM stack. The HTTPS/TLS worker can live in PSRAM without
// calling a cache-disabling operation from its own stack.
class DeviceOperationOwner : public device_transfer::NetworkOperationOwner {
public:
  static constexpr std::size_t kMaximumWriteBytes = 2048;

  void configure();
  bool start();
  bool started() const;
  bool release() override;
  bool healthy() const override;
  uint32_t stackHighWaterBytes() const override;
  bool stackSampleAvailable() const override {
    return stackSampleAvailable_.load(std::memory_order_acquire);
  }

  bool startStation(const std::string &ssid,
                    const std::string &password) override;
  device_transfer::NetworkStartResult startStationDetailed(
      const std::string &ssid, const std::string &password) override;
  bool disconnectStation(bool wifiOff) override;
  bool startAccessPoint(const std::string &ssid,
                        const std::string &passphrase) override;
  device_transfer::NetworkStartResult startAccessPointDetailed(
      const std::string &ssid, const std::string &passphrase) override;
  bool stopAccessPoint(bool wifiOff) override;
  bool stopWiFi() override;
  device_transfer::StationState stationState() const override { return wifi_.stationState(); }
  uint32_t stationIPAddress() const override { return wifi_.stationIPAddress(); }
  uint32_t accessPointIPAddress() const override { return wifi_.accessPointIPAddress(); }
  uint8_t accessPointClientCount() const override { return wifi_.accessPointClientCount(); }

  device_transfer::NetworkReadinessSnapshot networkReadiness() const override { return wifi_.readiness(); }

  FirmwarePartitionSnapshot partitionSnapshot();
  esp_err_t begin(const esp_partition_t *partition, std::size_t imageSize,
                  esp_ota_handle_t &handle);
  esp_err_t write(esp_ota_handle_t handle, const uint8_t *data,
                  std::size_t size);
  esp_err_t end(esp_ota_handle_t handle);
  esp_err_t abort(esp_ota_handle_t handle);
  esp_err_t description(const esp_partition_t *partition,
                        esp_app_desc_t &description);
  esp_err_t protectMetadataReaderFloor(uint32_t reader);
  esp_err_t selectBootPartition(const esp_partition_t *partition);
  esp_err_t acceptFirmwareOperation(const receipt::Record &record, uint32_t revision);
  esp_err_t acknowledgeFirmwareOperation(const receipt::Record &record);
  using MapOperation = void (*)(void *, const char *, bool);
  esp_err_t runMapActivation(MapOperation operation, void *context,
                             const std::string &sessionId, bool automaticExit);

private:
  enum class Operation : uint8_t {
    Snapshot = 0,
    Begin,
    Write,
    End,
    Abort,
    Description,
    SelectBoot,
    ProtectMetadataReaderFloor,
    AcceptFirmwareOperation,
    AcknowledgeFirmwareOperation,
    StartStation,
    DisconnectStation,
    StartAccessPoint,
    StopAccessPoint,
    StopWiFi,
    MapActivation,
    Quiesce,
  };

  struct Command {
    Operation operation = Operation::Snapshot;
    const esp_partition_t *partition = nullptr;
    esp_ota_handle_t handle = 0;
    std::size_t size = 0;
    uint32_t id = 0;
    bool wifiOff = false;
    MapOperation mapOperation = nullptr;
    void *mapContext = nullptr;
    bool automaticExit = false;
    receipt::Record firmwareReceipt{};
    uint32_t receiptRevision = 0;
  };

  struct Result {
    esp_err_t error = ESP_FAIL;
    esp_ota_handle_t handle = 0;
    FirmwarePartitionSnapshot snapshot;
    esp_app_desc_t description{};
    uint32_t commandId = 0;
    device_transfer::NetworkStartResult networkStart;
  };

  // Map activation is the deepest internal-stack operation. The HTTP/TLS
  // worker uses PSRAM and never invokes activation on its own stack.
  static constexpr uint32_t kWorkerStackBytes = 16384;
  static constexpr TickType_t kCommandTimeoutTicks = pdMS_TO_TICKS(60000);
  static constexpr TickType_t kMapActivationTimeoutTicks = pdMS_TO_TICKS(600000);

  mutable SemaphoreHandle_t callMutex_ = nullptr;
  StaticSemaphore_t callMutexStorage_{};
  QueueHandle_t commandQueue_ = nullptr;
  StaticQueue_t commandQueueStorage_{};
  uint8_t commandQueueBuffer_[sizeof(Command)]{};
  QueueHandle_t resultQueue_ = nullptr;
  StaticQueue_t resultQueueStorage_{};
  uint8_t resultQueueBuffer_[sizeof(Result)]{};
  std::atomic<TaskHandle_t> workerTask_{nullptr};
  // This owner is a boot-lifetime object in internal BSS. Reserving its
  // cache-safe stack at link time avoids taking the largest DMA-capable heap
  // block immediately before Wi-Fi initialization. The task sleeps between
  // commands and is reused after quiescence, never deleted/recreated.
  alignas(16) StackType_t workerStack_[kWorkerStackBytes / sizeof(StackType_t)]{};
  StaticTask_t workerTaskStorage_{};
  std::atomic<uint32_t> lastStackHighWaterBytes_{0};
  std::atomic<bool> stackSampleAvailable_{false};
  alignas(4) uint8_t writeBuffer_[kMaximumWriteBytes]{};
  char networkSsid_[33]{};
  char networkPassword_[65]{};
  char mapSessionId_[81]{};
  DeviceWiFiRuntime wifi_;
  uint32_t nextCommandId_ = 1;
  std::atomic<internal_owner_policy::DispatchState> dispatchState_{
      internal_owner_policy::DispatchState::Ready};

  esp_err_t execute(const Command &command, Result &result,
                    const uint8_t *writeData = nullptr,
                    const std::string *networkSsid = nullptr,
                    const std::string *networkPassword = nullptr,
                    TickType_t timeoutTicks = kCommandTimeoutTicks);
  bool startLocked();
  void run();
  static void taskThunk(void *context);
};

} // namespace firmware_update
